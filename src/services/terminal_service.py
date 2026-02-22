"""Platform detection and native terminal launcher for SSH connections.

Detects the host OS at startup and identifies the default terminal
application.  Provides :meth:`launch_ssh` to open an interactive SSH
session in that terminal.
"""

from __future__ import annotations

import logging
import os
import platform
import shlex
import shutil
import subprocess
from dataclasses import dataclass
from typing import Optional

log = logging.getLogger(__name__)


@dataclass
class PlatformInfo:
    """Snapshot of the detected host environment."""

    system: str          # 'Darwin', 'Linux', 'Windows'
    system_label: str    # 'macOS', 'Linux', 'Windows'
    terminal: str        # Human-readable terminal name
    terminal_cmd: str    # Executable used to launch the terminal
    has_sshpass: bool    # True if ``sshpass`` is on PATH


# ── Detection helpers ─────────────────────────────────────────────────────────

_SYSTEM_LABELS = {
    "Darwin": "macOS",
    "Linux": "Linux",
    "Windows": "Windows",
}

# macOS terminals checked in preference order
_MACOS_TERMINALS = [
    ("iTerm", "/Applications/iTerm.app"),
    ("Terminal", "/System/Applications/Utilities/Terminal.app"),
    ("Terminal", "/Applications/Utilities/Terminal.app"),
]

# Linux terminals: (human name, executable)
_LINUX_TERMINALS = [
    ("GNOME Terminal", "gnome-terminal"),
    ("Konsole", "konsole"),
    ("Xfce Terminal", "xfce4-terminal"),
    ("MATE Terminal", "mate-terminal"),
    ("LXTerminal", "lxterminal"),
    ("Tilix", "tilix"),
    ("Alacritty", "alacritty"),
    ("xterm", "xterm"),
]

# Windows terminals
_WINDOWS_TERMINALS = [
    ("Windows Terminal", "wt"),
    ("Command Prompt", "cmd"),
]


def _detect_macos_terminal() -> tuple[str, str]:
    """Return ``(name, app_name)`` for the first available macOS terminal."""
    for name, app_path in _MACOS_TERMINALS:
        if os.path.exists(app_path):
            return name, name
    return "Terminal", "Terminal"


def _detect_linux_terminal() -> tuple[str, str]:
    """Return ``(name, executable)`` for the first available Linux terminal."""
    for name, cmd in _LINUX_TERMINALS:
        if shutil.which(cmd):
            return name, cmd
    return "xterm", "xterm"


def _detect_windows_terminal() -> tuple[str, str]:
    """Return ``(name, executable)`` for the first available Windows terminal."""
    for name, cmd in _WINDOWS_TERMINALS:
        if shutil.which(cmd):
            return name, cmd
    return "Command Prompt", "cmd"


def detect_platform() -> PlatformInfo:
    """Probe the host OS and locate the default terminal application."""
    system = platform.system()
    label = _SYSTEM_LABELS.get(system, system)

    if system == "Darwin":
        term_name, term_cmd = _detect_macos_terminal()
    elif system == "Linux":
        term_name, term_cmd = _detect_linux_terminal()
    elif system == "Windows":
        term_name, term_cmd = _detect_windows_terminal()
    else:
        term_name, term_cmd = "unknown", "unknown"

    has_sshpass = shutil.which("sshpass") is not None

    info = PlatformInfo(
        system=system,
        system_label=label,
        terminal=term_name,
        terminal_cmd=term_cmd,
        has_sshpass=has_sshpass,
    )
    log.info(
        "Detected platform: %s, terminal: %s, sshpass: %s",
        label, term_name, "yes" if has_sshpass else "no",
    )
    return info


# ── SSH launcher ──────────────────────────────────────────────────────────────


class TerminalService:
    """Launch SSH sessions in the host's native terminal application."""

    def __init__(self, platform_info: Optional[PlatformInfo] = None) -> None:
        self.platform_info = platform_info or detect_platform()

    # -- Public API ----------------------------------------------------------

    def launch_ssh(
        self,
        hostname: str,
        port: int,
        username: str,
        key_path: str = "",
        password: str = "",
    ) -> None:
        """Open an interactive SSH session in the native terminal.

        If *password* is provided and ``sshpass`` is available on the host,
        the password is passed automatically via the ``SSHPASS`` environment
        variable so the user is not prompted.

        Raises :class:`RuntimeError` if the terminal could not be launched.
        """
        ssh_cmd = self._build_ssh_command(
            hostname, port, username, key_path, password,
        )
        system = self.platform_info.system

        try:
            if system == "Darwin":
                self._launch_macos(ssh_cmd)
            elif system == "Linux":
                self._launch_linux(ssh_cmd)
            elif system == "Windows":
                self._launch_windows(ssh_cmd)
            else:
                raise RuntimeError(
                    f"Unsupported platform: {self.platform_info.system_label}"
                )
        except FileNotFoundError as exc:
            raise RuntimeError(
                f"Terminal '{self.platform_info.terminal}' not found: {exc}"
            ) from exc

    # -- SSH command construction --------------------------------------------

    def _build_ssh_command(
        self,
        hostname: str,
        port: int,
        username: str,
        key_path: str = "",
        password: str = "",
    ) -> str:
        """Build a shell-safe ``ssh …`` command string.

        When *password* is supplied and ``sshpass`` is available, the
        returned command is wrapped so the password is fed automatically
        via the ``SSHPASS`` environment variable.
        """
        parts = ["ssh"]
        if key_path:
            parts.extend(["-i", os.path.expanduser(key_path)])
        if port != 22:
            parts.extend(["-p", str(port)])
        if username:
            parts.append(f"{username}@{hostname}")
        else:
            parts.append(hostname)

        ssh_cmd = " ".join(shlex.quote(p) for p in parts)

        if password and self.platform_info.has_sshpass:
            safe_pw = shlex.quote(password)
            return (
                f"export SSHPASS={safe_pw}; "
                f"sshpass -e {ssh_cmd}; "
                "unset SSHPASS"
            )

        return ssh_cmd

    # -- Platform-specific launchers -----------------------------------------

    def _launch_macos(self, ssh_cmd: str) -> None:
        """Open a new terminal window on macOS via AppleScript."""
        terminal = self.platform_info.terminal

        # Escape backslashes and double-quotes for AppleScript string context
        safe_cmd = ssh_cmd.replace("\\", "\\\\").replace('"', '\\"')

        if terminal == "iTerm":
            script = (
                'tell application "iTerm"\n'
                "    activate\n"
                "    create window with default profile "
                f'command "{safe_cmd}"\n'
                "end tell"
            )
        else:
            script = (
                'tell application "Terminal"\n'
                "    activate\n"
                f'    do script "{safe_cmd}"\n'
                "end tell"
            )

        subprocess.Popen(
            ["osascript", "-e", script],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    def _launch_linux(self, ssh_cmd: str) -> None:
        """Open a new terminal window on Linux."""
        cmd = self.platform_info.terminal_cmd

        # Most Linux terminals accept a common pattern; a few differ.
        if cmd == "gnome-terminal":
            args = [cmd, "--", "bash", "-c", ssh_cmd + "; exec bash"]
        elif cmd in ("konsole", "mate-terminal"):
            args = [cmd, "-e", "bash", "-c", ssh_cmd + "; exec bash"]
        elif cmd == "xfce4-terminal":
            args = [cmd, "--command", ssh_cmd]
        elif cmd == "tilix":
            args = [cmd, "-e", ssh_cmd]
        elif cmd == "alacritty":
            args = [cmd, "-e", "bash", "-c", ssh_cmd + "; exec bash"]
        else:
            # xterm and generic fallback
            args = [cmd, "-e", ssh_cmd]

        subprocess.Popen(
            args,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    def _launch_windows(self, ssh_cmd: str) -> None:
        """Open a new terminal window on Windows."""
        cmd = self.platform_info.terminal_cmd

        if cmd == "wt":
            args = [cmd, "cmd", "/k", ssh_cmd]
        else:
            args = ["cmd", "/c", "start", "cmd", "/k", ssh_cmd]

        subprocess.Popen(
            args,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
