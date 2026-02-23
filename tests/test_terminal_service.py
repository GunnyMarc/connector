"""Tests for TerminalService platform detection and SSH command building."""

from __future__ import annotations

from types import SimpleNamespace
from unittest.mock import patch

from py_flask.services.terminal_service import (
    PlatformInfo,
    TerminalService,
    detect_platform,
)


class TestPlatformDetection:
    """Test the detect_platform() function."""

    def test_returns_platform_info(self) -> None:
        """detect_platform returns a PlatformInfo dataclass."""
        info = detect_platform()
        assert isinstance(info, PlatformInfo)
        assert info.system in ("Darwin", "Linux", "Windows")
        assert info.system_label in ("macOS", "Linux", "Windows")
        assert isinstance(info.has_sshpass, bool)
        assert info.terminal  # non-empty terminal name

    @patch("py_flask.services.terminal_service.platform.system", return_value="Darwin")
    @patch("py_flask.services.terminal_service.os.path.exists", return_value=True)
    @patch("py_flask.services.terminal_service.shutil.which", return_value=None)
    def test_macos_detection(
        self, mock_which, mock_exists, mock_system,
    ) -> None:
        """macOS is detected as Darwin with Terminal app."""
        info = detect_platform()
        assert info.system == "Darwin"
        assert info.system_label == "macOS"

    @patch("py_flask.services.terminal_service.platform.system", return_value="Linux")
    @patch("py_flask.services.terminal_service.os.path.exists", return_value=False)
    @patch("py_flask.services.terminal_service.shutil.which", return_value=None)
    def test_linux_detection_fallback(
        self, mock_which, mock_exists, mock_system,
    ) -> None:
        """Linux falls back to xterm when no terminals are found."""
        info = detect_platform()
        assert info.system == "Linux"
        assert info.terminal == "xterm"

    @patch("py_flask.services.terminal_service.platform.system", return_value="Windows")
    @patch("py_flask.services.terminal_service.os.path.exists", return_value=False)
    @patch("py_flask.services.terminal_service.shutil.which", return_value=None)
    def test_windows_detection_fallback(
        self, mock_which, mock_exists, mock_system,
    ) -> None:
        """Windows falls back to Command Prompt when wt is not found."""
        info = detect_platform()
        assert info.system == "Windows"
        assert info.terminal == "Command Prompt"


class TestSSHCommandBuilding:
    """Test _build_ssh_command for various configurations."""

    def _make_service(
        self, has_sshpass: bool = False, system: str = "Darwin",
    ) -> TerminalService:
        """Create a TerminalService with a controlled PlatformInfo."""
        info = PlatformInfo(
            system=system,
            system_label="macOS" if system == "Darwin" else system,
            terminal="Terminal",
            terminal_cmd="Terminal",
            has_sshpass=has_sshpass,
        )
        return TerminalService(info)

    def test_basic_ssh_command(self) -> None:
        """Builds a simple ssh command with user@host."""
        svc = self._make_service()
        cmd = svc._build_ssh_command(
            hostname="example.com", port=22, username="user",
        )
        assert "ssh" in cmd
        assert "user@example.com" in cmd

    def test_custom_port(self) -> None:
        """Non-default port is included with -p flag."""
        svc = self._make_service()
        cmd = svc._build_ssh_command(
            hostname="example.com", port=2222, username="user",
        )
        assert "-p" in cmd
        assert "2222" in cmd

    def test_default_port_omits_flag(self) -> None:
        """Default port 22 does not include -p flag."""
        svc = self._make_service()
        cmd = svc._build_ssh_command(
            hostname="example.com", port=22, username="user",
        )
        assert "-p" not in cmd

    def test_key_path(self) -> None:
        """Key path is included with -i flag."""
        svc = self._make_service()
        cmd = svc._build_ssh_command(
            hostname="example.com",
            port=22,
            username="user",
            key_path="~/.ssh/id_rsa",
        )
        assert "-i" in cmd

    def test_no_username(self) -> None:
        """Without username, just the hostname is used."""
        svc = self._make_service()
        cmd = svc._build_ssh_command(
            hostname="example.com", port=22, username="",
        )
        assert "example.com" in cmd
        assert "@" not in cmd

    def test_sshpass_integration(self) -> None:
        """With sshpass available, the command wraps with SSHPASS."""
        svc = self._make_service(has_sshpass=True)
        cmd = svc._build_ssh_command(
            hostname="example.com",
            port=22,
            username="user",
            password="s3cret!",
        )
        assert "SSHPASS" in cmd
        assert "sshpass -e" in cmd
        assert "unset SSHPASS" in cmd

    def test_no_sshpass_no_wrapping(self) -> None:
        """Without sshpass, password doesn't appear in the command."""
        svc = self._make_service(has_sshpass=False)
        cmd = svc._build_ssh_command(
            hostname="example.com",
            port=22,
            username="user",
            password="s3cret!",
        )
        assert "SSHPASS" not in cmd
        assert "sshpass" not in cmd

    def test_special_characters_in_password(self) -> None:
        """Passwords with special characters are shell-quoted."""
        svc = self._make_service(has_sshpass=True)
        cmd = svc._build_ssh_command(
            hostname="example.com",
            port=22,
            username="user",
            password="p@$$'w0rd\"!",
        )
        assert "SSHPASS" in cmd
        # The password should be shell-quoted (not appear raw)
        assert "p@$$'w0rd\"!" not in cmd


class TestProtocolCommandBuilding:
    """Test protocol-specific command builders."""

    def _make_service(
        self, has_sshpass: bool = False, system: str = "Darwin",
    ) -> TerminalService:
        """Create a TerminalService with a controlled PlatformInfo."""
        info = PlatformInfo(
            system=system,
            system_label="macOS" if system == "Darwin" else system,
            terminal="Terminal",
            terminal_cmd="Terminal",
            has_sshpass=has_sshpass,
        )
        return TerminalService(info)

    def _make_site(self, **kwargs) -> SimpleNamespace:
        """Build a minimal site-like object for testing."""
        defaults = {
            "name": "Test",
            "hostname": "example.com",
            "port": 22,
            "username": "user",
            "auth_type": "password",
            "password": "",
            "key_path": "",
            "protocol": "ssh2",
            "serial_port": "",
            "serial_baud": 9600,
        }
        defaults.update(kwargs)
        return SimpleNamespace(**defaults)

    def test_ssh2_command(self) -> None:
        """SSH2 protocol builds a standard ssh command."""
        svc = self._make_service()
        site = self._make_site(protocol="ssh2")
        cmd = svc._build_command_for_protocol(site, "ssh2")
        assert "ssh" in cmd
        assert "user@example.com" in cmd

    def test_ssh1_command_includes_protocol_option(self) -> None:
        """SSH1 protocol includes the Protocol=1 option."""
        svc = self._make_service()
        site = self._make_site(protocol="ssh1")
        cmd = svc._build_command_for_protocol(site, "ssh1")
        assert "Protocol=1" in cmd
        assert "ssh" in cmd

    def test_local_command(self) -> None:
        """Local Shell protocol opens the login shell."""
        svc = self._make_service()
        site = self._make_site(protocol="local")
        cmd = svc._build_command_for_protocol(site, "local")
        assert "--login" in cmd

    def test_raw_command(self) -> None:
        """Raw protocol uses netcat (nc)."""
        svc = self._make_service()
        site = self._make_site(protocol="raw", hostname="10.0.0.1", port=4000)
        cmd = svc._build_command_for_protocol(site, "raw")
        assert "nc" in cmd
        assert "10.0.0.1" in cmd
        assert "4000" in cmd

    def test_telnet_command_basic(self) -> None:
        """Telnet protocol uses telnet with hostname."""
        svc = self._make_service()
        site = self._make_site(
            protocol="telnet", hostname="switch.local", port=23, username="",
        )
        cmd = svc._build_command_for_protocol(site, "telnet")
        assert "telnet" in cmd
        assert "switch.local" in cmd
        # Default port 23 should not appear
        assert "23" not in cmd

    def test_telnet_command_with_username_and_port(self) -> None:
        """Telnet with username uses -l flag; non-default port is appended."""
        svc = self._make_service()
        site = self._make_site(
            protocol="telnet", hostname="router.lan", port=2323, username="admin",
        )
        cmd = svc._build_command_for_protocol(site, "telnet")
        assert "-l" in cmd
        assert "admin" in cmd
        assert "2323" in cmd

    def test_serial_command(self) -> None:
        """Serial protocol uses screen with device and baud rate."""
        svc = self._make_service()
        site = self._make_site(
            protocol="serial", serial_port="/dev/ttyUSB0", serial_baud=115200,
        )
        cmd = svc._build_command_for_protocol(site, "serial")
        assert "screen" in cmd
        assert "/dev/ttyUSB0" in cmd
        assert "115200" in cmd

    def test_serial_default_port(self) -> None:
        """Serial with empty port falls back to /dev/ttyUSB0."""
        svc = self._make_service()
        site = self._make_site(protocol="serial", serial_port="", serial_baud=9600)
        cmd = svc._build_command_for_protocol(site, "serial")
        assert "/dev/ttyUSB0" in cmd
        assert "9600" in cmd

    def test_unsupported_protocol_raises(self) -> None:
        """Unknown protocol raises RuntimeError."""
        svc = self._make_service()
        site = self._make_site(protocol="ftp")
        try:
            svc._build_command_for_protocol(site, "ftp")
            assert False, "Should have raised RuntimeError"
        except RuntimeError as exc:
            assert "Unsupported protocol" in str(exc)

    def test_ssh2_with_sshpass(self) -> None:
        """SSH2 with password and sshpass wraps with SSHPASS."""
        svc = self._make_service(has_sshpass=True)
        site = self._make_site(protocol="ssh2", password="secret")
        cmd = svc._build_command_for_protocol(site, "ssh2")
        assert "SSHPASS" in cmd
        assert "sshpass -e" in cmd

    def test_ssh1_with_key_auth(self) -> None:
        """SSH1 with key auth includes -i flag and Protocol=1."""
        svc = self._make_service()
        site = self._make_site(
            protocol="ssh1", auth_type="key", key_path="~/.ssh/id_rsa",
        )
        cmd = svc._build_command_for_protocol(site, "ssh1")
        assert "-i" in cmd
        assert "Protocol=1" in cmd
