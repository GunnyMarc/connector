"""Tests for TerminalService platform detection and SSH command building."""

from __future__ import annotations

from unittest.mock import patch

from src.services.terminal_service import (
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

    @patch("src.services.terminal_service.platform.system", return_value="Darwin")
    @patch("src.services.terminal_service.os.path.exists", return_value=True)
    @patch("src.services.terminal_service.shutil.which", return_value=None)
    def test_macos_detection(
        self, mock_which, mock_exists, mock_system,
    ) -> None:
        """macOS is detected as Darwin with Terminal app."""
        info = detect_platform()
        assert info.system == "Darwin"
        assert info.system_label == "macOS"

    @patch("src.services.terminal_service.platform.system", return_value="Linux")
    @patch("src.services.terminal_service.os.path.exists", return_value=False)
    @patch("src.services.terminal_service.shutil.which", return_value=None)
    def test_linux_detection_fallback(
        self, mock_which, mock_exists, mock_system,
    ) -> None:
        """Linux falls back to xterm when no terminals are found."""
        info = detect_platform()
        assert info.system == "Linux"
        assert info.terminal == "xterm"

    @patch("src.services.terminal_service.platform.system", return_value="Windows")
    @patch("src.services.terminal_service.os.path.exists", return_value=False)
    @patch("src.services.terminal_service.shutil.which", return_value=None)
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
