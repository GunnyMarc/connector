"""Tests for folder management (routes, model integration, drag-and-drop API).

Includes tests for hierarchical subfolders using ``/``-separated paths.
"""

from __future__ import annotations

from flask.testing import FlaskClient

from py_flask.app import _build_folder_tree
from py_flask.models.site import Site
from py_flask.services.settings_service import SettingsService
from py_flask.services.storage import SiteStorage


# ── Helpers ───────────────────────────────────────────────────────────────────


def _create_folder(app, name: str) -> None:
    """Create a folder via the settings service."""
    svc: SettingsService = app.config["SETTINGS"]
    settings = svc.get_all()
    folders = settings.get("folders", [])
    folders.append(name)
    svc.update({"folders": folders})


def _create_site(app, name: str, folder: str = "", site_id: str = "") -> str:
    """Insert a test site and return its ID."""
    storage: SiteStorage = app.config["STORAGE"]
    site = Site(
        name=name,
        hostname="10.0.0.1",
        port=22,
        username="root",
        folder=folder,
        **({"id": site_id} if site_id else {}),
    )
    storage.create_site(site)
    return site.id


# ── Site model folder field ───────────────────────────────────────────────────


class TestSiteFolderField:
    """Test the folder field on the Site model."""

    def test_default_folder_is_empty(self) -> None:
        """New sites have an empty folder by default."""
        site = Site(name="Test", hostname="host.com")
        assert site.folder == ""

    def test_folder_in_to_dict(self) -> None:
        """folder field is included in serialisation."""
        site = Site(name="Test", hostname="host.com", folder="Production")
        d = site.to_dict()
        assert d["folder"] == "Production"

    def test_folder_round_trip(self) -> None:
        """folder survives to_dict → from_dict round-trip."""
        site = Site(name="Test", hostname="host.com", folder="Staging")
        restored = Site.from_dict(site.to_dict())
        assert restored.folder == "Staging"

    def test_folder_persists_in_storage(self, storage, crypto) -> None:
        """folder is preserved through encrypted storage."""
        site = Site(name="Test", hostname="host.com", folder="Archive")
        storage.create_site(site)

        found = storage.get_site(site.id)
        assert found is not None
        assert found.folder == "Archive"


# ── Folder creation ──────────────────────────────────────────────────────────


class TestFolderCreate:
    """Test POST /folders/create."""

    def test_create_folder_json(self, app, client: FlaskClient) -> None:
        """Create a folder via JSON and verify it's persisted."""
        resp = client.post(
            "/folders/create",
            json={"name": "Production"},
        )
        assert resp.status_code == 200
        data = resp.get_json()
        assert data["ok"] is True
        assert "Production" in data["folders"]

    def test_create_folder_form(self, app, client: FlaskClient) -> None:
        """Create a folder via form POST and verify redirect."""
        resp = client.post(
            "/folders/create",
            data={"name": "Staging"},
        )
        assert resp.status_code == 302  # redirect

        svc: SettingsService = app.config["SETTINGS"]
        folders = svc.get_all().get("folders", [])
        assert "Staging" in folders

    def test_create_duplicate_folder(self, app, client: FlaskClient) -> None:
        """Creating a folder with the same name returns 409."""
        _create_folder(app, "Existing")
        resp = client.post(
            "/folders/create",
            json={"name": "Existing"},
        )
        assert resp.status_code == 409

    def test_create_empty_name(self, client: FlaskClient) -> None:
        """Empty folder name returns 400."""
        resp = client.post(
            "/folders/create",
            json={"name": ""},
        )
        assert resp.status_code == 400

    def test_create_whitespace_name(self, client: FlaskClient) -> None:
        """Whitespace-only folder name returns 400."""
        resp = client.post(
            "/folders/create",
            json={"name": "   "},
        )
        assert resp.status_code == 400


# ── Folder rename ─────────────────────────────────────────────────────────────


class TestFolderRename:
    """Test POST /folders/rename."""

    def test_rename_folder(self, app, client: FlaskClient) -> None:
        """Rename a folder and verify sites are updated."""
        _create_folder(app, "Old Name")
        site_id = _create_site(app, "Server A", folder="Old Name")

        resp = client.post(
            "/folders/rename",
            json={"old_name": "Old Name", "new_name": "New Name"},
        )
        assert resp.status_code == 200
        data = resp.get_json()
        assert data["ok"] is True
        assert "New Name" in data["folders"]
        assert "Old Name" not in data["folders"]

        # Verify site was moved to new folder
        storage: SiteStorage = app.config["STORAGE"]
        site = storage.get_site(site_id)
        assert site.folder == "New Name"

    def test_rename_nonexistent(self, app, client: FlaskClient) -> None:
        """Renaming a nonexistent folder returns 404."""
        resp = client.post(
            "/folders/rename",
            json={"old_name": "Nope", "new_name": "Whatever"},
        )
        assert resp.status_code == 404

    def test_rename_to_existing(self, app, client: FlaskClient) -> None:
        """Renaming to an existing folder name returns 409."""
        _create_folder(app, "A")
        _create_folder(app, "B")
        resp = client.post(
            "/folders/rename",
            json={"old_name": "A", "new_name": "B"},
        )
        assert resp.status_code == 409

    def test_rename_empty_names(self, client: FlaskClient) -> None:
        """Empty names return 400."""
        resp = client.post(
            "/folders/rename",
            json={"old_name": "", "new_name": "X"},
        )
        assert resp.status_code == 400


# ── Folder delete ─────────────────────────────────────────────────────────────


class TestFolderDelete:
    """Test POST /folders/delete."""

    def test_delete_folder(self, app, client: FlaskClient) -> None:
        """Delete a folder — sites move back to root."""
        _create_folder(app, "Temp")
        site_id = _create_site(app, "Server X", folder="Temp")

        resp = client.post(
            "/folders/delete",
            json={"name": "Temp"},
        )
        assert resp.status_code == 200
        data = resp.get_json()
        assert data["ok"] is True
        assert "Temp" not in data["folders"]

        # Verify site is back at root
        storage: SiteStorage = app.config["STORAGE"]
        site = storage.get_site(site_id)
        assert site.folder == ""

    def test_delete_nonexistent(self, client: FlaskClient) -> None:
        """Deleting a nonexistent folder returns 404."""
        resp = client.post(
            "/folders/delete",
            json={"name": "Nope"},
        )
        assert resp.status_code == 404

    def test_delete_empty_name(self, client: FlaskClient) -> None:
        """Empty name returns 400."""
        resp = client.post(
            "/folders/delete",
            json={"name": ""},
        )
        assert resp.status_code == 400


# ── Move site to folder (drag-and-drop API) ──────────────────────────────────


class TestMoveSite:
    """Test POST /folders/move (drag-and-drop endpoint)."""

    def test_move_to_folder(self, app, client: FlaskClient) -> None:
        """Move a root site into a folder."""
        _create_folder(app, "Production")
        site_id = _create_site(app, "Web Server")

        resp = client.post(
            "/folders/move",
            json={"site_id": site_id, "folder": "Production"},
        )
        assert resp.status_code == 200
        data = resp.get_json()
        assert data["ok"] is True
        assert data["folder"] == "Production"

        storage: SiteStorage = app.config["STORAGE"]
        assert storage.get_site(site_id).folder == "Production"

    def test_move_to_root(self, app, client: FlaskClient) -> None:
        """Move a site from a folder back to root."""
        _create_folder(app, "Staging")
        site_id = _create_site(app, "API Server", folder="Staging")

        resp = client.post(
            "/folders/move",
            json={"site_id": site_id, "folder": ""},
        )
        assert resp.status_code == 200
        data = resp.get_json()
        assert data["ok"] is True
        assert data["folder"] == ""

        storage: SiteStorage = app.config["STORAGE"]
        assert storage.get_site(site_id).folder == ""

    def test_move_between_folders(self, app, client: FlaskClient) -> None:
        """Move a site from one folder to another."""
        _create_folder(app, "Folder A")
        _create_folder(app, "Folder B")
        site_id = _create_site(app, "DB Server", folder="Folder A")

        resp = client.post(
            "/folders/move",
            json={"site_id": site_id, "folder": "Folder B"},
        )
        assert resp.status_code == 200

        storage: SiteStorage = app.config["STORAGE"]
        assert storage.get_site(site_id).folder == "Folder B"

    def test_move_nonexistent_site(self, client: FlaskClient) -> None:
        """Moving a nonexistent site returns 404."""
        resp = client.post(
            "/folders/move",
            json={"site_id": "no-such-id", "folder": ""},
        )
        assert resp.status_code == 404

    def test_move_to_nonexistent_folder(
        self, app, client: FlaskClient,
    ) -> None:
        """Moving to a folder that doesn't exist returns 404."""
        site_id = _create_site(app, "Orphan")
        resp = client.post(
            "/folders/move",
            json={"site_id": site_id, "folder": "Ghost"},
        )
        assert resp.status_code == 404

    def test_move_missing_site_id(self, client: FlaskClient) -> None:
        """Missing site_id returns 400."""
        resp = client.post(
            "/folders/move",
            json={"folder": "X"},
        )
        assert resp.status_code == 400


# ── Folder reorder ────────────────────────────────────────────────────────────


class TestFolderReorder:
    """Test POST /folders/reorder."""

    def test_reorder_basic(self, app, client: FlaskClient) -> None:
        """Reorder three folders and verify new order is persisted."""
        _create_folder(app, "Alpha")
        _create_folder(app, "Beta")
        _create_folder(app, "Gamma")

        resp = client.post(
            "/folders/reorder",
            json={"folders": ["Gamma", "Alpha", "Beta"]},
        )
        assert resp.status_code == 200
        data = resp.get_json()
        assert data["ok"] is True
        assert data["folders"] == ["Gamma", "Alpha", "Beta"]

        # Verify persisted order
        svc: SettingsService = app.config["SETTINGS"]
        assert svc.get_all()["folders"] == ["Gamma", "Alpha", "Beta"]

    def test_reorder_reverse(self, app, client: FlaskClient) -> None:
        """Reverse the folder order."""
        _create_folder(app, "A")
        _create_folder(app, "B")
        _create_folder(app, "C")

        resp = client.post(
            "/folders/reorder",
            json={"folders": ["C", "B", "A"]},
        )
        assert resp.status_code == 200

        svc: SettingsService = app.config["SETTINGS"]
        assert svc.get_all()["folders"] == ["C", "B", "A"]

    def test_reorder_single_folder(self, app, client: FlaskClient) -> None:
        """Reorder with a single folder is a no-op but succeeds."""
        _create_folder(app, "Only")

        resp = client.post(
            "/folders/reorder",
            json={"folders": ["Only"]},
        )
        assert resp.status_code == 200

    def test_reorder_missing_folder(self, app, client: FlaskClient) -> None:
        """Reorder that omits a folder returns 400."""
        _create_folder(app, "A")
        _create_folder(app, "B")

        resp = client.post(
            "/folders/reorder",
            json={"folders": ["A"]},
        )
        assert resp.status_code == 400

    def test_reorder_extra_folder(self, app, client: FlaskClient) -> None:
        """Reorder that adds a new folder returns 400."""
        _create_folder(app, "A")

        resp = client.post(
            "/folders/reorder",
            json={"folders": ["A", "Unknown"]},
        )
        assert resp.status_code == 400

    def test_reorder_duplicates(self, app, client: FlaskClient) -> None:
        """Reorder with duplicate names returns 400."""
        _create_folder(app, "A")
        _create_folder(app, "B")

        resp = client.post(
            "/folders/reorder",
            json={"folders": ["A", "A"]},
        )
        assert resp.status_code == 400

    def test_reorder_empty_list(self, app, client: FlaskClient) -> None:
        """Reorder with empty list succeeds when no folders exist."""
        resp = client.post(
            "/folders/reorder",
            json={"folders": []},
        )
        assert resp.status_code == 200

    def test_reorder_invalid_type(self, client: FlaskClient) -> None:
        """Non-list value for folders returns 400."""
        resp = client.post(
            "/folders/reorder",
            json={"folders": "not a list"},
        )
        assert resp.status_code == 400

    def test_sidebar_reflects_reorder(
        self, app, client: FlaskClient,
    ) -> None:
        """After reorder, sidebar renders folders in the new order."""
        _create_folder(app, "Zebra")
        _create_folder(app, "Apple")
        _create_site(app, "Z-srv", folder="Zebra")
        _create_site(app, "A-srv", folder="Apple")

        # Reorder: Apple first, then Zebra
        client.post(
            "/folders/reorder",
            json={"folders": ["Apple", "Zebra"]},
        )

        resp = client.get("/")
        html = resp.data.decode()
        apple_pos = html.index("Apple")
        zebra_pos = html.index("Zebra")
        assert apple_pos < zebra_pos


# ── Sidebar folder rendering ─────────────────────────────────────────────────


class TestSidebarFolders:
    """Test that folders render correctly in the sidebar."""

    def test_sidebar_shows_folders(self, app, client: FlaskClient) -> None:
        """Folders appear in the sidebar HTML."""
        _create_folder(app, "Production")
        _create_folder(app, "Staging")
        _create_site(app, "Web", folder="Production")
        _create_site(app, "API", folder="Staging")

        resp = client.get("/")
        assert resp.status_code == 200
        html = resp.data.decode()
        assert "Production" in html
        assert "Staging" in html

    def test_sidebar_groups_sites(self, app, client: FlaskClient) -> None:
        """Sites appear under their assigned folder."""
        _create_folder(app, "Prod")
        _create_site(app, "FolderChild", folder="Prod")
        _create_site(app, "RootChild", folder="")

        resp = client.get("/")
        html = resp.data.decode()
        assert "FolderChild" in html
        assert "RootChild" in html

    def test_site_form_shows_folder_dropdown(
        self, app, client: FlaskClient,
    ) -> None:
        """The create/edit form has a folder dropdown."""
        _create_folder(app, "MyFolder")
        resp = client.get("/sites/new")
        html = resp.data.decode()
        assert "MyFolder" in html
        assert 'name="folder"' in html

    def test_create_site_with_folder(
        self, app, client: FlaskClient,
    ) -> None:
        """Creating a site with a folder assigns it correctly."""
        _create_folder(app, "Archive")
        client.post(
            "/sites/new",
            data={
                "name": "Old Server",
                "hostname": "10.0.0.99",
                "port": "22",
                "auth_type": "password",
                "folder": "Archive",
            },
            follow_redirects=True,
        )

        storage: SiteStorage = app.config["STORAGE"]
        sites = storage.list_sites()
        assert len(sites) == 1
        assert sites[0].folder == "Archive"

    def test_duplicate_preserves_folder(
        self, app, client: FlaskClient,
    ) -> None:
        """Duplicating a site preserves the folder assignment."""
        _create_folder(app, "Tools")
        site_id = _create_site(app, "ToolSrv", folder="Tools")

        client.post(f"/sites/{site_id}/duplicate", follow_redirects=True)

        storage: SiteStorage = app.config["STORAGE"]
        sites = storage.list_sites()
        assert len(sites) == 2
        copy = [s for s in sites if s.id != site_id][0]
        assert copy.folder == "Tools"


# ── Subfolder support ─────────────────────────────────────────────────────────


class TestFolderTreeBuilder:
    """Test the _build_folder_tree helper in app.py."""

    def test_flat_folders(self) -> None:
        """Flat folder names produce a flat tree."""
        tree = _build_folder_tree(["A", "B"], [])
        assert len(tree) == 2
        assert tree[0]["name"] == "A"
        assert tree[0]["path"] == "A"
        assert tree[0]["children"] == []
        assert tree[1]["name"] == "B"

    def test_nested_folders(self) -> None:
        """Path-based names create nested children."""
        tree = _build_folder_tree(["AWS", "AWS/Prod", "AWS/Staging"], [])
        assert len(tree) == 1
        aws = tree[0]
        assert aws["name"] == "AWS"
        assert len(aws["children"]) == 2
        assert aws["children"][0]["name"] == "Prod"
        assert aws["children"][0]["path"] == "AWS/Prod"
        assert aws["children"][1]["name"] == "Staging"

    def test_deeply_nested(self) -> None:
        """Three levels of nesting work correctly."""
        tree = _build_folder_tree(["A", "A/B", "A/B/C"], [])
        assert len(tree) == 1
        a = tree[0]
        assert len(a["children"]) == 1
        b = a["children"][0]
        assert b["name"] == "B"
        assert len(b["children"]) == 1
        c = b["children"][0]
        assert c["name"] == "C"
        assert c["path"] == "A/B/C"

    def test_sites_assigned_to_correct_node(self) -> None:
        """Sites are placed in the matching folder node."""
        site_a = Site(name="S1", hostname="h", folder="AWS/Prod")
        site_b = Site(name="S2", hostname="h", folder="AWS")
        tree = _build_folder_tree(
            ["AWS", "AWS/Prod"], [site_a, site_b],
        )
        aws = tree[0]
        assert len(aws["sites"]) == 1
        assert aws["sites"][0].name == "S2"
        prod = aws["children"][0]
        assert len(prod["sites"]) == 1
        assert prod["sites"][0].name == "S1"

    def test_preserves_order(self) -> None:
        """Tree preserves the insertion order of folders."""
        tree = _build_folder_tree(["Z", "A", "M"], [])
        names = [n["name"] for n in tree]
        assert names == ["Z", "A", "M"]

    def test_orphan_subfolder_goes_to_root(self) -> None:
        """Subfolder without parent in list becomes a root node."""
        tree = _build_folder_tree(["AWS/Prod"], [])
        assert len(tree) == 1
        assert tree[0]["name"] == "Prod"
        assert tree[0]["path"] == "AWS/Prod"


class TestSubfolderCreate:
    """Test creating subfolders via the API."""

    def test_create_subfolder_with_parent(
        self, app, client: FlaskClient,
    ) -> None:
        """Creating with parent auto-builds the full path."""
        _create_folder(app, "AWS")
        resp = client.post(
            "/folders/create",
            json={"name": "Production", "parent": "AWS"},
        )
        assert resp.status_code == 200
        data = resp.get_json()
        assert data["ok"] is True
        assert "AWS/Production" in data["folders"]

    def test_create_subfolder_via_path(
        self, app, client: FlaskClient,
    ) -> None:
        """Creating with a path name directly works."""
        resp = client.post(
            "/folders/create",
            json={"name": "AWS/Staging"},
        )
        assert resp.status_code == 200
        data = resp.get_json()
        # Both "AWS" (auto-created parent) and "AWS/Staging" should exist
        assert "AWS" in data["folders"]
        assert "AWS/Staging" in data["folders"]

    def test_auto_creates_intermediate_folders(
        self, app, client: FlaskClient,
    ) -> None:
        """Deep path auto-creates all intermediate parents."""
        resp = client.post(
            "/folders/create",
            json={"name": "A/B/C"},
        )
        assert resp.status_code == 200
        data = resp.get_json()
        assert "A" in data["folders"]
        assert "A/B" in data["folders"]
        assert "A/B/C" in data["folders"]

    def test_create_duplicate_subfolder(
        self, app, client: FlaskClient,
    ) -> None:
        """Creating an already-existing subfolder returns 409."""
        _create_folder(app, "AWS")
        _create_folder(app, "AWS/Prod")
        resp = client.post(
            "/folders/create",
            json={"name": "Prod", "parent": "AWS"},
        )
        assert resp.status_code == 409


class TestSubfolderRename:
    """Test renaming folders with subfolders."""

    def test_rename_parent_cascades_to_children(
        self, app, client: FlaskClient,
    ) -> None:
        """Renaming a parent folder renames all descendant paths."""
        _create_folder(app, "AWS")
        _create_folder(app, "AWS/Prod")
        _create_folder(app, "AWS/Staging")
        site_id = _create_site(app, "Server", folder="AWS/Prod")

        resp = client.post(
            "/folders/rename",
            json={"old_name": "AWS", "new_name": "Amazon"},
        )
        assert resp.status_code == 200
        data = resp.get_json()
        assert "Amazon" in data["folders"]
        assert "Amazon/Prod" in data["folders"]
        assert "Amazon/Staging" in data["folders"]
        assert "AWS" not in data["folders"]

        # Site folder should also be updated
        storage: SiteStorage = app.config["STORAGE"]
        site = storage.get_site(site_id)
        assert site.folder == "Amazon/Prod"

    def test_rename_leaf_subfolder(
        self, app, client: FlaskClient,
    ) -> None:
        """Renaming a leaf subfolder only changes that path."""
        _create_folder(app, "AWS")
        _create_folder(app, "AWS/Prod")
        _create_folder(app, "AWS/Stage")

        resp = client.post(
            "/folders/rename",
            json={"old_name": "AWS/Prod", "new_name": "AWS/Production"},
        )
        assert resp.status_code == 200
        data = resp.get_json()
        assert "AWS/Production" in data["folders"]
        assert "AWS/Prod" not in data["folders"]
        # Sibling untouched
        assert "AWS/Stage" in data["folders"]


class TestSubfolderDelete:
    """Test deleting folders that have subfolders."""

    def test_delete_parent_removes_children(
        self, app, client: FlaskClient,
    ) -> None:
        """Deleting a parent removes all subfolders too."""
        _create_folder(app, "AWS")
        _create_folder(app, "AWS/Prod")
        _create_folder(app, "AWS/Staging")
        site_id = _create_site(app, "Web", folder="AWS/Prod")

        resp = client.post(
            "/folders/delete",
            json={"name": "AWS"},
        )
        assert resp.status_code == 200
        data = resp.get_json()
        assert "AWS" not in data["folders"]
        assert "AWS/Prod" not in data["folders"]
        assert "AWS/Staging" not in data["folders"]

        # Site should be moved to root
        storage: SiteStorage = app.config["STORAGE"]
        site = storage.get_site(site_id)
        assert site.folder == ""

    def test_delete_leaf_preserves_parent(
        self, app, client: FlaskClient,
    ) -> None:
        """Deleting a leaf subfolder keeps the parent."""
        _create_folder(app, "AWS")
        _create_folder(app, "AWS/Prod")

        resp = client.post(
            "/folders/delete",
            json={"name": "AWS/Prod"},
        )
        assert resp.status_code == 200
        data = resp.get_json()
        assert "AWS" in data["folders"]
        assert "AWS/Prod" not in data["folders"]


class TestSubfolderMove:
    """Test moving sites into subfolders."""

    def test_move_site_to_subfolder(
        self, app, client: FlaskClient,
    ) -> None:
        """A site can be moved into a subfolder."""
        _create_folder(app, "AWS")
        _create_folder(app, "AWS/Prod")
        site_id = _create_site(app, "Web")

        resp = client.post(
            "/folders/move",
            json={"site_id": site_id, "folder": "AWS/Prod"},
        )
        assert resp.status_code == 200
        storage: SiteStorage = app.config["STORAGE"]
        assert storage.get_site(site_id).folder == "AWS/Prod"


class TestSubfolderSidebar:
    """Test that the sidebar renders the folder tree correctly."""

    def test_sidebar_shows_subfolder(
        self, app, client: FlaskClient,
    ) -> None:
        """Subfolders appear in the sidebar HTML."""
        _create_folder(app, "AWS")
        _create_folder(app, "AWS/Production")
        _create_site(app, "Web", folder="AWS/Production")

        resp = client.get("/")
        assert resp.status_code == 200
        html = resp.data.decode()
        assert "AWS" in html
        assert "Production" in html

    def test_form_shows_subfolder_in_dropdown(
        self, app, client: FlaskClient,
    ) -> None:
        """The site form dropdown includes subfolders."""
        _create_folder(app, "AWS")
        _create_folder(app, "AWS/Prod")

        resp = client.get("/sites/new")
        html = resp.data.decode()
        assert "AWS/Prod" in html

    def test_create_site_in_subfolder(
        self, app, client: FlaskClient,
    ) -> None:
        """A site can be created directly in a subfolder."""
        _create_folder(app, "AWS")
        _create_folder(app, "AWS/Prod")
        client.post(
            "/sites/new",
            data={
                "name": "Prod Server",
                "hostname": "10.0.0.1",
                "port": "22",
                "folder": "AWS/Prod",
            },
            follow_redirects=True,
        )
        storage: SiteStorage = app.config["STORAGE"]
        site = storage.list_sites()[0]
        assert site.folder == "AWS/Prod"
