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


# ── Protocol-aware routes ─────────────────────────────────────────────────────


def _create_protocol_site(app, protocol: str, **kwargs) -> str:
    """Insert a site with the given protocol and return its ID."""
    storage: SiteStorage = app.config["STORAGE"]
    defaults = {
        "name": f"{protocol} test",
        "hostname": "10.0.0.1",
        "port": 22,
        "username": "root",
        "auth_type": "password",
        "password": "",
        "protocol": protocol,
        "id": f"proto-{protocol}-id",
    }
    defaults.update(kwargs)
    site = Site(**defaults)
    storage.create_site(site)
    return site.id


class TestProtocolRoutes:
    """Test protocol-aware behaviour across routes."""

    def test_create_local_shell_site(self, app, client: FlaskClient) -> None:
        """POST /sites/new with protocol=local creates a Local Shell site."""
        resp = client.post(
            "/sites/new",
            data={
                "name": "My Shell",
                "hostname": "",
                "port": "22",
                "protocol": "local",
            },
            follow_redirects=True,
        )
        assert resp.status_code == 200
        storage: SiteStorage = app.config["STORAGE"]
        sites = storage.list_sites()
        assert len(sites) == 1
        assert sites[0].protocol == "local"

    def test_create_serial_site(self, app, client: FlaskClient) -> None:
        """POST /sites/new with protocol=serial stores serial fields."""
        resp = client.post(
            "/sites/new",
            data={
                "name": "Serial Device",
                "hostname": "",
                "port": "22",
                "protocol": "serial",
                "serial_port": "/dev/ttyUSB0",
                "serial_baud": "115200",
            },
            follow_redirects=True,
        )
        assert resp.status_code == 200
        storage: SiteStorage = app.config["STORAGE"]
        site = storage.list_sites()[0]
        assert site.protocol == "serial"
        assert site.serial_port == "/dev/ttyUSB0"
        assert site.serial_baud == 115200

    def test_create_telnet_site(self, app, client: FlaskClient) -> None:
        """POST /sites/new with protocol=telnet creates a Telnet site."""
        resp = client.post(
            "/sites/new",
            data={
                "name": "Telnet Switch",
                "hostname": "switch.local",
                "port": "23",
                "protocol": "telnet",
                "username": "admin",
            },
            follow_redirects=True,
        )
        assert resp.status_code == 200
        storage: SiteStorage = app.config["STORAGE"]
        site = storage.list_sites()[0]
        assert site.protocol == "telnet"
        assert site.hostname == "switch.local"

    def test_create_raw_site(self, app, client: FlaskClient) -> None:
        """POST /sites/new with protocol=raw creates a Raw TCP site."""
        resp = client.post(
            "/sites/new",
            data={
                "name": "Raw TCP",
                "hostname": "10.0.0.5",
                "port": "4000",
                "protocol": "raw",
            },
            follow_redirects=True,
        )
        assert resp.status_code == 200
        storage: SiteStorage = app.config["STORAGE"]
        site = storage.list_sites()[0]
        assert site.protocol == "raw"
        assert site.port == 4000

    def test_edit_changes_protocol(self, app, client: FlaskClient) -> None:
        """POST edit can change a site's protocol."""
        site_id = _create_test_site(app)
        resp = client.post(
            f"/sites/{site_id}/edit",
            data={
                "name": "Route Test",
                "hostname": "",
                "port": "22",
                "protocol": "local",
            },
            follow_redirects=True,
        )
        assert resp.status_code == 200
        storage: SiteStorage = app.config["STORAGE"]
        site = storage.get_site(site_id)
        assert site.protocol == "local"

    def test_duplicate_preserves_protocol(self, app, client: FlaskClient) -> None:
        """Duplicating a site preserves its protocol."""
        site_id = _create_protocol_site(
            app, "serial", serial_port="/dev/ttyS0", serial_baud=57600,
        )
        resp = client.post(
            f"/sites/{site_id}/duplicate",
            follow_redirects=True,
        )
        assert resp.status_code == 200
        storage: SiteStorage = app.config["STORAGE"]
        sites = storage.list_sites()
        copy = [s for s in sites if s.name.endswith("(Copy)")][0]
        assert copy.protocol == "serial"
        assert copy.serial_port == "/dev/ttyS0"
        assert copy.serial_baud == 57600

    def test_ssh_page_shows_protocol_label(
        self, app, client: FlaskClient,
    ) -> None:
        """GET /sites/<id>/ssh shows the protocol label in the page."""
        site_id = _create_protocol_site(app, "telnet", hostname="switch.local")
        resp = client.get(f"/sites/{site_id}/ssh")
        assert resp.status_code == 200
        assert b"Telnet" in resp.data

    def test_index_shows_protocol_badge(
        self, app, client: FlaskClient,
    ) -> None:
        """Dashboard detail panel shows a protocol badge."""
        site_id = _create_protocol_site(app, "raw", hostname="10.0.0.1")
        resp = client.get(f"/?site={site_id}")
        assert resp.status_code == 200
        assert b"Raw" in resp.data

    def test_index_local_shell_no_sftp_button(
        self, app, client: FlaskClient,
    ) -> None:
        """Local Shell sessions should not show the SFTP button."""
        site_id = _create_protocol_site(app, "local")
        resp = client.get(f"/?site={site_id}")
        assert resp.status_code == 200
        assert b"SFTP" not in resp.data

    def test_index_ssh_site_shows_sftp_button(
        self, app, client: FlaskClient,
    ) -> None:
        """SSH sessions should show the SFTP button."""
        site_id = _create_protocol_site(app, "ssh2", hostname="server.com")
        resp = client.get(f"/?site={site_id}")
        assert resp.status_code == 200
        assert b"SFTP" in resp.data

    def test_default_protocol_when_omitted(
        self, app, client: FlaskClient,
    ) -> None:
        """Omitting protocol field from POST defaults to ssh2."""
        resp = client.post(
            "/sites/new",
            data={
                "name": "No Proto",
                "hostname": "host.com",
                "port": "22",
            },
            follow_redirects=True,
        )
        assert resp.status_code == 200
        storage: SiteStorage = app.config["STORAGE"]
        site = storage.list_sites()[0]
        assert site.protocol == "ssh2"

    def test_sidebar_shows_protocol_icon(
        self, app, client: FlaskClient,
    ) -> None:
        """Sidebar uses protocol-specific icon for Local Shell."""
        _create_protocol_site(app, "local")
        resp = client.get("/")
        assert resp.status_code == 200
        assert b"bi-terminal-fill" in resp.data
