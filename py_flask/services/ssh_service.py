"""SSH and SFTP connection service using paramiko."""

from __future__ import annotations

import os
import queue
import stat
import threading
from collections.abc import Generator
from dataclasses import dataclass
from typing import Any, Optional

import paramiko

from py_flask.config import Config
from py_flask.models.site import Site


@dataclass
class CommandResult:
    """Result of a remote SSH command execution."""

    stdout: str
    stderr: str
    exit_code: int


@dataclass
class RemoteFile:
    """A file or directory entry from an SFTP listing."""

    name: str
    path: str
    is_dir: bool
    size: int
    modified: str


class SSHService:
    """Manage SSH and SFTP connections to a single remote site.

    Supports the context-manager protocol so connections are always closed::

        with SSHService(site) as ssh:
            result = ssh.execute("uname -a")
    """

    def __init__(self, site: Site) -> None:
        self._site = site
        self._client: Optional[paramiko.SSHClient] = None

    # ── Connection lifecycle ───────────────────────────────────────────────

    def connect(self) -> None:
        """Open an SSH connection using the site's credentials."""
        self._client = paramiko.SSHClient()
        self._client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

        kwargs: dict = {
            "hostname": self._site.hostname,
            "port": self._site.port,
            "username": self._site.username,
            "timeout": Config.SSH_TIMEOUT,
        }

        if self._site.auth_type == "key" and self._site.key_path:
            kwargs["key_filename"] = os.path.expanduser(self._site.key_path)
        else:
            kwargs["password"] = self._site.password

        self._client.connect(**kwargs)

    def disconnect(self) -> None:
        """Close the SSH connection if open."""
        if self._client:
            self._client.close()
            self._client = None

    # ── SSH commands ───────────────────────────────────────────────────────

    def execute(self, command: str) -> CommandResult:
        """Run *command* on the remote host and return its output."""
        if not self._client:
            raise ConnectionError("Not connected — call connect() first")

        _, stdout, stderr = self._client.exec_command(
            command, timeout=Config.SSH_COMMAND_TIMEOUT,
        )
        exit_code = stdout.channel.recv_exit_status()
        return CommandResult(
            stdout=stdout.read().decode("utf-8", errors="replace"),
            stderr=stderr.read().decode("utf-8", errors="replace"),
            exit_code=exit_code,
        )

    # ── SFTP operations ────────────────────────────────────────────────────

    def sftp_normalize(self, remote_path: str) -> str:
        """Resolve *remote_path* to a canonical absolute path via SFTP.

        Relative paths (including ``"."``) are resolved against the
        remote user's home directory.  The result always starts with
        ``"/"``.
        """
        if not self._client:
            raise ConnectionError("Not connected — call connect() first")

        sftp = self._client.open_sftp()
        try:
            return sftp.normalize(remote_path)
        finally:
            sftp.close()

    def sftp_list(self, remote_path: str = ".") -> list[RemoteFile]:
        """List files and directories at *remote_path*.

        *remote_path* should be an absolute path.  Child entry paths
        are constructed as absolute paths so they can be used directly
        in subsequent calls without ambiguity.
        """
        if not self._client:
            raise ConnectionError("Not connected — call connect() first")

        sftp = self._client.open_sftp()
        try:
            # Normalise to an absolute path so every child path is also
            # absolute — avoids relative-path confusion in URL routing.
            abs_path = sftp.normalize(remote_path)

            entries: list[RemoteFile] = []
            for attr in sftp.listdir_attr(abs_path):
                is_dir = stat.S_ISDIR(attr.st_mode) if attr.st_mode else False
                if abs_path == "/":
                    full_path = f"/{attr.filename}"
                else:
                    full_path = f"{abs_path}/{attr.filename}"
                entries.append(
                    RemoteFile(
                        name=attr.filename,
                        path=full_path,
                        is_dir=is_dir,
                        size=attr.st_size or 0,
                        modified=str(attr.st_mtime or ""),
                    )
                )
            # Directories first, then alphabetical.
            entries.sort(key=lambda f: (not f.is_dir, f.name.lower()))
            return entries
        finally:
            sftp.close()

    def sftp_download(self, remote_path: str, local_path: str) -> None:
        """Download a remote file to *local_path*."""
        if not self._client:
            raise ConnectionError("Not connected — call connect() first")

        sftp = self._client.open_sftp()
        try:
            sftp.get(remote_path, local_path)
        finally:
            sftp.close()

    def sftp_upload(self, local_path: str, remote_path: str) -> None:
        """Upload a local file to *remote_path*."""
        if not self._client:
            raise ConnectionError("Not connected — call connect() first")

        sftp = self._client.open_sftp()
        try:
            sftp.put(local_path, remote_path)
        finally:
            sftp.close()

    # ── SFTP operations with progress ──────────────────────────────────────

    @staticmethod
    def _format_size(size_bytes: int) -> str:
        """Return a human-readable file size string."""
        for unit in ("B", "KB", "MB", "GB", "TB"):
            if abs(size_bytes) < 1024:
                return f"{size_bytes:.1f} {unit}" if unit != "B" else f"{size_bytes} {unit}"
            size_bytes /= 1024  # type: ignore[assignment]
        return f"{size_bytes:.1f} PB"

    def sftp_upload_with_progress(
        self,
        local_path: str,
        remote_path: str,
    ) -> Generator[dict[str, Any], None, None]:
        """Upload a local file to *remote_path*, yielding progress events.

        Each yielded dict has the shape::

            {"event": "scan"|"progress"|"complete"|"error",
             "transferred": int, "total": int, "filename": str,
             "percent": float, "message": str}

        The transfer runs in a background thread; progress events are
        bridged to the generator via a :class:`queue.Queue`.
        """
        if not self._client:
            raise ConnectionError("Not connected — call connect() first")

        total_size = os.path.getsize(local_path)
        filename = os.path.basename(remote_path)
        size_label = self._format_size(total_size)

        yield {
            "event": "scan",
            "message": f"Scanning source: {filename}",
            "filename": filename,
            "total": total_size,
        }
        yield {
            "event": "scan_complete",
            "message": f"Source size: {size_label}",
            "filename": filename,
            "total": total_size,
        }

        progress_queue: queue.Queue[tuple[Any, ...]] = queue.Queue()

        def _callback(transferred: int, total: int) -> None:
            progress_queue.put(("progress", transferred, total))

        def _run() -> None:
            try:
                sftp = self._client.open_sftp()  # type: ignore[union-attr]
                try:
                    sftp.put(local_path, remote_path, callback=_callback)
                finally:
                    sftp.close()
                progress_queue.put(("complete", total_size, total_size))
            except Exception as exc:
                progress_queue.put(("error", str(exc)))

        thread = threading.Thread(target=_run, daemon=True)
        thread.start()

        while True:
            try:
                event = progress_queue.get(timeout=60)
            except queue.Empty:
                yield {"event": "heartbeat"}
                continue

            if event[0] == "progress":
                transferred = int(event[1])
                total = int(event[2])
                pct = (transferred / total * 100) if total else 0
                yield {
                    "event": "progress",
                    "transferred": transferred,
                    "total": total,
                    "filename": filename,
                    "percent": round(pct, 1),
                    "message": (
                        f"Uploading {filename}: "
                        f"{self._format_size(transferred)} / {size_label}"
                    ),
                }
            elif event[0] == "complete":
                yield {
                    "event": "complete",
                    "transferred": total_size,
                    "total": total_size,
                    "filename": filename,
                    "percent": 100,
                    "message": f"Uploaded {filename} ({size_label})",
                }
                break
            elif event[0] == "error":
                yield {"event": "error", "message": str(event[1])}
                break

        thread.join(timeout=5)

    def sftp_download_with_progress(
        self,
        remote_path: str,
        local_path: str,
    ) -> Generator[dict[str, Any], None, None]:
        """Download a remote file to *local_path*, yielding progress events.

        Identical event format to :meth:`sftp_upload_with_progress`.
        """
        if not self._client:
            raise ConnectionError("Not connected — call connect() first")

        filename = os.path.basename(remote_path)

        yield {
            "event": "scan",
            "message": f"Scanning source: {filename}",
            "filename": filename,
            "total": 0,
        }

        # Get remote file size.
        sftp_stat = self._client.open_sftp()
        try:
            total_size = sftp_stat.stat(remote_path).st_size or 0
        finally:
            sftp_stat.close()

        size_label = self._format_size(total_size)

        yield {
            "event": "scan_complete",
            "message": f"Source size: {size_label}",
            "filename": filename,
            "total": total_size,
        }

        progress_queue: queue.Queue[tuple[Any, ...]] = queue.Queue()

        def _callback(transferred: int, total: int) -> None:
            progress_queue.put(("progress", transferred, total))

        def _run() -> None:
            try:
                sftp = self._client.open_sftp()  # type: ignore[union-attr]
                try:
                    sftp.get(remote_path, local_path, callback=_callback)
                finally:
                    sftp.close()
                progress_queue.put(("complete", total_size, total_size))
            except Exception as exc:
                progress_queue.put(("error", str(exc)))

        thread = threading.Thread(target=_run, daemon=True)
        thread.start()

        while True:
            try:
                event = progress_queue.get(timeout=60)
            except queue.Empty:
                yield {"event": "heartbeat"}
                continue

            if event[0] == "progress":
                transferred = int(event[1])
                total = int(event[2])
                pct = (transferred / total * 100) if total else 0
                yield {
                    "event": "progress",
                    "transferred": transferred,
                    "total": total,
                    "filename": filename,
                    "percent": round(pct, 1),
                    "message": (
                        f"Downloading {filename}: "
                        f"{self._format_size(transferred)} / {size_label}"
                    ),
                }
            elif event[0] == "complete":
                yield {
                    "event": "complete",
                    "transferred": total_size,
                    "total": total_size,
                    "filename": filename,
                    "percent": 100,
                    "message": f"Downloaded {filename} ({size_label})",
                }
                break
            elif event[0] == "error":
                yield {"event": "error", "message": str(event[1])}
                break

        thread.join(timeout=5)

    # ── Context manager ────────────────────────────────────────────────────

    def __enter__(self) -> SSHService:
        self.connect()
        return self

    def __exit__(self, *args: object) -> None:
        self.disconnect()
