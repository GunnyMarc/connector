"""Tests for the encrypted SettingsService."""

from __future__ import annotations

from py_flask.services.settings_service import SettingsService


class TestSettingsDefaults:
    """Test that defaults are provided when no settings file exists."""

    def test_get_all_returns_defaults(
        self, settings_svc: SettingsService,
    ) -> None:
        """get_all returns the DEFAULTS when no settings are stored."""
        settings = settings_svc.get_all()
        assert settings["default_port"] == 22
        assert settings["ssh_timeout"] == 10
        assert settings["command_timeout"] == 30
        assert settings["default_username"] == ""
        assert settings["default_auth_type"] == "password"
        assert settings["default_key_path"] == "~/.ssh/id_rsa"
        assert settings["terminal_name"] == ""
        assert settings["terminal_path"] == ""

    def test_get_single_default(
        self, settings_svc: SettingsService,
    ) -> None:
        """get returns a single default value."""
        assert settings_svc.get("default_port") == 22

    def test_get_unknown_key(
        self, settings_svc: SettingsService,
    ) -> None:
        """get returns None for an unknown key."""
        assert settings_svc.get("nonexistent_key") is None


class TestSettingsUpdate:
    """Test persisting and retrieving settings."""

    def test_update_overrides_defaults(
        self, settings_svc: SettingsService,
    ) -> None:
        """Updated values override defaults."""
        settings_svc.update({"default_port": 2222, "ssh_timeout": 30})

        settings = settings_svc.get_all()
        assert settings["default_port"] == 2222
        assert settings["ssh_timeout"] == 30
        # Unchanged defaults preserved
        assert settings["command_timeout"] == 30
        assert settings["default_username"] == ""

    def test_update_persists(
        self, settings_svc: SettingsService,
    ) -> None:
        """Settings persist across get_all calls."""
        settings_svc.update({"default_username": "deploy"})
        assert settings_svc.get("default_username") == "deploy"

    def test_multiple_updates_merge(
        self, settings_svc: SettingsService,
    ) -> None:
        """Successive updates merge rather than replace."""
        settings_svc.update({"default_port": 2222})
        settings_svc.update({"ssh_timeout": 60})

        settings = settings_svc.get_all()
        assert settings["default_port"] == 2222
        assert settings["ssh_timeout"] == 60

    def test_update_returns_full_settings(
        self, settings_svc: SettingsService,
    ) -> None:
        """update() returns the full merged settings dict."""
        result = settings_svc.update({"default_port": 9999})
        assert result["default_port"] == 9999
        assert "ssh_timeout" in result
        assert "default_username" in result
