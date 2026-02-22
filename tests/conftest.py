"""Shared pytest fixtures for the Connector test suite."""

from __future__ import annotations

from pathlib import Path

import pytest

from src.app import create_app
from src.models.site import Site
from src.services.crypto_service import CryptoService
from src.services.settings_service import SettingsService
from src.services.storage import SiteStorage


@pytest.fixture()
def tmp_data_dir(tmp_path: Path) -> Path:
    """Return a temporary directory for encrypted data files."""
    data = tmp_path / "data"
    data.mkdir()
    return data


@pytest.fixture()
def crypto(tmp_data_dir: Path) -> CryptoService:
    """Return a CryptoService backed by a temporary key file."""
    return CryptoService(tmp_data_dir / ".key")


@pytest.fixture()
def storage(tmp_data_dir: Path, crypto: CryptoService) -> SiteStorage:
    """Return a SiteStorage backed by a temporary encrypted file."""
    return SiteStorage(tmp_data_dir / "sites.enc", crypto)


@pytest.fixture()
def settings_svc(tmp_data_dir: Path, crypto: CryptoService) -> SettingsService:
    """Return a SettingsService backed by a temporary encrypted file."""
    return SettingsService(tmp_data_dir / "settings.enc", crypto)


@pytest.fixture()
def sample_site() -> Site:
    """Return a sample site for testing."""
    return Site(
        name="Test Server",
        hostname="192.168.1.100",
        port=22,
        username="admin",
        auth_type="password",
        password="s3cret!",
        key_path="",
        notes="Test site for unit tests",
        id="test-uuid-1234",
    )


@pytest.fixture()
def sample_site_key() -> Site:
    """Return a sample site using key-based authentication."""
    return Site(
        name="Prod Server",
        hostname="10.0.0.50",
        port=2222,
        username="deploy",
        auth_type="key",
        password="",
        key_path="~/.ssh/id_ed25519",
        notes="Key-auth site",
        id="test-uuid-5678",
    )


@pytest.fixture()
def app(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    """Create a Flask test app with isolated temp data directory."""
    data_dir = tmp_path / "data"
    data_dir.mkdir()

    monkeypatch.setattr("src.config.Config.DATA_DIR", data_dir)
    monkeypatch.setattr("src.config.Config.SITES_FILE", data_dir / "sites.enc")
    monkeypatch.setattr("src.config.Config.SETTINGS_FILE", data_dir / "settings.enc")
    monkeypatch.setattr("src.config.Config.KEY_FILE", data_dir / ".key")
    monkeypatch.setattr("src.config.Config.SECRET_KEY", "test-secret-key")

    application = create_app()
    application.config["TESTING"] = True
    return application


@pytest.fixture()
def client(app):
    """Return a Flask test client."""
    return app.test_client()
