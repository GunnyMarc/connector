"""Platform detection and native terminal launcher for connections.

Detects the host OS at startup, enumerates installed terminal applications,
and launches interactive sessions in the user's chosen terminal.

The catalog of supported terminals lives in ``_TERMINAL_CATALOGS`` keyed by
host OS.  Each entry carries enough metadata for both *detection* (where to
look for the install) and *launching* (which launch strategy to use).  Users
override the auto-detected default via the application Settings UI; the
preference is persisted in the encrypted settings file as the keys
``terminal_name`` and ``terminal_path``.
"""

from __future__ import annotations

import logging
import os
import platform
import shlex
import shutil
import subprocess
from dataclasses import asdict, dataclass, field
from typing import Optional

log = logging.getLogger(__name__)


# ── Data classes ──────────────────────────────────────────────────────────────


@dataclass
class TerminalApp:
    """Metadata describing one terminal application option."""

    name: str            # Human-readable name shown in Settings (e.g. "iTerm")
    path: str            # Bundle path (macOS) or executable name/path
    launcher: str        # Launch strategy id — see ``_LAUNCHERS``
    installed: bool = False


@dataclass
class PlatformInfo:
    """Snapshot of the detected host environment."""

    system: str          # 'Darwin', 'Linux', 'Windows'
    system_label: str    # 'macOS', 'Linux', 'Windows'
    terminal: str        # Currently selected terminal name
    terminal_cmd: str    # Currently selected terminal path/executable
    terminal_launcher: str  # Currently selected launcher strategy id
    has_sshpass: bool    # True if ``sshpass`` is on PATH
    available_terminals: list[TerminalApp] = field(default_factory=list)

    def to_dict(self) -> dict:
        """Return a JSON-serialisable representation (used in templates)."""
        d = asdict(self)
        d["available_terminals"] = [asdict(t) for t in self.available_terminals]
        return d


# ── Terminal catalogs ─────────────────────────────────────────────────────────

_SYSTEM_LABELS = {
    "Darwin": "macOS",
    "Linux": "Linux",
    "Windows": "Windows",
}

# Each catalog entry is (name, default-path, launcher-id).
# ``launcher`` selects the AppleScript / argv strategy used to launch a command.
_TERMINAL_CATALOGS: dict[str, list[tuple[str, str, str]]] = {
    "Darwin": [
        ("iTerm", "/Applications/iTerm.app", "macos_iterm"),
        ("Ghostty", "/Applications/Ghostty.app", "macos_ghostty"),
        ("Royal TSX", "/Applications/Royal TSX.app", "macos_open"),
        ("Alacritty", "/Applications/Alacritty.app", "macos_open"),
        ("Kitty", "/Applications/kitty.app", "macos_open"),
        ("WezTerm", "/Applications/WezTerm.app", "macos_open"),
        ("Hyper", "/Applications/Hyper.app", "macos_open"),
        ("Terminal", "/System/Applications/Utilities/Terminal.app", "macos_terminal"),
        ("Terminal", "/Applications/Utilities/Terminal.app", "macos_terminal"),
    ],
    "Linux": [
        ("GNOME Terminal", "gnome-terminal", "linux_gnome"),
        ("Konsole", "konsole", "linux_konsole"),
        ("Xfce Terminal", "xfce4-terminal", "linux_xfce"),
        ("MATE Terminal", "mate-terminal", "linux_konsole"),
        ("LXTerminal", "lxterminal", "linux_generic"),
        ("Tilix", "tilix", "linux_tilix"),
        ("Alacritty", "alacritty", "linux_alacritty"),
        ("Kitty", "kitty", "linux_alacritty"),
        ("WezTerm", "wezterm", "linux_alacritty"),
        ("Ghostty", "ghostty", "linux_alacritty"),
        ("xterm", "xterm", "linux_generic"),
    ],
    "Windows": [
        ("Windows Terminal", "wt", "windows_wt"),
        ("Command Prompt", "cmd", "windows_cmd"),
    ],
}


def _is_installed(system: str, path: str) -> bool:
    """Return True if a terminal at *path* is installed on the host."""
    if system == "Darwin":
        # macOS: catalog entries are .app bundle paths.
        return os.path.exists(path)
    # Linux / Windows: catalog entries are executable names (or paths).
    if os.sep in path or (os.altsep and os.altsep in path):
        return os.path.exists(path)
    return shutil.which(path) is not None


def discover_terminals(system: Optional[str] = None) -> list[TerminalApp]:
    """Return the platform's catalog with each entry's *installed* flag set.

    De-duplicates entries that share the same ``(name, launcher)`` and keep
    only the first installed path (so the macOS Terminal.app's two possible
    locations collapse to a single entry).
    """
    sys_name = system or platform.system()
    catalog = _TERMINAL_CATALOGS.get(sys_name, [])

    seen: dict[tuple[str, str], TerminalApp] = {}
    for name, path, launcher in catalog:
        installed = _is_installed(sys_name, path)
        key = (name, launcher)
        existing = seen.get(key)
        if existing is None:
            seen[key] = TerminalApp(
                name=name, path=path, launcher=launcher, installed=installed,
            )
        elif installed and not existing.installed:
            # Prefer the path that actually exists.
            existing.path = path
            existing.installed = True

    return list(seen.values())


def _pick_default(terminals: list[TerminalApp], system: str) -> TerminalApp:
    """Return the first installed terminal, or a sensible fallback."""
    for term in terminals:
        if term.installed:
            return term

    # Hard fallbacks when no catalog entry is installed.
    fallbacks = {
        "Darwin": TerminalApp(
            name="Terminal", path="Terminal", launcher="macos_terminal",
        ),
        "Linux": TerminalApp(name="xterm", path="xterm", launcher="linux_generic"),
        "Windows": TerminalApp(
            name="Command Prompt", path="cmd", launcher="windows_cmd",
        ),
    }
    return fallbacks.get(
        system,
        TerminalApp(name="unknown", path="unknown", launcher="generic"),
    )


def detect_platform() -> PlatformInfo:
    """Probe the host OS and locate the default terminal application."""
    system = platform.system()
    label = _SYSTEM_LABELS.get(system, system)

    terminals = discover_terminals(system)
    default = _pick_default(terminals, system)
    has_sshpass = shutil.which("sshpass") is not None

    info = PlatformInfo(
        system=system,
        system_label=label,
        terminal=default.name,
        terminal_cmd=default.path,
        terminal_launcher=default.launcher,
        has_sshpass=has_sshpass,
        available_terminals=terminals,
    )
    log.info(
        "Detected platform: %s, terminal: %s (%s), sshpass: %s",
        label, default.name, default.path, "yes" if has_sshpass else "no",
    )
    return info


def _resolve_launcher(
    system: str, name: str, path: str,
) -> str:
    """Find the launcher id for a terminal by matching the catalog by name.

    Falls back to a platform-default launcher if the name is not in the
    catalog (e.g. a user-supplied custom path).
    """
    for cat_name, _cat_path, launcher in _TERMINAL_CATALOGS.get(system, []):
        if cat_name.lower() == name.lower():
            return launcher

    if system == "Darwin":
        return "macos_open"
    if system == "Linux":
        return "linux_generic"
    if system == "Windows":
        return "windows_cmd"
    return "generic"


# ── Session launcher ──────────────────────────────────────────────────────────


class TerminalService:
    """Launch sessions in the host's native terminal application."""

    def __init__(self, platform_info: Optional[PlatformInfo] = None) -> None:
        self.platform_info = platform_info or detect_platform()

    # -- Configuration -------------------------------------------------------

    def set_terminal(self, name: str, path: str = "") -> None:
        """Apply a user-selected terminal at runtime.

        *name* is required (the human-readable label used to pick a launcher
        strategy). *path* is the bundle path / executable; when blank, falls
        back to the catalog's default path for that name.
        """
        if not name:
            return

        system = self.platform_info.system

        # Default the path from the catalog entry if the user left it blank.
        if not path:
            for cat_name, cat_path, _launcher in _TERMINAL_CATALOGS.get(system, []):
                if cat_name.lower() == name.lower():
                    path = cat_path
                    break

        launcher = _resolve_launcher(system, name, path)
        self.platform_info.terminal = name
        self.platform_info.terminal_cmd = path or name
        self.platform_info.terminal_launcher = launcher

    # -- Public API ----------------------------------------------------------

    def launch_session(self, site) -> None:
        """Open an interactive session in the native terminal.

        Dispatches to the correct command builder based on ``site.protocol``.
        Accepts a :class:`~py_flask.models.site.Site` instance (or any object
        with the same attributes).

        Raises :class:`RuntimeError` on unsupported protocol or launch failure.
        """
        protocol = getattr(site, "protocol", "ssh2")
        cmd = self._build_command_for_protocol(site, protocol)
        self._launch_in_terminal(cmd)

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
        self._launch_in_terminal(ssh_cmd)

    # -- Internal launcher ---------------------------------------------------

    def _launch_in_terminal(self, cmd: str) -> None:
        """Dispatch *cmd* to the configured terminal's launch strategy."""
        launcher = self.platform_info.terminal_launcher
        handler = _LAUNCHERS.get(launcher)
        if handler is None:
            raise RuntimeError(
                f"No launch strategy for terminal '{self.platform_info.terminal}'"
            )
        try:
            handler(self, cmd)
        except FileNotFoundError as exc:
            raise RuntimeError(
                f"Terminal '{self.platform_info.terminal}' not found: {exc}"
            ) from exc

    # -- Protocol command builders -------------------------------------------

    def _build_command_for_protocol(self, site, protocol: str) -> str:
        """Return the shell command string for the given protocol."""
        if protocol in ("ssh2", "ssh1"):
            return self._build_ssh_command(
                hostname=site.hostname,
                port=site.port,
                username=site.username,
                key_path=site.key_path if site.auth_type == "key" else "",
                password=site.password if site.auth_type == "password" else "",
                ssh_version=1 if protocol == "ssh1" else 2,
            )
        if protocol == "local":
            return self._build_local_command()
        if protocol == "raw":
            return self._build_raw_command(site.hostname, site.port)
        if protocol == "telnet":
            return self._build_telnet_command(
                site.hostname, site.port, site.username,
            )
        if protocol == "serial":
            return self._build_serial_command(
                site.serial_port, site.serial_baud,
            )
        raise RuntimeError(f"Unsupported protocol: {protocol}")

    def _build_local_command(self) -> str:
        """Build a command that opens the user's default login shell."""
        shell = os.environ.get("SHELL", "/bin/bash")
        return shlex.quote(shell) + " --login"

    def _build_raw_command(self, hostname: str, port: int) -> str:
        """Build a ``nc`` (netcat) command for raw TCP connections."""
        parts = ["nc", hostname, str(port)]
        return " ".join(shlex.quote(p) for p in parts)

    def _build_telnet_command(
        self, hostname: str, port: int, username: str = "",
    ) -> str:
        """Build a ``telnet`` command.

        If *username* is supplied, it is passed via ``-l``.
        """
        parts = ["telnet"]
        if username:
            parts.extend(["-l", username])
        parts.append(hostname)
        if port != 23:
            parts.append(str(port))
        return " ".join(shlex.quote(p) for p in parts)

    def _build_serial_command(
        self, serial_port: str, serial_baud: int,
    ) -> str:
        """Build a ``screen`` command for serial connections."""
        port_path = serial_port or "/dev/ttyUSB0"
        parts = ["screen", port_path, str(serial_baud)]
        return " ".join(shlex.quote(p) for p in parts)

    # -- SSH command construction --------------------------------------------

    def _build_ssh_command(
        self,
        hostname: str,
        port: int,
        username: str,
        key_path: str = "",
        password: str = "",
        ssh_version: int = 2,
    ) -> str:
        """Build a shell-safe ``ssh …`` command string.

        When *password* is supplied and ``sshpass`` is available, the
        returned command is wrapped so the password is fed automatically
        via the ``SSHPASS`` environment variable.

        *ssh_version* selects SSH protocol version (1 or 2).
        """
        parts = ["ssh"]
        if ssh_version == 1:
            parts.extend(["-o", "Protocol=1"])
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


# ── Launcher strategies ───────────────────────────────────────────────────────
#
# Each launcher is a free function ``(svc: TerminalService, cmd: str) -> None``
# that opens *cmd* in a specific terminal application.  Keeping the strategies
# as a registry makes it cheap to add new terminals (e.g. Ghostty, Royal TSX)
# without growing the if/elif tree inside ``TerminalService``.


def _macos_app_name(path: str) -> str:
    """Return the bundle's display name from a ``.app`` path (no extension)."""
    base = os.path.basename(path.rstrip("/"))
    return base[:-4] if base.lower().endswith(".app") else base


def _ascii_safe(cmd: str) -> str:
    """Escape backslashes and double-quotes for AppleScript string context."""
    return cmd.replace("\\", "\\\\").replace('"', '\\"')


def _launch_macos_terminal(svc: "TerminalService", cmd: str) -> None:
    """Apple Terminal.app via AppleScript ``do script``."""
    safe = _ascii_safe(cmd)
    script = (
        'tell application "Terminal"\n'
        "    activate\n"
        f'    do script "{safe}"\n'
        "end tell"
    )
    subprocess.Popen(
        ["osascript", "-e", script],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def _launch_macos_iterm(svc: "TerminalService", cmd: str) -> None:
    """iTerm via AppleScript ``create window with default profile``."""
    safe = _ascii_safe(cmd)
    script = (
        'tell application "iTerm"\n'
        "    activate\n"
        "    create window with default profile "
        f'command "{safe}"\n'
        "end tell"
    )
    subprocess.Popen(
        ["osascript", "-e", script],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def _launch_macos_ghostty(svc: "TerminalService", cmd: str) -> None:
    """Ghostty: pass the command via the ``-e`` flag in a new instance."""
    app_path = svc.platform_info.terminal_cmd
    # Ghostty supports `-e <cmd>` to run a command in a new window.
    subprocess.Popen(
        ["open", "-na", app_path, "--args", "-e", cmd],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def _launch_macos_open(svc: "TerminalService", cmd: str) -> None:
    """Generic macOS launch via ``open -na <app> --args <cmd>``.

    Used for terminals like Royal TSX, Alacritty, Kitty, WezTerm, Hyper.
    Many terminals accept ``-e <cmd>``; for those that don't, the command
    appears as an extra argv element which is harmless.
    """
    app_path = svc.platform_info.terminal_cmd
    subprocess.Popen(
        ["open", "-na", app_path, "--args", "-e", cmd],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def _launch_linux_gnome(svc: "TerminalService", cmd: str) -> None:
    subprocess.Popen(
        [svc.platform_info.terminal_cmd, "--", "bash", "-c", cmd + "; exec bash"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def _launch_linux_konsole(svc: "TerminalService", cmd: str) -> None:
    subprocess.Popen(
        [svc.platform_info.terminal_cmd, "-e", "bash", "-c", cmd + "; exec bash"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def _launch_linux_xfce(svc: "TerminalService", cmd: str) -> None:
    subprocess.Popen(
        [svc.platform_info.terminal_cmd, "--command", cmd],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def _launch_linux_tilix(svc: "TerminalService", cmd: str) -> None:
    subprocess.Popen(
        [svc.platform_info.terminal_cmd, "-e", cmd],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def _launch_linux_alacritty(svc: "TerminalService", cmd: str) -> None:
    """Alacritty / Kitty / WezTerm / Ghostty (Linux) — all support ``-e``."""
    subprocess.Popen(
        [svc.platform_info.terminal_cmd, "-e", "bash", "-c", cmd + "; exec bash"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def _launch_linux_generic(svc: "TerminalService", cmd: str) -> None:
    """xterm and last-resort fallback."""
    subprocess.Popen(
        [svc.platform_info.terminal_cmd, "-e", cmd],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def _launch_windows_wt(svc: "TerminalService", cmd: str) -> None:
    subprocess.Popen(
        [svc.platform_info.terminal_cmd, "cmd", "/k", cmd],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def _launch_windows_cmd(svc: "TerminalService", cmd: str) -> None:
    subprocess.Popen(
        ["cmd", "/c", "start", "cmd", "/k", cmd],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


_LAUNCHERS = {
    "macos_terminal": _launch_macos_terminal,
    "macos_iterm": _launch_macos_iterm,
    "macos_ghostty": _launch_macos_ghostty,
    "macos_open": _launch_macos_open,
    "linux_gnome": _launch_linux_gnome,
    "linux_konsole": _launch_linux_konsole,
    "linux_xfce": _launch_linux_xfce,
    "linux_tilix": _launch_linux_tilix,
    "linux_alacritty": _launch_linux_alacritty,
    "linux_generic": _launch_linux_generic,
    "windows_wt": _launch_windows_wt,
    "windows_cmd": _launch_windows_cmd,
    "generic": _launch_linux_generic,
}
