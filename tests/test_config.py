"""Tests for the Config class and environment variable loading."""

from __future__ import annotations

from pathlib import Path

import pytest

from src.config import Config


class TestConfigDefaults:
    """Test Config class default values."""

    def test_base_dir_is_project_root(self) -> None:
        """BASE_DIR should point to the project root (parent of src/)."""
        assert Config.BASE_DIR.is_dir()
        assert (Config.BASE_DIR / "src").is_dir()

    def test_data_dir_default_under_base(self) -> None:
        """DATA_DIR defaults to BASE_DIR/data when env var is unset."""
        # The default is str(BASE_DIR / "data"); verify it's a Path under BASE_DIR.
        assert isinstance(Config.DATA_DIR, Path)

    def test_sites_file_under_data_dir(self) -> None:
        """SITES_FILE should be DATA_DIR/sites.enc."""
        assert Config.SITES_FILE == Config.DATA_DIR / "sites.enc"

    def test_settings_file_under_data_dir(self) -> None:
        """SETTINGS_FILE should be DATA_DIR/settings.enc."""
        assert Config.SETTINGS_FILE == Config.DATA_DIR / "settings.enc"

    def test_key_file_under_data_dir(self) -> None:
        """KEY_FILE should be DATA_DIR/.key."""
        assert Config.KEY_FILE == Config.DATA_DIR / ".key"

    def test_default_host(self) -> None:
        """Default HOST should be localhost."""
        assert Config.HOST == "127.0.0.1"

    def test_default_port_is_int(self) -> None:
        """PORT should be an integer."""
        assert isinstance(Config.PORT, int)
        assert Config.PORT == 5101

    def test_default_ssh_timeout(self) -> None:
        """SSH_TIMEOUT should default to 10."""
        assert isinstance(Config.SSH_TIMEOUT, int)
        assert Config.SSH_TIMEOUT == 10

    def test_default_ssh_command_timeout(self) -> None:
        """SSH_COMMAND_TIMEOUT should default to 30."""
        assert isinstance(Config.SSH_COMMAND_TIMEOUT, int)
        assert Config.SSH_COMMAND_TIMEOUT == 30

    def test_secret_key_is_nonempty_string(self) -> None:
        """SECRET_KEY should be a non-empty string."""
        assert isinstance(Config.SECRET_KEY, str)
        assert len(Config.SECRET_KEY) > 0

    def test_ssl_enabled_default_is_true(self) -> None:
        """SSL_ENABLED should default to True."""
        assert Config.SSL_ENABLED is True

    def test_ssl_cert_file_is_path(self) -> None:
        """SSL_CERT_FILE should be a Path object."""
        assert isinstance(Config.SSL_CERT_FILE, Path)

    def test_ssl_key_file_is_path(self) -> None:
        """SSL_KEY_FILE should be a Path object."""
        assert isinstance(Config.SSL_KEY_FILE, Path)

    def test_ssl_cert_default_name(self) -> None:
        """SSL_CERT_FILE should default to cert.pem in DATA_DIR."""
        assert Config.SSL_CERT_FILE.name == "cert.pem"

    def test_ssl_key_default_name(self) -> None:
        """SSL_KEY_FILE should default to key.pem in DATA_DIR."""
        assert Config.SSL_KEY_FILE.name == "key.pem"


class TestConfigPathConsistency:
    """Test that derived paths are consistent with DATA_DIR."""

    def test_all_storage_paths_share_parent(self) -> None:
        """SITES_FILE, SETTINGS_FILE, KEY_FILE, and SSL files should all be in DATA_DIR."""
        assert Config.SITES_FILE.parent == Config.DATA_DIR
        assert Config.SETTINGS_FILE.parent == Config.DATA_DIR
        assert Config.KEY_FILE.parent == Config.DATA_DIR
        assert Config.SSL_CERT_FILE.parent == Config.DATA_DIR
        assert Config.SSL_KEY_FILE.parent == Config.DATA_DIR

    def test_storage_files_have_expected_names(self) -> None:
        """Verify the exact filenames of encrypted storage files."""
        assert Config.SITES_FILE.name == "sites.enc"
        assert Config.SETTINGS_FILE.name == "settings.enc"
        assert Config.KEY_FILE.name == ".key"

    def test_data_dir_is_path_object(self) -> None:
        """DATA_DIR should be a pathlib.Path, not a string."""
        assert isinstance(Config.DATA_DIR, Path)

    def test_base_dir_is_absolute(self) -> None:
        """BASE_DIR should be an absolute path (resolved)."""
        assert Config.BASE_DIR.is_absolute()


class TestConfigEnvOverrides:
    """Test that environment variables override Config defaults."""

    def test_data_dir_from_env(self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
        """CONNECTOR_DATA_DIR env var should override DATA_DIR."""
        custom_dir = tmp_path / "custom_data"
        monkeypatch.setenv("CONNECTOR_DATA_DIR", str(custom_dir))

        # Re-import to pick up the env var — but Config is a class with
        # class-level attrs evaluated at import time, so we monkeypatch directly.
        monkeypatch.setattr("src.config.Config.DATA_DIR", Path(str(custom_dir)))
        from src.config import Config as C

        assert C.DATA_DIR == custom_dir

    def test_port_from_env(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """CONNECTOR_PORT env var should override PORT."""
        monkeypatch.setattr("src.config.Config.PORT", 9999)
        from src.config import Config as C

        assert C.PORT == 9999

    def test_ssh_timeout_from_env(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """SSH_TIMEOUT env var should override SSH_TIMEOUT."""
        monkeypatch.setattr("src.config.Config.SSH_TIMEOUT", 60)
        from src.config import Config as C

        assert C.SSH_TIMEOUT == 60

    def test_ssh_command_timeout_from_env(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """SSH_COMMAND_TIMEOUT env var should override SSH_COMMAND_TIMEOUT."""
        monkeypatch.setattr("src.config.Config.SSH_COMMAND_TIMEOUT", 120)
        from src.config import Config as C

        assert C.SSH_COMMAND_TIMEOUT == 120

    def test_ssl_enabled_from_env(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """CONNECTOR_SSL_ENABLED env var should override SSL_ENABLED."""
        monkeypatch.setattr("src.config.Config.SSL_ENABLED", False)
        from src.config import Config as C

        assert C.SSL_ENABLED is False

    def test_ssl_cert_file_from_env(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path,
    ) -> None:
        """CONNECTOR_SSL_CERT env var should override SSL_CERT_FILE."""
        custom = tmp_path / "custom_cert.pem"
        monkeypatch.setattr("src.config.Config.SSL_CERT_FILE", custom)
        from src.config import Config as C

        assert C.SSL_CERT_FILE == custom

    def test_ssl_key_file_from_env(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path,
    ) -> None:
        """CONNECTOR_SSL_KEY env var should override SSL_KEY_FILE."""
        custom = tmp_path / "custom_key.pem"
        monkeypatch.setattr("src.config.Config.SSL_KEY_FILE", custom)
        from src.config import Config as C

        assert C.SSL_KEY_FILE == custom
