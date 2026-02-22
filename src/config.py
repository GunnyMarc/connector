"""Application configuration loaded from environment variables."""

from __future__ import annotations

import os
import secrets
from pathlib import Path


class Config:
    """Central configuration for the Connector application."""

    BASE_DIR: Path = Path(__file__).resolve().parent.parent
    DATA_DIR: Path = Path(os.getenv("CONNECTOR_DATA_DIR", str(BASE_DIR / "data")))

    # Encrypted storage paths
    SITES_FILE: Path = DATA_DIR / "sites.enc"
    SETTINGS_FILE: Path = DATA_DIR / "settings.enc"
    KEY_FILE: Path = DATA_DIR / ".key"

    # Flask
    SECRET_KEY: str = os.getenv("FLASK_SECRET_KEY", secrets.token_hex(32))
    HOST: str = os.getenv("CONNECTOR_HOST", "127.0.0.1")
    PORT: int = int(os.getenv("CONNECTOR_PORT", "5101"))

    # SSH defaults
    SSH_TIMEOUT: int = int(os.getenv("SSH_TIMEOUT", "10"))
    SSH_COMMAND_TIMEOUT: int = int(os.getenv("SSH_COMMAND_TIMEOUT", "30"))
