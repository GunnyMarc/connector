"""Flask application entry point for the Connector application."""

from __future__ import annotations

from collections import OrderedDict
from typing import Any

from flask import Flask, request

from py_flask.config import Config
from py_flask.routes.connections import connections_bp
from py_flask.routes.folders import folders_bp
from py_flask.routes.settings import settings_bp
from py_flask.routes.sites import sites_bp
from py_flask.services.crypto_service import CryptoService
from py_flask.services.settings_service import SettingsService
from py_flask.services.storage import SiteStorage
from py_flask.services.terminal_service import TerminalService, detect_platform


# ── Folder tree builder ───────────────────────────────────────────────────────

# Separator used in folder paths (e.g. "AWS/Production").
FOLDER_SEP = "/"


def _build_folder_tree(
    folder_paths: list[str],
    all_sites: list,
) -> list[dict[str, Any]]:
    """Build a recursive folder tree from a flat list of folder paths.

    Each node is a dict::

        {
            "name":     "Production",   # display label (last segment)
            "path":     "AWS/Production",  # full path (used as key)
            "children": [...],            # sub-folder nodes
            "sites":    [Site, ...],      # sites assigned to this folder
        }

    *folder_paths* is ordered; the tree preserves that order at each level.

    Sites are assigned to the **deepest matching** folder path.  Sites whose
    ``folder`` value does not match any known path are returned separately by
    the caller (they belong to root).
    """
    # Map full path → node  (insertion-order preserved)
    nodes: OrderedDict[str, dict] = OrderedDict()
    for path in folder_paths:
        nodes[path] = {
            "name": path.rsplit(FOLDER_SEP, 1)[-1],
            "path": path,
            "children": [],
            "sites": [],
        }

    # Assign sites to their folder node
    site_index: set[str] = set()
    for site in all_sites:
        if site.folder and site.folder in nodes:
            nodes[site.folder]["sites"].append(site)
            site_index.add(site.id)

    # Build tree: attach children to parents.  A folder "A/B" is a child
    # of "A" only if "A" also exists in the nodes map.
    root_nodes: list[dict] = []
    for path, node in nodes.items():
        parent_path = path.rsplit(FOLDER_SEP, 1)[0] if FOLDER_SEP in path else ""
        if parent_path and parent_path in nodes:
            nodes[parent_path]["children"].append(node)
        else:
            root_nodes.append(node)

    return root_nodes


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

    # Apply the user-selected terminal preference (if any) from settings.
    saved = settings_svc.get_all()
    if saved.get("terminal_name"):
        terminal.set_terminal(
            saved["terminal_name"], saved.get("terminal_path", ""),
        )

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

        # Build the recursive folder tree for the sidebar
        folder_tree = _build_folder_tree(folder_names, all_sites)

        # Flat folders map (still used by the site form dropdown + legacy)
        folders_map: OrderedDict[str, list] = OrderedDict()
        for fname in folder_names:
            folders_map[fname] = []
        for site in all_sites:
            if site.folder and site.folder in folders_map:
                folders_map[site.folder].append(site)

        # Root sites (no folder or unknown folder)
        assigned = {s.id for s in all_sites if s.folder and s.folder in folders_map}
        root_sites = [s for s in all_sites if s.id not in assigned]

        return {
            "sidebar_sites": all_sites,
            "sidebar_root_sites": root_sites,
            "sidebar_folders": folders_map,
            "sidebar_folder_tree": folder_tree,
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

    # Build SSL context when HTTPS is enabled.
    ssl_ctx = None
    if Config.SSL_ENABLED:
        from py_flask.services.ssl_service import ensure_ssl_certs

        cert, key = ensure_ssl_certs(
            Config.SSL_CERT_FILE,
            Config.SSL_KEY_FILE,
            hostname=Config.HOST,
        )
        ssl_ctx = (str(cert), str(key))
        scheme = "https"
    else:
        scheme = "http"

    print(f"  Connector running on {scheme}://{Config.HOST}:{Config.PORT}")
    application.run(
        host=Config.HOST,
        port=Config.PORT,
        debug=True,
        ssl_context=ssl_ctx,
    )
