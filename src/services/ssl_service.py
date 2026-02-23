"""SSL/TLS certificate management for the Connector application.

Generates self-signed certificates for HTTPS when no existing cert/key
pair is found.  Uses the ``cryptography`` library (already a project
dependency for Fernet encryption).
"""

from __future__ import annotations

import datetime
import os
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID


# Default validity period for self-signed certificates (days).
_DEFAULT_VALIDITY_DAYS = 365

# RSA key size in bits.
_RSA_KEY_SIZE = 2048


def ensure_ssl_certs(
    cert_path: Path,
    key_path: Path,
    hostname: str = "localhost",
    *,
    validity_days: int = _DEFAULT_VALIDITY_DAYS,
) -> tuple[Path, Path]:
    """Return paths to an SSL cert and private key, generating them if needed.

    If both *cert_path* and *key_path* already exist they are returned
    as-is.  Otherwise a new RSA-2048 self-signed certificate is created
    with Subject Alternative Names for *hostname*, ``localhost``, and
    ``127.0.0.1``.

    The private key file is written with mode 0o600.

    Returns:
        A ``(cert_path, key_path)`` tuple.
    """
    if cert_path.exists() and key_path.exists():
        return cert_path, key_path

    # Ensure the parent directory exists.
    cert_path.parent.mkdir(parents=True, exist_ok=True)
    key_path.parent.mkdir(parents=True, exist_ok=True)

    # Generate RSA private key.
    private_key = rsa.generate_private_key(
        public_exponent=65537,
        key_size=_RSA_KEY_SIZE,
    )

    # Build the X.509 subject.
    subject = issuer = x509.Name([
        x509.NameAttribute(NameOID.COMMON_NAME, hostname),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Connector"),
    ])

    # Subject Alternative Names — always include localhost + 127.0.0.1
    # plus the configured hostname (if different).
    san_entries: list[x509.GeneralName] = [
        x509.DNSName("localhost"),
        x509.IPAddress(
            __import__("ipaddress").IPv4Address("127.0.0.1"),
        ),
    ]
    if hostname not in ("localhost", "127.0.0.1"):
        # Try to add as IP first; fall back to DNS name.
        try:
            import ipaddress

            addr = ipaddress.ip_address(hostname)
            san_entries.append(x509.IPAddress(addr))
        except ValueError:
            san_entries.append(x509.DNSName(hostname))

    now = datetime.datetime.now(datetime.timezone.utc)

    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(private_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now)
        .not_valid_after(now + datetime.timedelta(days=validity_days))
        .add_extension(
            x509.SubjectAlternativeName(san_entries),
            critical=False,
        )
        .sign(private_key, hashes.SHA256())
    )

    # Write private key (PEM, no passphrase, restrictive permissions).
    key_path.write_bytes(
        private_key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.TraditionalOpenSSL,
            encryption_algorithm=serialization.NoEncryption(),
        )
    )
    os.chmod(key_path, 0o600)

    # Write certificate (PEM).
    cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))

    return cert_path, key_path
