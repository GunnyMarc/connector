"""Site connection data model."""

from __future__ import annotations

import uuid
from dataclasses import asdict, dataclass, field
from typing import Optional

# Supported protocol identifiers.
PROTOCOLS = ("ssh2", "ssh1", "local", "raw", "telnet", "serial")

# Human-readable labels for each protocol.
PROTOCOL_LABELS = {
    "ssh2": "SSH2",
    "ssh1": "SSH1",
    "local": "Local Shell",
    "raw": "Raw",
    "telnet": "Telnet",
    "serial": "Serial",
}


@dataclass
class Site:
    """Represents a remote site connection entry.

    Attributes:
        name:        Human-readable label for the site.
        hostname:    DNS name or IP address.
        port:        Network port (default 22).
        username:    Login user.
        auth_type:   Either ``"password"`` or ``"key"``.
        password:    Password when *auth_type* is ``"password"``.
        key_path:    Path to SSH private key when *auth_type* is ``"key"``.
        notes:       Free-form notes about the site.
        folder:      Folder name for sidebar grouping (empty = root).
        protocol:    Connection protocol (``ssh2``, ``ssh1``, ``local``,
                     ``raw``, ``telnet``, ``serial``).  Defaults to ``ssh2``
                     for backward compatibility.
        serial_port: Device path for serial connections (e.g. ``/dev/ttyUSB0``).
        serial_baud: Baud rate for serial connections (default 9600).
        sftp_root:   Absolute path where the SFTP file browser starts
                     (empty = remote home directory).
        id:          Auto-generated UUID.
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
    protocol: str = "ssh2"
    serial_port: str = ""
    serial_baud: int = 9600
    sftp_root: str = ""
    id: str = field(default_factory=lambda: str(uuid.uuid4()))

    @property
    def protocol_label(self) -> str:
        """Return the human-readable label for this site's protocol."""
        return PROTOCOL_LABELS.get(self.protocol, self.protocol)

    @property
    def is_ssh(self) -> bool:
        """Return ``True`` if the protocol is SSH (v1 or v2)."""
        return self.protocol in ("ssh1", "ssh2")

    @property
    def is_network(self) -> bool:
        """Return ``True`` if the protocol uses hostname/port."""
        return self.protocol in ("ssh1", "ssh2", "raw", "telnet")

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
