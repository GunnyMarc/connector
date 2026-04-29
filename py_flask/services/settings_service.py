"""Encrypted settings storage for global application options."""

from __future__ import annotations

import copy
import json
from pathlib import Path
from typing import Any

from py_flask.services.crypto_service import CryptoService


class SettingsService:
    """Read and write global settings backed by an encrypted file."""

    DEFAULTS: dict[str, Any] = {
        "default_port": 22,
        "ssh_timeout": 10,
        "command_timeout": 30,
        "default_username": "",
        "default_auth_type": "password",
        "default_key_path": "~/.ssh/id_rsa",
        "folders": [],
        # Terminal preference — empty strings mean "use the platform default"
        # detected at startup.
        "terminal_name": "",
        "terminal_path": "",
    }

    def __init__(self, file_path: Path, crypto: CryptoService) -> None:
        self._file_path = file_path
        self._crypto = crypto

    # ── Read ───────────────────────────────────────────────────────────────

    def get_all(self) -> dict[str, Any]:
        """Return the full settings dict, merged with defaults."""
        stored: dict[str, Any] = {}
        if self._file_path.exists():
            ciphertext = self._file_path.read_text(encoding="utf-8").strip()
            if ciphertext:
                plaintext = self._crypto.decrypt(ciphertext)
                stored = json.loads(plaintext)

        merged = copy.deepcopy(self.DEFAULTS)
        merged.update(stored)
        return merged

    def get(self, key: str) -> Any:
        """Return a single setting value."""
        return self.get_all().get(key, self.DEFAULTS.get(key))

    # ── Write ──────────────────────────────────────────────────────────────

    def update(self, updates: dict[str, Any]) -> dict[str, Any]:
        """Merge *updates* into the stored settings and persist."""
        settings = self.get_all()
        settings.update(updates)
        self._file_path.parent.mkdir(parents=True, exist_ok=True)
        plaintext = json.dumps(settings, indent=2)
        ciphertext = self._crypto.encrypt(plaintext)
        self._file_path.write_text(ciphertext, encoding="utf-8")
        return settings
