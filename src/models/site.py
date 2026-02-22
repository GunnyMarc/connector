"""Site connection data model."""

from __future__ import annotations

import uuid
from dataclasses import asdict, dataclass, field
from typing import Optional


@dataclass
class Site:
    """Represents a remote site connection entry.

    Attributes:
        name:      Human-readable label for the site.
        hostname:  DNS name or IP address.
        port:      SSH port (default 22).
        username:  Login user.
        auth_type: Either ``"password"`` or ``"key"``.
        password:  Password when *auth_type* is ``"password"``.
        key_path:  Path to SSH private key when *auth_type* is ``"key"``.
        notes:     Free-form notes about the site.
        folder:    Folder name for sidebar grouping (empty = root).
        id:        Auto-generated UUID.
    """

    name: str
    hostname: str
    port: int = 22
    username: str = ""
    auth_type: str = "password"
    password: str = ""
    key_path: str = ""
    notes: str = ""
    folder: str = ""
    id: str = field(default_factory=lambda: str(uuid.uuid4()))

    def to_dict(self) -> dict:
        """Serialise the site to a plain dictionary."""
        return asdict(self)

    @classmethod
    def from_dict(cls, data: dict) -> Site:
        """Create a ``Site`` from a dictionary, ignoring unknown keys."""
        known_keys = cls.__dataclass_fields__
        return cls(**{k: v for k, v in data.items() if k in known_keys})

    def masked_password(self) -> str:
        """Return the password replaced with asterisks (for display)."""
        if not self.password:
            return ""
        return "*" * min(len(self.password), 8)
