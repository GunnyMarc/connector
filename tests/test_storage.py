"""Tests for the encrypted SiteStorage CRUD layer."""

from __future__ import annotations

from py_flask.models.site import Site
from py_flask.services.storage import SiteStorage


class TestListSites:
    """Test listing sites."""

    def test_empty_storage(self, storage: SiteStorage) -> None:
        """Fresh storage returns an empty list."""
        assert storage.list_sites() == []

    def test_list_after_create(
        self, storage: SiteStorage, sample_site: Site,
    ) -> None:
        """Created sites appear in list_sites."""
        storage.create_site(sample_site)
        sites = storage.list_sites()
        assert len(sites) == 1
        assert sites[0].name == "Test Server"

    def test_list_multiple(self, storage: SiteStorage) -> None:
        """Multiple sites are listed correctly."""
        for i in range(5):
            storage.create_site(Site(name=f"Site {i}", hostname=f"host{i}.com"))
        assert len(storage.list_sites()) == 5


class TestGetSite:
    """Test get_site by ID."""

    def test_existing_site(
        self, storage: SiteStorage, sample_site: Site,
    ) -> None:
        """get_site returns the matching Site."""
        storage.create_site(sample_site)
        found = storage.get_site("test-uuid-1234")
        assert found is not None
        assert found.name == "Test Server"
        assert found.hostname == "192.168.1.100"

    def test_nonexistent_site(self, storage: SiteStorage) -> None:
        """get_site returns None for unknown IDs."""
        assert storage.get_site("does-not-exist") is None


class TestCreateSite:
    """Test site creation."""

    def test_creates_and_persists(
        self, storage: SiteStorage, sample_site: Site,
    ) -> None:
        """Created site is persisted to the encrypted file."""
        result = storage.create_site(sample_site)
        assert result.id == sample_site.id

        # Re-read to confirm persistence
        sites = storage.list_sites()
        assert len(sites) == 1
        assert sites[0].password == "s3cret!"

    def test_preserves_all_fields(
        self, storage: SiteStorage, sample_site_key: Site,
    ) -> None:
        """All fields including key_path survive create round-trip."""
        storage.create_site(sample_site_key)
        found = storage.get_site("test-uuid-5678")
        assert found is not None
        assert found.auth_type == "key"
        assert found.key_path == "~/.ssh/id_ed25519"
        assert found.port == 2222


class TestUpdateSite:
    """Test site updates."""

    def test_update_fields(
        self, storage: SiteStorage, sample_site: Site,
    ) -> None:
        """update_site merges new values into the existing entry."""
        storage.create_site(sample_site)
        updated = storage.update_site("test-uuid-1234", {
            "name": "Renamed Server",
            "port": 2222,
        })
        assert updated is not None
        assert updated.name == "Renamed Server"
        assert updated.port == 2222
        # Other fields unchanged
        assert updated.hostname == "192.168.1.100"
        assert updated.password == "s3cret!"

    def test_cannot_overwrite_id(
        self, storage: SiteStorage, sample_site: Site,
    ) -> None:
        """update_site prevents ID from being overwritten."""
        storage.create_site(sample_site)
        updated = storage.update_site("test-uuid-1234", {"id": "hacked"})
        assert updated is not None
        assert updated.id == "test-uuid-1234"

    def test_update_nonexistent(self, storage: SiteStorage) -> None:
        """update_site returns None if the site doesn't exist."""
        assert storage.update_site("no-such-id", {"name": "X"}) is None


class TestDeleteSite:
    """Test site deletion."""

    def test_delete_existing(
        self, storage: SiteStorage, sample_site: Site,
    ) -> None:
        """delete_site removes the site and returns True."""
        storage.create_site(sample_site)
        assert storage.delete_site("test-uuid-1234") is True
        assert storage.list_sites() == []

    def test_delete_nonexistent(self, storage: SiteStorage) -> None:
        """delete_site returns False for unknown IDs."""
        assert storage.delete_site("no-such-id") is False

    def test_delete_preserves_others(self, storage: SiteStorage) -> None:
        """Deleting one site does not affect other sites."""
        site_a = Site(name="A", hostname="a.com", id="id-a")
        site_b = Site(name="B", hostname="b.com", id="id-b")
        storage.create_site(site_a)
        storage.create_site(site_b)

        storage.delete_site("id-a")
        remaining = storage.list_sites()
        assert len(remaining) == 1
        assert remaining[0].id == "id-b"
