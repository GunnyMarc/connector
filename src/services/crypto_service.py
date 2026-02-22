"""Fernet-based encryption service for site storage.

The encryption key is auto-generated on first use and persisted to a file
so the encrypted data can be read back across restarts.
"""

from __future__ import annotations

from pathlib import Path

from cryptography.fernet import Fernet


class CryptoService:
    """Encrypt and decrypt strings using Fernet (AES-128-CBC + HMAC)."""

    def __init__(self, key_path: Path) -> None:
        self._key_path = key_path
        self._fernet: Fernet | None = None

    # ── Key management ─────────────────────────────────────────────────────

    def _load_or_create_key(self) -> bytes:
        """Load the key from disk or generate a new one."""
        if self._key_path.exists():
            return self._key_path.read_bytes().strip()

        self._key_path.parent.mkdir(parents=True, exist_ok=True)
        key = Fernet.generate_key()
        self._key_path.write_bytes(key)
        self._key_path.chmod(0o600)
        return key

    @property
    def fernet(self) -> Fernet:
        """Lazy-initialised Fernet instance."""
        if self._fernet is None:
            key = self._load_or_create_key()
            self._fernet = Fernet(key)
        return self._fernet

    # ── Public API ─────────────────────────────────────────────────────────

    def encrypt(self, plaintext: str) -> str:
        """Encrypt *plaintext* and return a URL-safe base64 token string."""
        return self.fernet.encrypt(plaintext.encode("utf-8")).decode("utf-8")

    def decrypt(self, ciphertext: str) -> str:
        """Decrypt a token string produced by :meth:`encrypt`."""
        return self.fernet.decrypt(ciphertext.encode("utf-8")).decode("utf-8")
