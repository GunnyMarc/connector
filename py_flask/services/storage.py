"""Encrypted file storage for site connection entries.

Sites are serialised to JSON, encrypted via :class:`CryptoService`, and
written to a single ``.enc`` text file.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Optional

from py_flask.models.site import Site
from py_flask.services.crypto_service import CryptoService


class SiteStorage:
    """CRUD operations backed by an encrypted text file."""

    def __init__(self, file_path: Path, crypto: CryptoService) -> None:
        self._file_path = file_path
        self._crypto = crypto

    # ── Internal helpers ───────────────────────────────────────────────────

    def _read_all(self) -> list[dict]:
        """Decrypt and parse the storage file, returning raw dicts."""
        if not self._file_path.exists():
            return []
        ciphertext = self._file_path.read_text(encoding="utf-8").strip()
        if not ciphertext:
            return []
        plaintext = self._crypto.decrypt(ciphertext)
        return json.loads(plaintext)

    def _write_all(self, entries: list[dict]) -> None:
        """Serialise, encrypt, and persist all entries."""
        self._file_path.parent.mkdir(parents=True, exist_ok=True)
        plaintext = json.dumps(entries, indent=2)
        ciphertext = self._crypto.encrypt(plaintext)
        self._file_path.write_text(ciphertext, encoding="utf-8")

    # ── Public CRUD ────────────────────────────────────────────────────────

    def list_sites(self) -> list[Site]:
        """Return every stored site."""
        return [Site.from_dict(entry) for entry in self._read_all()]

    def get_site(self, site_id: str) -> Optional[Site]:
        """Look up a single site by its UUID."""
        for entry in self._read_all():
            if entry.get("id") == site_id:
                return Site.from_dict(entry)
        return None

    def create_site(self, site: Site) -> Site:
        """Append a new site and persist."""
        entries = self._read_all()
        entries.append(site.to_dict())
        self._write_all(entries)
        return site

    def update_site(self, site_id: str, updates: dict) -> Optional[Site]:
        """Merge *updates* into the matching site and persist."""
        entries = self._read_all()
        for idx, entry in enumerate(entries):
            if entry.get("id") == site_id:
                entry.update(updates)
                entry["id"] = site_id  # prevent id overwrite
                entries[idx] = entry
                self._write_all(entries)
                return Site.from_dict(entry)
        return None

    def delete_site(self, site_id: str) -> bool:
        """Remove the site with *site_id*.  Returns ``True`` on success."""
        entries = self._read_all()
        filtered = [e for e in entries if e.get("id") != site_id]
        if len(filtered) == len(entries):
            return False
        self._write_all(filtered)
        return True
