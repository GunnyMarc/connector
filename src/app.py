"""Flask application entry point for the Connector application."""

from __future__ import annotations

from collections import OrderedDict

from flask import Flask, request

from src.config import Config
from src.routes.connections import connections_bp
from src.routes.folders import folders_bp
from src.routes.settings import settings_bp
from src.routes.sites import sites_bp
from src.services.crypto_service import CryptoService
from src.services.settings_service import SettingsService
from src.services.storage import SiteStorage
from src.services.terminal_service import TerminalService, detect_platform


def create_app() -> Flask:
    """Application factory — build and configure the Flask app."""
    app = Flask(
        __name__,
        template_folder="templates",
        static_folder="static",
    )
    app.secret_key = Config.SECRET_KEY

    # Detect host platform and default terminal at startup
    platform_info = detect_platform()
    terminal = TerminalService(platform_info)
    app.config["PLATFORM_INFO"] = platform_info
    app.config["TERMINAL"] = terminal

    # Initialise encrypted storage
    crypto = CryptoService(Config.KEY_FILE)
    storage = SiteStorage(Config.SITES_FILE, crypto)
    app.config["STORAGE"] = storage

    # Initialise global settings
    settings_svc = SettingsService(Config.SETTINGS_FILE, crypto)
    app.config["SETTINGS"] = settings_svc

    # ── Context processor — inject sidebar data into every template ────────
    @app.context_processor
    def inject_sidebar() -> dict:
        all_sites = storage.list_sites()

        # Determine the active site from either ?site= query param
        # or the <site_id> path segment used by sub-page routes.
        active_id = (
            request.args.get("site")
            or (request.view_args or {}).get("site_id")
        )
        active_site = storage.get_site(active_id) if active_id else None

        # Build folder → [sites] mapping preserving settings order
        global_settings = settings_svc.get_all()
        folder_names: list[str] = global_settings.get("folders", [])

        # Ordered dict: folder name → list of sites in that folder
        folders_map: OrderedDict[str, list] = OrderedDict()
        for fname in folder_names:
            folders_map[fname] = []

        # Root sites (no folder assigned)
        root_sites = []
        for site in all_sites:
            if site.folder and site.folder in folders_map:
                folders_map[site.folder].append(site)
            else:
                root_sites.append(site)

        return {
            "sidebar_sites": all_sites,
            "sidebar_root_sites": root_sites,
            "sidebar_folders": folders_map,
            "active_site": active_site,
            "platform_info": platform_info,
        }

    # Register route blueprints
    app.register_blueprint(sites_bp)
    app.register_blueprint(connections_bp)
    app.register_blueprint(settings_bp)
    app.register_blueprint(folders_bp)

    return app


if __name__ == "__main__":
    application = create_app()
    application.run(host=Config.HOST, port=Config.PORT, debug=True)
