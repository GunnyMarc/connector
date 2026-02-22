"""Tests for Flask routes (sites, connections, settings)."""

from __future__ import annotations

import io
import json
from unittest.mock import patch

from flask.testing import FlaskClient

from src.models.site import Site
from src.services.settings_service import SettingsService
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


# ── Export ────────────────────────────────────────────────────────────────────


def _create_export_site(app, **overrides) -> str:
    """Insert a site with sensible defaults for export tests; return its ID."""
    storage: SiteStorage = app.config["STORAGE"]
    defaults = {
        "name": "Export Me",
        "hostname": "export.example.com",
        "port": 22,
        "username": "deployer",
        "auth_type": "password",
        "password": "supersecret",
        "key_path": "~/.ssh/id_rsa",
        "folder": "Production",
        "protocol": "ssh2",
    }
    defaults.update(overrides)
    site = Site(**defaults)
    storage.create_site(site)
    return site.id


class TestExport:
    """Test GET /settings/export."""

    def test_export_returns_json(self, app, client: FlaskClient) -> None:
        """Export response has application/json mimetype."""
        _create_export_site(app)
        resp = client.get("/settings/export")
        assert resp.status_code == 200
        assert resp.mimetype == "application/json"

    def test_export_attachment_filename(
        self, app, client: FlaskClient,
    ) -> None:
        """Export sets Content-Disposition with a timestamp filename."""
        _create_export_site(app)
        resp = client.get("/settings/export")
        cd = resp.headers.get("Content-Disposition", "")
        assert "attachment" in cd
        assert "connector_export_" in cd
        assert cd.endswith('.json"')

    def test_export_has_connector_flag(
        self, app, client: FlaskClient,
    ) -> None:
        """Export payload contains ``connector_export: true`` and version."""
        _create_export_site(app)
        resp = client.get("/settings/export")
        data = json.loads(resp.data)
        assert data["connector_export"] is True
        assert data["version"] == 1
        assert "exported_at" in data

    def test_export_strips_password(self, app, client: FlaskClient) -> None:
        """Exported sites must not include the password field."""
        _create_export_site(app, password="topsecret")
        resp = client.get("/settings/export")
        data = json.loads(resp.data)
        assert len(data["sites"]) == 1
        assert "password" not in data["sites"][0]

    def test_export_strips_key_path(self, app, client: FlaskClient) -> None:
        """Exported sites must not include the key_path field."""
        _create_export_site(app, key_path="/home/user/.ssh/id_rsa")
        resp = client.get("/settings/export")
        data = json.loads(resp.data)
        assert "key_path" not in data["sites"][0]

    def test_export_preserves_username(
        self, app, client: FlaskClient,
    ) -> None:
        """Exported sites preserve the username field."""
        _create_export_site(app, username="webadmin")
        resp = client.get("/settings/export")
        data = json.loads(resp.data)
        assert data["sites"][0]["username"] == "webadmin"

    def test_export_preserves_hostname_and_protocol(
        self, app, client: FlaskClient,
    ) -> None:
        """Exported sites preserve hostname, protocol, and folder."""
        _create_export_site(
            app,
            hostname="db.internal",
            protocol="telnet",
            folder="Infra",
        )
        resp = client.get("/settings/export")
        data = json.loads(resp.data)
        site = data["sites"][0]
        assert site["hostname"] == "db.internal"
        assert site["protocol"] == "telnet"
        assert site["folder"] == "Infra"

    def test_export_includes_folders(self, app, client: FlaskClient) -> None:
        """Export payload contains the folders list from settings."""
        svc: SettingsService = app.config["SETTINGS"]
        svc.update({"folders": ["AWS", "AWS/Production", "GCP"]})
        _create_export_site(app)

        resp = client.get("/settings/export")
        data = json.loads(resp.data)
        assert data["folders"] == ["AWS", "AWS/Production", "GCP"]

    def test_export_empty_no_sites(self, client: FlaskClient) -> None:
        """Export with no sites returns an empty sites list."""
        resp = client.get("/settings/export")
        data = json.loads(resp.data)
        assert data["sites"] == []
        assert data["connector_export"] is True

    def test_export_multiple_sites(self, app, client: FlaskClient) -> None:
        """Export includes all sites, each without credentials."""
        _create_export_site(app, name="Site A", id="a-id")
        _create_export_site(app, name="Site B", id="b-id")
        resp = client.get("/settings/export")
        data = json.loads(resp.data)
        assert len(data["sites"]) == 2
        for site in data["sites"]:
            assert "password" not in site
            assert "key_path" not in site


# ── Import ────────────────────────────────────────────────────────────────────


def _make_export_payload(
    sites: list[dict] | None = None,
    folders: list[str] | None = None,
) -> dict:
    """Build a valid Connector export payload dict."""
    return {
        "connector_export": True,
        "version": 1,
        "exported_at": "2025-01-01T00:00:00Z",
        "folders": folders or [],
        "sites": sites or [],
    }


def _upload_json(client: FlaskClient, payload: dict | str):
    """POST a JSON payload to /settings/import as a file upload."""
    raw = payload if isinstance(payload, str) else json.dumps(payload)
    data = {
        "import_file": (io.BytesIO(raw.encode("utf-8")), "export.json"),
    }
    return client.post(
        "/settings/import",
        data=data,
        content_type="multipart/form-data",
        follow_redirects=True,
    )


class TestImport:
    """Test POST /settings/import."""

    def test_import_creates_sites(self, app, client: FlaskClient) -> None:
        """Importing valid JSON creates sites in storage."""
        payload = _make_export_payload(
            sites=[
                {
                    "name": "Imported Server",
                    "hostname": "import.host.com",
                    "port": 22,
                    "username": "ops",
                    "protocol": "ssh2",
                    "folder": "",
                },
            ],
        )
        resp = _upload_json(client, payload)
        assert resp.status_code == 200

        storage: SiteStorage = app.config["STORAGE"]
        sites = storage.list_sites()
        assert len(sites) == 1
        assert sites[0].name == "Imported Server"
        assert sites[0].hostname == "import.host.com"

    def test_import_assigns_fresh_uuids(
        self, app, client: FlaskClient,
    ) -> None:
        """Imported sites get new UUIDs, not the ones from the file."""
        payload = _make_export_payload(
            sites=[
                {
                    "id": "old-uuid-1234",
                    "name": "UUID Test",
                    "hostname": "host.com",
                    "port": 22,
                    "protocol": "ssh2",
                },
            ],
        )
        _upload_json(client, payload)

        storage: SiteStorage = app.config["STORAGE"]
        sites = storage.list_sites()
        assert len(sites) == 1
        assert sites[0].id != "old-uuid-1234"

    def test_import_blanks_credentials(
        self, app, client: FlaskClient,
    ) -> None:
        """Imported sites have empty password and key_path."""
        payload = _make_export_payload(
            sites=[
                {
                    "name": "Cred Test",
                    "hostname": "host.com",
                    "port": 22,
                    "username": "admin",
                    "password": "hacked-in",
                    "key_path": "/sneaky/key",
                    "protocol": "ssh2",
                },
            ],
        )
        _upload_json(client, payload)

        storage: SiteStorage = app.config["STORAGE"]
        site = storage.list_sites()[0]
        assert site.password == ""
        assert site.key_path == ""

    def test_import_merges_folders(self, app, client: FlaskClient) -> None:
        """Import merges new folders with existing ones."""
        svc: SettingsService = app.config["SETTINGS"]
        svc.update({"folders": ["Existing"]})

        payload = _make_export_payload(
            folders=["Existing", "New Folder", "Another"],
        )
        _upload_json(client, payload)

        settings = svc.get_all()
        folders = settings["folders"]
        assert "Existing" in folders
        assert "New Folder" in folders
        assert "Another" in folders
        # "Existing" should not be duplicated.
        assert folders.count("Existing") == 1

    def test_import_skips_duplicates(
        self, app, client: FlaskClient,
    ) -> None:
        """Sites matching (name, hostname, protocol) are skipped."""
        # Pre-create a site.
        _create_export_site(
            app,
            name="Dup Site",
            hostname="dup.host.com",
            protocol="ssh2",
        )

        payload = _make_export_payload(
            sites=[
                {
                    "name": "Dup Site",
                    "hostname": "dup.host.com",
                    "protocol": "ssh2",
                    "port": 22,
                },
                {
                    "name": "Fresh Site",
                    "hostname": "fresh.host.com",
                    "protocol": "ssh2",
                    "port": 22,
                },
            ],
        )
        resp = _upload_json(client, payload)
        assert resp.status_code == 200

        storage: SiteStorage = app.config["STORAGE"]
        sites = storage.list_sites()
        names = [s.name for s in sites]
        assert names.count("Dup Site") == 1
        assert "Fresh Site" in names
        assert len(sites) == 2

    def test_import_rejects_invalid_json(
        self, client: FlaskClient,
    ) -> None:
        """Non-JSON file is rejected with a flash message."""
        resp = _upload_json(client, "this is not json {{{")
        assert resp.status_code == 200
        assert b"Invalid JSON" in resp.data

    def test_import_rejects_non_connector_file(
        self, client: FlaskClient,
    ) -> None:
        """Valid JSON without connector_export flag is rejected."""
        resp = _upload_json(client, {"some_key": "some_value"})
        assert resp.status_code == 200
        assert b"not a valid Connector export" in resp.data

    def test_import_no_file_selected(self, client: FlaskClient) -> None:
        """POST with no file flashes an error."""
        resp = client.post(
            "/settings/import",
            data={},
            content_type="multipart/form-data",
            follow_redirects=True,
        )
        assert resp.status_code == 200
        assert b"No file selected" in resp.data

    def test_import_empty_file(self, client: FlaskClient) -> None:
        """Empty file upload is treated as invalid JSON."""
        data = {
            "import_file": (io.BytesIO(b""), "empty.json"),
        }
        resp = client.post(
            "/settings/import",
            data=data,
            content_type="multipart/form-data",
            follow_redirects=True,
        )
        assert resp.status_code == 200
        assert b"Invalid JSON" in resp.data

    def test_import_preserves_username(
        self, app, client: FlaskClient,
    ) -> None:
        """Imported sites keep the username from the export file."""
        payload = _make_export_payload(
            sites=[
                {
                    "name": "User Test",
                    "hostname": "host.com",
                    "port": 22,
                    "username": "imported_user",
                    "protocol": "ssh2",
                },
            ],
        )
        _upload_json(client, payload)

        storage: SiteStorage = app.config["STORAGE"]
        site = storage.list_sites()[0]
        assert site.username == "imported_user"

    def test_import_flash_summary(self, app, client: FlaskClient) -> None:
        """Import flashes a summary with imported and skipped counts."""
        # Pre-create a duplicate.
        _create_export_site(
            app, name="Already Here", hostname="h.com", protocol="ssh2",
        )

        payload = _make_export_payload(
            sites=[
                {
                    "name": "Already Here",
                    "hostname": "h.com",
                    "protocol": "ssh2",
                    "port": 22,
                },
                {
                    "name": "New One",
                    "hostname": "n.com",
                    "protocol": "ssh2",
                    "port": 22,
                },
            ],
        )
        resp = _upload_json(client, payload)
        assert b"1 session(s) imported" in resp.data
        assert b"1 skipped" in resp.data

    def test_import_no_sessions_in_file(
        self, client: FlaskClient,
    ) -> None:
        """Import file with no sites array flashes informational message."""
        payload = _make_export_payload(sites=[])
        resp = _upload_json(client, payload)
        assert resp.status_code == 200
        assert b"No sessions found" in resp.data


# ── Browse Key ────────────────────────────────────────────────────────────────


class TestBrowseKey:
    """Test POST /api/browse-key (native file dialog)."""

    def test_returns_json(self, client: FlaskClient) -> None:
        """Endpoint returns JSON with a 'path' key."""
        with patch("src.routes.sites.subprocess.run") as mock_run:
            mock_run.return_value.returncode = 1  # cancelled
            mock_run.return_value.stdout = ""
            resp = client.post("/api/browse-key")
        assert resp.status_code == 200
        assert resp.content_type.startswith("application/json")
        data = json.loads(resp.data)
        assert "path" in data

    def test_returns_selected_path_macos(
        self, app, client: FlaskClient,
    ) -> None:
        """On macOS, returns the path chosen via osascript."""
        app.config["PLATFORM_INFO"].system = "Darwin"
        with patch("src.routes.sites.subprocess.run") as mock_run:
            mock_run.return_value.returncode = 0
            mock_run.return_value.stdout = "/Users/me/.ssh/id_ed25519\n"
            resp = client.post("/api/browse-key")
        data = json.loads(resp.data)
        assert data["path"] == "/Users/me/.ssh/id_ed25519"

    def test_cancelled_dialog_returns_empty(
        self, app, client: FlaskClient,
    ) -> None:
        """When the user cancels the dialog, path is empty."""
        app.config["PLATFORM_INFO"].system = "Darwin"
        with patch("src.routes.sites.subprocess.run") as mock_run:
            mock_run.return_value.returncode = 1
            mock_run.return_value.stdout = ""
            resp = client.post("/api/browse-key")
        data = json.loads(resp.data)
        assert data["path"] == ""

    def test_returns_selected_path_linux(
        self, app, client: FlaskClient,
    ) -> None:
        """On Linux with zenity, returns the selected path."""
        app.config["PLATFORM_INFO"].system = "Linux"
        with patch("src.routes.sites.shutil.which", return_value="/usr/bin/zenity"):
            with patch("src.routes.sites.subprocess.run") as mock_run:
                mock_run.return_value.returncode = 0
                mock_run.return_value.stdout = "/home/user/.ssh/id_rsa\n"
                resp = client.post("/api/browse-key")
        data = json.loads(resp.data)
        assert data["path"] == "/home/user/.ssh/id_rsa"

    def test_timeout_returns_empty(
        self, app, client: FlaskClient,
    ) -> None:
        """Subprocess timeout returns empty path gracefully."""
        import subprocess as sp

        app.config["PLATFORM_INFO"].system = "Darwin"
        with patch(
            "src.routes.sites.subprocess.run",
            side_effect=sp.TimeoutExpired("osascript", 120),
        ):
            resp = client.post("/api/browse-key")
        data = json.loads(resp.data)
        assert data["path"] == ""

    def test_unknown_platform_returns_empty(
        self, app, client: FlaskClient,
    ) -> None:
        """Unsupported platform returns empty path without error."""
        app.config["PLATFORM_INFO"].system = "FreeBSD"
        resp = client.post("/api/browse-key")
        data = json.loads(resp.data)
        assert data["path"] == ""
