"""Tests for the CryptoService encryption layer."""

from __future__ import annotations

from pathlib import Path

import pytest

from py_flask.services.crypto_service import CryptoService


class TestKeyManagement:
    """Test encryption key lifecycle."""

    def test_auto_generates_key_file(self, tmp_data_dir: Path) -> None:
        """Key file is created automatically on first use."""
        key_path = tmp_data_dir / ".key"
        assert not key_path.exists()

        crypto = CryptoService(key_path)
        crypto.encrypt("trigger key creation")

        assert key_path.exists()

    def test_key_file_permissions(self, tmp_data_dir: Path) -> None:
        """Key file is created with restrictive permissions (0o600)."""
        key_path = tmp_data_dir / ".key"
        crypto = CryptoService(key_path)
        crypto.encrypt("trigger")

        # Check owner-only permissions
        mode = key_path.stat().st_mode & 0o777
        assert mode == 0o600

    def test_key_persists_across_instances(self, tmp_data_dir: Path) -> None:
        """A second CryptoService instance reuses the existing key."""
        key_path = tmp_data_dir / ".key"

        crypto1 = CryptoService(key_path)
        ciphertext = crypto1.encrypt("hello")

        crypto2 = CryptoService(key_path)
        plaintext = crypto2.decrypt(ciphertext)
        assert plaintext == "hello"

    def test_creates_parent_directories(self, tmp_path: Path) -> None:
        """Key file creation also creates missing parent dirs."""
        nested = tmp_path / "a" / "b" / ".key"
        crypto = CryptoService(nested)
        crypto.encrypt("trigger")
        assert nested.exists()


class TestEncryptDecrypt:
    """Test encrypt/decrypt round-trips."""

    def test_basic_round_trip(self, crypto: CryptoService) -> None:
        """Encrypted text decrypts back to the original."""
        plaintext = "Hello, World!"
        ciphertext = crypto.encrypt(plaintext)
        assert crypto.decrypt(ciphertext) == plaintext

    def test_ciphertext_differs_from_plaintext(
        self, crypto: CryptoService,
    ) -> None:
        """Encrypted output is not the same as input."""
        plaintext = "sensitive data"
        ciphertext = crypto.encrypt(plaintext)
        assert ciphertext != plaintext

    def test_unicode_round_trip(self, crypto: CryptoService) -> None:
        """Unicode characters survive encryption round-trip."""
        text = "Héllo, Wörld! 🔑"
        assert crypto.decrypt(crypto.encrypt(text)) == text

    def test_empty_string(self, crypto: CryptoService) -> None:
        """Empty strings can be encrypted and decrypted."""
        assert crypto.decrypt(crypto.encrypt("")) == ""

    def test_special_characters(self, crypto: CryptoService) -> None:
        """Special shell characters survive encryption round-trip."""
        text = 'p@$$w0rd!#%^&*(){}[]|\\:";\'<>,.?/~`'
        assert crypto.decrypt(crypto.encrypt(text)) == text

    def test_large_payload(self, crypto: CryptoService) -> None:
        """Large payloads encrypt and decrypt successfully."""
        text = "A" * 100_000
        assert crypto.decrypt(crypto.encrypt(text)) == text

    def test_wrong_key_fails(self, tmp_data_dir: Path) -> None:
        """Decrypting with a different key raises an exception."""
        crypto1 = CryptoService(tmp_data_dir / ".key1")
        ciphertext = crypto1.encrypt("secret")

        crypto2 = CryptoService(tmp_data_dir / ".key2")
        with pytest.raises(Exception):
            crypto2.decrypt(ciphertext)
