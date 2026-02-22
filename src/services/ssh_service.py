"""SSH and SFTP connection service using paramiko."""

from __future__ import annotations

import os
import stat
from dataclasses import dataclass
from typing import Optional

import paramiko

from src.config import Config
from src.models.site import Site


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

    def sftp_list(self, remote_path: str = ".") -> list[RemoteFile]:
        """List files and directories at *remote_path*."""
        if not self._client:
            raise ConnectionError("Not connected — call connect() first")

        sftp = self._client.open_sftp()
        try:
            entries: list[RemoteFile] = []
            for attr in sftp.listdir_attr(remote_path):
                is_dir = stat.S_ISDIR(attr.st_mode) if attr.st_mode else False
                full_path = f"{remote_path}/{attr.filename}".replace("//", "/")
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

    # ── Context manager ────────────────────────────────────────────────────

    def __enter__(self) -> SSHService:
        self.connect()
        return self

    def __exit__(self, *args: object) -> None:
        self.disconnect()
