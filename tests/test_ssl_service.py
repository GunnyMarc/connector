"""Tests for the SSL/TLS certificate generation service."""

from __future__ import annotations

import os
import stat
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives.serialization import load_pem_private_key

from py_flask.services.ssl_service import ensure_ssl_certs


class TestEnsureSSLCerts:
    """Test self-signed certificate generation via ensure_ssl_certs."""

    def test_generates_cert_and_key(self, tmp_path: Path) -> None:
        """Should create cert.pem and key.pem when they don't exist."""
        cert_path = tmp_path / "cert.pem"
        key_path = tmp_path / "key.pem"

        result = ensure_ssl_certs(cert_path, key_path)

        assert result == (cert_path, key_path)
        assert cert_path.exists()
        assert key_path.exists()

    def test_returns_existing_certs_without_regenerating(self, tmp_path: Path) -> None:
        """Should not overwrite existing cert/key files."""
        cert_path = tmp_path / "cert.pem"
        key_path = tmp_path / "key.pem"

        # Generate first time.
        ensure_ssl_certs(cert_path, key_path)
        original_cert = cert_path.read_bytes()
        original_key = key_path.read_bytes()

        # Call again — should return existing files.
        ensure_ssl_certs(cert_path, key_path)
        assert cert_path.read_bytes() == original_cert
        assert key_path.read_bytes() == original_key

    def test_creates_parent_directories(self, tmp_path: Path) -> None:
        """Should create parent directories if they don't exist."""
        cert_path = tmp_path / "deep" / "nested" / "cert.pem"
        key_path = tmp_path / "deep" / "nested" / "key.pem"

        ensure_ssl_certs(cert_path, key_path)

        assert cert_path.exists()
        assert key_path.exists()

    def test_key_file_permissions(self, tmp_path: Path) -> None:
        """Private key file should have restrictive permissions (0o600)."""
        cert_path = tmp_path / "cert.pem"
        key_path = tmp_path / "key.pem"

        ensure_ssl_certs(cert_path, key_path)

        mode = os.stat(key_path).st_mode & 0o777
        assert mode == 0o600

    def test_cert_is_valid_pem(self, tmp_path: Path) -> None:
        """Generated cert should be a valid PEM-encoded X.509 certificate."""
        cert_path = tmp_path / "cert.pem"
        key_path = tmp_path / "key.pem"

        ensure_ssl_certs(cert_path, key_path)

        cert = x509.load_pem_x509_certificate(cert_path.read_bytes())
        assert cert is not None
        assert cert.subject is not None

    def test_key_is_valid_pem(self, tmp_path: Path) -> None:
        """Generated key should be a valid PEM-encoded RSA private key."""
        cert_path = tmp_path / "cert.pem"
        key_path = tmp_path / "key.pem"

        ensure_ssl_certs(cert_path, key_path)

        private_key = load_pem_private_key(key_path.read_bytes(), password=None)
        assert private_key is not None

    def test_cert_subject_contains_hostname(self, tmp_path: Path) -> None:
        """Certificate subject CN should contain the specified hostname."""
        cert_path = tmp_path / "cert.pem"
        key_path = tmp_path / "key.pem"

        ensure_ssl_certs(cert_path, key_path, hostname="myhost.local")

        cert = x509.load_pem_x509_certificate(cert_path.read_bytes())
        cn_attrs = cert.subject.get_attributes_for_oid(
            x509.oid.NameOID.COMMON_NAME,
        )
        assert len(cn_attrs) == 1
        assert cn_attrs[0].value == "myhost.local"

    def test_cert_organization_is_connector(self, tmp_path: Path) -> None:
        """Certificate subject O should be 'Connector'."""
        cert_path = tmp_path / "cert.pem"
        key_path = tmp_path / "key.pem"

        ensure_ssl_certs(cert_path, key_path)

        cert = x509.load_pem_x509_certificate(cert_path.read_bytes())
        org_attrs = cert.subject.get_attributes_for_oid(
            x509.oid.NameOID.ORGANIZATION_NAME,
        )
        assert len(org_attrs) == 1
        assert org_attrs[0].value == "Connector"

    def test_cert_has_san_extension(self, tmp_path: Path) -> None:
        """Certificate should include Subject Alternative Names."""
        cert_path = tmp_path / "cert.pem"
        key_path = tmp_path / "key.pem"

        ensure_ssl_certs(cert_path, key_path, hostname="localhost")

        cert = x509.load_pem_x509_certificate(cert_path.read_bytes())
        san = cert.extensions.get_extension_for_class(
            x509.SubjectAlternativeName,
        )
        assert san is not None
        dns_names = san.value.get_values_for_type(x509.DNSName)
        assert "localhost" in dns_names

    def test_san_includes_127_0_0_1(self, tmp_path: Path) -> None:
        """SAN should always include 127.0.0.1 IP address."""
        cert_path = tmp_path / "cert.pem"
        key_path = tmp_path / "key.pem"

        ensure_ssl_certs(cert_path, key_path)

        cert = x509.load_pem_x509_certificate(cert_path.read_bytes())
        san = cert.extensions.get_extension_for_class(
            x509.SubjectAlternativeName,
        )
        import ipaddress

        ip_addrs = san.value.get_values_for_type(x509.IPAddress)
        assert ipaddress.IPv4Address("127.0.0.1") in ip_addrs

    def test_san_includes_custom_hostname_as_dns(self, tmp_path: Path) -> None:
        """Non-IP hostnames should appear as DNS SANs."""
        cert_path = tmp_path / "cert.pem"
        key_path = tmp_path / "key.pem"

        ensure_ssl_certs(cert_path, key_path, hostname="myserver.example.com")

        cert = x509.load_pem_x509_certificate(cert_path.read_bytes())
        san = cert.extensions.get_extension_for_class(
            x509.SubjectAlternativeName,
        )
        dns_names = san.value.get_values_for_type(x509.DNSName)
        assert "myserver.example.com" in dns_names
        assert "localhost" in dns_names

    def test_san_includes_custom_ip_as_ip_address(self, tmp_path: Path) -> None:
        """IP hostnames should appear as IP SANs, not DNS SANs."""
        cert_path = tmp_path / "cert.pem"
        key_path = tmp_path / "key.pem"

        ensure_ssl_certs(cert_path, key_path, hostname="10.0.0.5")

        cert = x509.load_pem_x509_certificate(cert_path.read_bytes())
        san = cert.extensions.get_extension_for_class(
            x509.SubjectAlternativeName,
        )
        import ipaddress

        ip_addrs = san.value.get_values_for_type(x509.IPAddress)
        assert ipaddress.IPv4Address("10.0.0.5") in ip_addrs

    def test_cert_is_self_signed(self, tmp_path: Path) -> None:
        """Issuer and subject should be identical (self-signed)."""
        cert_path = tmp_path / "cert.pem"
        key_path = tmp_path / "key.pem"

        ensure_ssl_certs(cert_path, key_path)

        cert = x509.load_pem_x509_certificate(cert_path.read_bytes())
        assert cert.issuer == cert.subject

    def test_cert_validity_period(self, tmp_path: Path) -> None:
        """Certificate should be valid for the specified number of days."""
        cert_path = tmp_path / "cert.pem"
        key_path = tmp_path / "key.pem"

        ensure_ssl_certs(cert_path, key_path, validity_days=30)

        cert = x509.load_pem_x509_certificate(cert_path.read_bytes())
        delta = cert.not_valid_after_utc - cert.not_valid_before_utc
        assert delta.days == 30

    def test_default_validity_is_365_days(self, tmp_path: Path) -> None:
        """Default certificate validity should be 365 days."""
        cert_path = tmp_path / "cert.pem"
        key_path = tmp_path / "key.pem"

        ensure_ssl_certs(cert_path, key_path)

        cert = x509.load_pem_x509_certificate(cert_path.read_bytes())
        delta = cert.not_valid_after_utc - cert.not_valid_before_utc
        assert delta.days == 365

    def test_regenerates_if_cert_missing(self, tmp_path: Path) -> None:
        """Should regenerate if cert is missing but key exists."""
        cert_path = tmp_path / "cert.pem"
        key_path = tmp_path / "key.pem"

        # Generate both, then delete only the cert.
        ensure_ssl_certs(cert_path, key_path)
        cert_path.unlink()

        ensure_ssl_certs(cert_path, key_path)
        assert cert_path.exists()
        assert key_path.exists()

    def test_regenerates_if_key_missing(self, tmp_path: Path) -> None:
        """Should regenerate if key is missing but cert exists."""
        cert_path = tmp_path / "cert.pem"
        key_path = tmp_path / "key.pem"

        # Generate both, then delete only the key.
        ensure_ssl_certs(cert_path, key_path)
        key_path.unlink()

        ensure_ssl_certs(cert_path, key_path)
        assert cert_path.exists()
        assert key_path.exists()
