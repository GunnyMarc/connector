"""Tests for the SSH service dataclasses and SSHService connection logic.

Covers CommandResult, RemoteFile dataclasses, SSHService error guards,
context-manager protocol, and connect() credential routing. All tests
use mocked paramiko — no live SSH server required.
"""

from __future__ import annotations

from unittest.mock import MagicMock, patch

import pytest

from src.models.site import Site
from src.services.ssh_service import CommandResult, RemoteFile, SSHService


# ── CommandResult dataclass ───────────────────────────────────────────────


class TestCommandResult:
    """Test CommandResult dataclass fields and behaviour."""

    def test_stores_all_fields(self) -> None:
        """CommandResult should store stdout, stderr, and exit_code."""
        result = CommandResult(stdout="hello", stderr="", exit_code=0)
        assert result.stdout == "hello"
        assert result.stderr == ""
        assert result.exit_code == 0

    def test_nonzero_exit_code(self) -> None:
        """CommandResult should store non-zero exit codes."""
        result = CommandResult(stdout="", stderr="fail", exit_code=1)
        assert result.exit_code == 1
        assert result.stderr == "fail"

    def test_multiline_output(self) -> None:
        """CommandResult should preserve multiline stdout."""
        output = "line1\nline2\nline3"
        result = CommandResult(stdout=output, stderr="", exit_code=0)
        assert result.stdout.count("\n") == 2

    def test_unicode_output(self) -> None:
        """CommandResult should handle unicode characters."""
        result = CommandResult(stdout="日本語テスト", stderr="", exit_code=0)
        assert result.stdout == "日本語テスト"


# ── RemoteFile dataclass ──────────────────────────────────────────────────


class TestRemoteFile:
    """Test RemoteFile dataclass fields and behaviour."""

    def test_stores_all_fields(self) -> None:
        """RemoteFile should store name, path, is_dir, size, and modified."""
        rf = RemoteFile(
            name="readme.txt",
            path="/home/user/readme.txt",
            is_dir=False,
            size=1024,
            modified="1700000000",
        )
        assert rf.name == "readme.txt"
        assert rf.path == "/home/user/readme.txt"
        assert rf.is_dir is False
        assert rf.size == 1024
        assert rf.modified == "1700000000"

    def test_directory_entry(self) -> None:
        """RemoteFile can represent a directory."""
        rf = RemoteFile(
            name="subdir",
            path="/home/user/subdir",
            is_dir=True,
            size=4096,
            modified="1700000000",
        )
        assert rf.is_dir is True

    def test_unique_identity(self) -> None:
        """Two RemoteFile instances with different paths are distinct."""
        a = RemoteFile(name="a.txt", path="/a.txt", is_dir=False, size=0, modified="")
        b = RemoteFile(name="b.txt", path="/b.txt", is_dir=False, size=0, modified="")
        assert a != b

    def test_root_path(self) -> None:
        """RemoteFile at root level should have correct path."""
        rf = RemoteFile(
            name="etc",
            path="/etc",
            is_dir=True,
            size=0,
            modified="",
        )
        assert rf.path == "/etc"


# ── SSHService error guards ──────────────────────────────────────────────


class TestSSHServiceNotConnected:
    """Test SSHService methods raise ConnectionError when not connected."""

    def _make_service(self) -> SSHService:
        """Create an SSHService with a dummy site (not connected)."""
        site = Site(name="Test", hostname="example.com", username="user")
        return SSHService(site)

    def test_execute_raises_when_not_connected(self) -> None:
        """execute() should raise ConnectionError if connect() was not called."""
        svc = self._make_service()
        with pytest.raises(ConnectionError, match="Not connected"):
            svc.execute("whoami")

    def test_sftp_normalize_raises_when_not_connected(self) -> None:
        """sftp_normalize() should raise ConnectionError if not connected."""
        svc = self._make_service()
        with pytest.raises(ConnectionError, match="Not connected"):
            svc.sftp_normalize(".")

    def test_sftp_list_raises_when_not_connected(self) -> None:
        """sftp_list() should raise ConnectionError if not connected."""
        svc = self._make_service()
        with pytest.raises(ConnectionError, match="Not connected"):
            svc.sftp_list("/tmp")

    def test_sftp_download_raises_when_not_connected(self) -> None:
        """sftp_download() should raise ConnectionError if not connected."""
        svc = self._make_service()
        with pytest.raises(ConnectionError, match="Not connected"):
            svc.sftp_download("/remote/file", "/local/file")

    def test_sftp_upload_raises_when_not_connected(self) -> None:
        """sftp_upload() should raise ConnectionError if not connected."""
        svc = self._make_service()
        with pytest.raises(ConnectionError, match="Not connected"):
            svc.sftp_upload("/local/file", "/remote/file")


# ── SSHService context manager ────────────────────────────────────────────


class TestSSHServiceContextManager:
    """Test SSHService context-manager protocol."""

    @patch("src.services.ssh_service.paramiko.SSHClient")
    def test_enter_calls_connect(self, mock_client_cls: MagicMock) -> None:
        """__enter__ should call connect() and return the service."""
        site = Site(name="Test", hostname="example.com", username="user")
        svc = SSHService(site)

        result = svc.__enter__()

        assert result is svc
        mock_client_cls.return_value.connect.assert_called_once()

    @patch("src.services.ssh_service.paramiko.SSHClient")
    def test_exit_calls_disconnect(self, mock_client_cls: MagicMock) -> None:
        """__exit__ should close the SSH client."""
        site = Site(name="Test", hostname="example.com", username="user")
        svc = SSHService(site)

        svc.__enter__()
        svc.__exit__(None, None, None)

        mock_client_cls.return_value.close.assert_called_once()

    @patch("src.services.ssh_service.paramiko.SSHClient")
    def test_with_statement(self, mock_client_cls: MagicMock) -> None:
        """SSHService should work as a context manager with 'with' statement."""
        site = Site(name="Test", hostname="example.com", username="user")

        with SSHService(site) as svc:
            assert svc is not None

        mock_client_cls.return_value.connect.assert_called_once()
        mock_client_cls.return_value.close.assert_called_once()


# ── SSHService connect() credential routing ───────────────────────────────


class TestSSHServiceConnect:
    """Test connect() builds correct paramiko kwargs based on auth type."""

    @patch("src.services.ssh_service.paramiko.SSHClient")
    def test_password_auth(self, mock_client_cls: MagicMock) -> None:
        """Password auth should pass 'password' kwarg to paramiko."""
        site = Site(
            name="PWD",
            hostname="10.0.0.1",
            port=22,
            username="admin",
            auth_type="password",
            password="secret",
        )
        svc = SSHService(site)
        svc.connect()

        call_kwargs = mock_client_cls.return_value.connect.call_args
        assert call_kwargs.kwargs.get("password") == "secret"
        assert "key_filename" not in call_kwargs.kwargs

    @patch("src.services.ssh_service.paramiko.SSHClient")
    def test_key_auth(self, mock_client_cls: MagicMock) -> None:
        """Key auth should pass 'key_filename' kwarg to paramiko."""
        site = Site(
            name="KEY",
            hostname="10.0.0.1",
            port=2222,
            username="deploy",
            auth_type="key",
            key_path="~/.ssh/id_rsa",
        )
        svc = SSHService(site)
        svc.connect()

        call_kwargs = mock_client_cls.return_value.connect.call_args
        assert "key_filename" in call_kwargs.kwargs
        assert "password" not in call_kwargs.kwargs

    @patch("src.services.ssh_service.paramiko.SSHClient")
    def test_connect_passes_hostname_and_port(self, mock_client_cls: MagicMock) -> None:
        """connect() should pass hostname and port to paramiko."""
        site = Site(name="Test", hostname="myhost.com", port=2222, username="user")
        svc = SSHService(site)
        svc.connect()

        call_kwargs = mock_client_cls.return_value.connect.call_args
        assert call_kwargs.kwargs["hostname"] == "myhost.com"
        assert call_kwargs.kwargs["port"] == 2222

    @patch("src.services.ssh_service.paramiko.SSHClient")
    def test_connect_passes_username(self, mock_client_cls: MagicMock) -> None:
        """connect() should pass username to paramiko."""
        site = Site(name="Test", hostname="host", username="testuser")
        svc = SSHService(site)
        svc.connect()

        call_kwargs = mock_client_cls.return_value.connect.call_args
        assert call_kwargs.kwargs["username"] == "testuser"

    @patch("src.services.ssh_service.paramiko.SSHClient")
    def test_connect_sets_auto_add_policy(self, mock_client_cls: MagicMock) -> None:
        """connect() should set AutoAddPolicy for host key verification."""
        site = Site(name="Test", hostname="host", username="user")
        svc = SSHService(site)
        svc.connect()

        mock_client_cls.return_value.set_missing_host_key_policy.assert_called_once()

    @patch("src.services.ssh_service.paramiko.SSHClient")
    def test_connect_includes_timeout(self, mock_client_cls: MagicMock) -> None:
        """connect() should include timeout from Config."""
        site = Site(name="Test", hostname="host", username="user")
        svc = SSHService(site)
        svc.connect()

        call_kwargs = mock_client_cls.return_value.connect.call_args
        assert "timeout" in call_kwargs.kwargs
        assert isinstance(call_kwargs.kwargs["timeout"], int)


# ── SSHService disconnect ─────────────────────────────────────────────────


class TestSSHServiceDisconnect:
    """Test disconnect() behaviour."""

    def test_disconnect_without_connect(self) -> None:
        """disconnect() should be safe to call even if never connected."""
        site = Site(name="Test", hostname="host", username="user")
        svc = SSHService(site)
        # Should not raise
        svc.disconnect()

    @patch("src.services.ssh_service.paramiko.SSHClient")
    def test_disconnect_clears_client(self, mock_client_cls: MagicMock) -> None:
        """disconnect() should set _client to None after closing."""
        site = Site(name="Test", hostname="host", username="user")
        svc = SSHService(site)
        svc.connect()
        svc.disconnect()

        # After disconnect, execute should raise ConnectionError (client is None)
        with pytest.raises(ConnectionError):
            svc.execute("test")

    @patch("src.services.ssh_service.paramiko.SSHClient")
    def test_double_disconnect(self, mock_client_cls: MagicMock) -> None:
        """Calling disconnect() twice should be safe."""
        site = Site(name="Test", hostname="host", username="user")
        svc = SSHService(site)
        svc.connect()
        svc.disconnect()
        svc.disconnect()  # Should not raise


# ── SSHService execute ────────────────────────────────────────────────────


class TestSSHServiceExecute:
    """Test execute() with mocked paramiko client."""

    @patch("src.services.ssh_service.paramiko.SSHClient")
    def test_returns_command_result(self, mock_client_cls: MagicMock) -> None:
        """execute() should return a CommandResult with stdout, stderr, exit_code."""
        mock_client = mock_client_cls.return_value
        mock_stdout = MagicMock()
        mock_stdout.read.return_value = b"hello world"
        mock_stdout.channel.recv_exit_status.return_value = 0
        mock_stderr = MagicMock()
        mock_stderr.read.return_value = b""
        mock_client.exec_command.return_value = (MagicMock(), mock_stdout, mock_stderr)

        site = Site(name="Test", hostname="host", username="user")
        svc = SSHService(site)
        svc.connect()
        result = svc.execute("echo hello world")

        assert isinstance(result, CommandResult)
        assert result.stdout == "hello world"
        assert result.stderr == ""
        assert result.exit_code == 0

    @patch("src.services.ssh_service.paramiko.SSHClient")
    def test_captures_stderr(self, mock_client_cls: MagicMock) -> None:
        """execute() should capture stderr output."""
        mock_client = mock_client_cls.return_value
        mock_stdout = MagicMock()
        mock_stdout.read.return_value = b""
        mock_stdout.channel.recv_exit_status.return_value = 2
        mock_stderr = MagicMock()
        mock_stderr.read.return_value = b"command not found"
        mock_client.exec_command.return_value = (MagicMock(), mock_stdout, mock_stderr)

        site = Site(name="Test", hostname="host", username="user")
        svc = SSHService(site)
        svc.connect()
        result = svc.execute("badcommand")

        assert result.stderr == "command not found"
        assert result.exit_code == 2
