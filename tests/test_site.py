"""Tests for the Site data model."""

from __future__ import annotations

from src.models.site import Site


class TestSiteCreation:
    """Test Site dataclass creation and defaults."""

    def test_minimal_creation(self) -> None:
        """Site can be created with just name and hostname."""
        site = Site(name="My Server", hostname="example.com")
        assert site.name == "My Server"
        assert site.hostname == "example.com"
        assert site.port == 22
        assert site.username == ""
        assert site.auth_type == "password"
        assert site.password == ""
        assert site.key_path == ""
        assert site.notes == ""
        assert site.id  # auto-generated UUID

    def test_full_creation(self, sample_site: Site) -> None:
        """Site can be created with all fields specified."""
        assert sample_site.name == "Test Server"
        assert sample_site.hostname == "192.168.1.100"
        assert sample_site.port == 22
        assert sample_site.username == "admin"
        assert sample_site.auth_type == "password"
        assert sample_site.password == "s3cret!"
        assert sample_site.id == "test-uuid-1234"

    def test_unique_ids(self) -> None:
        """Each Site gets a unique auto-generated ID."""
        site_a = Site(name="A", hostname="a.com")
        site_b = Site(name="B", hostname="b.com")
        assert site_a.id != site_b.id


class TestSiteSerialization:
    """Test to_dict / from_dict round-trip."""

    def test_to_dict(self, sample_site: Site) -> None:
        """to_dict produces a complete dictionary."""
        d = sample_site.to_dict()
        assert d["name"] == "Test Server"
        assert d["hostname"] == "192.168.1.100"
        assert d["port"] == 22
        assert d["password"] == "s3cret!"
        assert d["id"] == "test-uuid-1234"

    def test_from_dict(self) -> None:
        """from_dict reconstructs a Site from a dictionary."""
        data = {
            "name": "Restored",
            "hostname": "10.0.0.1",
            "port": 2222,
            "username": "root",
            "auth_type": "key",
            "password": "",
            "key_path": "/home/user/.ssh/id_rsa",
            "notes": "restored",
            "id": "restored-id",
        }
        site = Site.from_dict(data)
        assert site.name == "Restored"
        assert site.port == 2222
        assert site.id == "restored-id"

    def test_from_dict_ignores_unknown_keys(self) -> None:
        """from_dict silently ignores keys not in the dataclass."""
        data = {
            "name": "Test",
            "hostname": "host.com",
            "unknown_field": "should be ignored",
        }
        site = Site.from_dict(data)
        assert site.name == "Test"
        assert not hasattr(site, "unknown_field")

    def test_round_trip(self, sample_site: Site) -> None:
        """to_dict -> from_dict produces an equivalent Site."""
        restored = Site.from_dict(sample_site.to_dict())
        assert restored.name == sample_site.name
        assert restored.hostname == sample_site.hostname
        assert restored.port == sample_site.port
        assert restored.id == sample_site.id
        assert restored.password == sample_site.password


class TestMaskedPassword:
    """Test masked password display."""

    def test_masks_short_password(self) -> None:
        """Short passwords are masked up to their length."""
        site = Site(name="X", hostname="x.com", password="abc")
        assert site.masked_password() == "***"

    def test_masks_long_password(self) -> None:
        """Long passwords are capped at 8 asterisks."""
        site = Site(name="X", hostname="x.com", password="a_very_long_password")
        assert site.masked_password() == "********"

    def test_empty_password(self) -> None:
        """Empty password returns empty string."""
        site = Site(name="X", hostname="x.com", password="")
        assert site.masked_password() == ""
