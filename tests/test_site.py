"""Tests for the Site data model."""

from __future__ import annotations

from src.models.site import PROTOCOL_LABELS, PROTOCOLS, Site


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


class TestProtocolFields:
    """Test protocol-related fields and properties."""

    def test_default_protocol_is_ssh2(self) -> None:
        """New sites default to ssh2 protocol."""
        site = Site(name="S", hostname="h.com")
        assert site.protocol == "ssh2"

    def test_default_serial_fields(self) -> None:
        """Serial fields have sensible defaults."""
        site = Site(name="S", hostname="h.com")
        assert site.serial_port == ""
        assert site.serial_baud == 9600

    def test_protocol_label(self) -> None:
        """protocol_label returns the human-readable name."""
        for proto, label in PROTOCOL_LABELS.items():
            site = Site(name="S", hostname="h.com", protocol=proto)
            assert site.protocol_label == label

    def test_is_ssh_true_for_ssh_protocols(self) -> None:
        """is_ssh is True for ssh1 and ssh2."""
        for proto in ("ssh1", "ssh2"):
            site = Site(name="S", hostname="h.com", protocol=proto)
            assert site.is_ssh is True

    def test_is_ssh_false_for_non_ssh_protocols(self) -> None:
        """is_ssh is False for local, raw, telnet, serial."""
        for proto in ("local", "raw", "telnet", "serial"):
            site = Site(name="S", hostname="h.com", protocol=proto)
            assert site.is_ssh is False

    def test_is_network_true_for_network_protocols(self) -> None:
        """is_network is True for ssh1, ssh2, raw, telnet."""
        for proto in ("ssh1", "ssh2", "raw", "telnet"):
            site = Site(name="S", hostname="h.com", protocol=proto)
            assert site.is_network is True

    def test_is_network_false_for_non_network_protocols(self) -> None:
        """is_network is False for local, serial."""
        for proto in ("local", "serial"):
            site = Site(name="S", hostname="h.com", protocol=proto)
            assert site.is_network is False

    def test_serial_site_creation(self) -> None:
        """Serial site can be created with serial-specific fields."""
        site = Site(
            name="My Serial",
            hostname="",
            protocol="serial",
            serial_port="/dev/ttyUSB0",
            serial_baud=115200,
        )
        assert site.protocol == "serial"
        assert site.serial_port == "/dev/ttyUSB0"
        assert site.serial_baud == 115200

    def test_protocol_round_trip(self) -> None:
        """Protocol and serial fields survive to_dict -> from_dict."""
        site = Site(
            name="S",
            hostname="",
            protocol="serial",
            serial_port="/dev/ttyS0",
            serial_baud=57600,
        )
        restored = Site.from_dict(site.to_dict())
        assert restored.protocol == "serial"
        assert restored.serial_port == "/dev/ttyS0"
        assert restored.serial_baud == 57600

    def test_protocol_constants(self) -> None:
        """PROTOCOLS tuple contains all expected protocols."""
        assert set(PROTOCOLS) == {"ssh2", "ssh1", "local", "raw", "telnet", "serial"}

    def test_old_data_gets_default_protocol(self) -> None:
        """Data without a protocol field defaults to ssh2 (backward compat)."""
        data = {"name": "Old", "hostname": "old.com", "port": 22}
        site = Site.from_dict(data)
        assert site.protocol == "ssh2"
        assert site.serial_port == ""
        assert site.serial_baud == 9600


class TestSftpRoot:
    """Test SFTP start directory field."""

    def test_default_sftp_root_is_empty(self) -> None:
        """New sites default to an empty sftp_root."""
        site = Site(name="S", hostname="h.com")
        assert site.sftp_root == ""

    def test_sftp_root_creation(self) -> None:
        """Site can be created with a custom sftp_root."""
        site = Site(name="S", hostname="h.com", sftp_root="/var/www")
        assert site.sftp_root == "/var/www"

    def test_sftp_root_round_trip(self) -> None:
        """sftp_root survives to_dict -> from_dict."""
        site = Site(name="S", hostname="h.com", sftp_root="/data/files")
        restored = Site.from_dict(site.to_dict())
        assert restored.sftp_root == "/data/files"

    def test_old_data_gets_default_sftp_root(self) -> None:
        """Data without sftp_root field defaults to empty (backward compat)."""
        data = {"name": "Old", "hostname": "old.com", "port": 22}
        site = Site.from_dict(data)
        assert site.sftp_root == ""

    def test_sftp_root_in_to_dict(self) -> None:
        """sftp_root is included in the serialised dictionary."""
        site = Site(name="S", hostname="h.com", sftp_root="/home/deploy")
        d = site.to_dict()
        assert d["sftp_root"] == "/home/deploy"
