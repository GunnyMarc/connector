"""Tests for Flask routes (sites, connections, settings)."""

from __future__ import annotations

from flask.testing import FlaskClient

from src.models.site import Site
from src.services.storage import SiteStorage


# ── Helper ────────────────────────────────────────────────────────────────────


def _create_test_site(app) -> str:
    """Insert a test site and return its ID."""
    storage: SiteStorage = app.config["STORAGE"]
    site = Site(
        name="Route Test",
        hostname="10.0.0.1",
        port=22,
        username="root",
        auth_type="password",
        password="secret",
        id="route-test-id",
    )
    storage.create_site(site)
    return site.id


# ── Dashboard / Index ─────────────────────────────────────────────────────────


class TestIndex:
    """Test the main dashboard route."""

    def test_index_empty(self, client: FlaskClient) -> None:
        """Dashboard loads with no sites."""
        resp = client.get("/")
        assert resp.status_code == 200
        assert b"Connector" in resp.data

    def test_index_with_sites(self, app, client: FlaskClient) -> None:
        """Dashboard loads when sites exist."""
        _create_test_site(app)
        resp = client.get("/")
        assert resp.status_code == 200
        assert b"Route Test" in resp.data

    def test_index_with_selected_site(self, app, client: FlaskClient) -> None:
        """Dashboard shows site details when ?site= is provided."""
        site_id = _create_test_site(app)
        resp = client.get(f"/?site={site_id}")
        assert resp.status_code == 200
        assert b"Route Test" in resp.data


# ── Site CRUD ─────────────────────────────────────────────────────────────────


class TestSiteCRUD:
    """Test site create, edit, delete, duplicate routes."""

    def test_create_form_get(self, client: FlaskClient) -> None:
        """GET /sites/new renders the creation form."""
        resp = client.get("/sites/new")
        assert resp.status_code == 200
        assert b"form" in resp.data.lower()

    def test_create_site_post(self, app, client: FlaskClient) -> None:
        """POST /sites/new creates a site and redirects."""
        resp = client.post(
            "/sites/new",
            data={
                "name": "New Site",
                "hostname": "new.example.com",
                "port": "22",
                "username": "admin",
                "auth_type": "password",
                "password": "pass",
            },
            follow_redirects=True,
        )
        assert resp.status_code == 200
        assert b"New Site" in resp.data

        storage: SiteStorage = app.config["STORAGE"]
        assert len(storage.list_sites()) == 1

    def test_edit_form_get(self, app, client: FlaskClient) -> None:
        """GET /sites/<id>/edit renders the edit form."""
        site_id = _create_test_site(app)
        resp = client.get(f"/sites/{site_id}/edit")
        assert resp.status_code == 200
        assert b"Route Test" in resp.data

    def test_edit_site_post(self, app, client: FlaskClient) -> None:
        """POST /sites/<id>/edit updates the site."""
        site_id = _create_test_site(app)
        resp = client.post(
            f"/sites/{site_id}/edit",
            data={
                "name": "Updated Name",
                "hostname": "10.0.0.1",
                "port": "22",
                "username": "root",
                "auth_type": "password",
                "password": "newpass",
            },
            follow_redirects=True,
        )
        assert resp.status_code == 200
        assert b"Updated Name" in resp.data

    def test_edit_nonexistent(self, client: FlaskClient) -> None:
        """Editing a nonexistent site redirects with flash."""
        resp = client.get("/sites/no-such-id/edit")
        assert resp.status_code == 302  # redirect

    def test_duplicate_site(self, app, client: FlaskClient) -> None:
        """POST /sites/<id>/duplicate creates a copy."""
        site_id = _create_test_site(app)
        resp = client.post(
            f"/sites/{site_id}/duplicate",
            follow_redirects=True,
        )
        assert resp.status_code == 200

        storage: SiteStorage = app.config["STORAGE"]
        sites = storage.list_sites()
        assert len(sites) == 2
        names = [s.name for s in sites]
        assert "Route Test (Copy)" in names

    def test_delete_site(self, app, client: FlaskClient) -> None:
        """POST /sites/<id>/delete removes the site."""
        site_id = _create_test_site(app)
        resp = client.post(
            f"/sites/{site_id}/delete",
            follow_redirects=True,
        )
        assert resp.status_code == 200

        storage: SiteStorage = app.config["STORAGE"]
        assert len(storage.list_sites()) == 0

    def test_delete_nonexistent(self, client: FlaskClient) -> None:
        """Deleting a nonexistent site redirects gracefully."""
        resp = client.post("/sites/no-such-id/delete")
        assert resp.status_code == 302  # redirect


# ── SSH Route ─────────────────────────────────────────────────────────────────


class TestSSHRoute:
    """Test the SSH connection page."""

    def test_ssh_page_get(self, app, client: FlaskClient) -> None:
        """GET /sites/<id>/ssh renders the SSH page."""
        site_id = _create_test_site(app)
        resp = client.get(f"/sites/{site_id}/ssh")
        assert resp.status_code == 200
        assert b"Route Test" in resp.data

    def test_ssh_nonexistent_site(self, client: FlaskClient) -> None:
        """SSH for a nonexistent site redirects."""
        resp = client.get("/sites/no-such-id/ssh")
        assert resp.status_code == 302


# ── Quick Connect ─────────────────────────────────────────────────────────────


class TestQuickConnect:
    """Test the quick-connect route."""

    def test_empty_host(self, client: FlaskClient) -> None:
        """Empty host string flashes a warning and redirects."""
        resp = client.post("/quick-connect", data={"host": ""})
        assert resp.status_code == 302

    def test_invalid_port(self, client: FlaskClient) -> None:
        """Invalid port in host string flashes an error."""
        resp = client.post(
            "/quick-connect",
            data={"host": "user@example.com:notaport"},
        )
        assert resp.status_code == 302


# ── Settings ──────────────────────────────────────────────────────────────────


class TestSettingsRoute:
    """Test the global settings page."""

    def test_settings_get(self, client: FlaskClient) -> None:
        """GET /settings renders the settings form."""
        resp = client.get("/settings")
        assert resp.status_code == 200
        assert b"settings" in resp.data.lower()

    def test_settings_post(self, app, client: FlaskClient) -> None:
        """POST /settings updates and redirects."""
        resp = client.post(
            "/settings",
            data={
                "default_port": "2222",
                "ssh_timeout": "15",
                "command_timeout": "60",
                "default_username": "deploy",
                "default_auth_type": "key",
                "default_key_path": "~/.ssh/id_ed25519",
            },
            follow_redirects=True,
        )
        assert resp.status_code == 200

        from src.services.settings_service import SettingsService
        svc: SettingsService = app.config["SETTINGS"]
        settings = svc.get_all()
        assert settings["default_port"] == 2222
        assert settings["default_username"] == "deploy"


# ── SFTP Route ────────────────────────────────────────────────────────────────


class TestSFTPRoute:
    """Test SFTP routes (without actual SSH connection)."""

    def test_sftp_nonexistent_site(self, client: FlaskClient) -> None:
        """SFTP for a nonexistent site redirects."""
        resp = client.get("/sites/no-such-id/sftp")
        assert resp.status_code == 302

    def test_sftp_page_renders_with_error(
        self, app, client: FlaskClient,
    ) -> None:
        """SFTP page renders gracefully when connection fails."""
        site_id = _create_test_site(app)
        resp = client.get(f"/sites/{site_id}/sftp")
        # Should render (200) with an error message, not crash
        assert resp.status_code == 200
