"""Settings routes for global application options, import and export."""

from __future__ import annotations

import json
from datetime import datetime

from flask import (
    Blueprint,
    Response,
    current_app,
    flash,
    redirect,
    render_template,
    request,
    url_for,
)

from src.models.site import Site
from src.services.settings_service import SettingsService
from src.services.storage import SiteStorage

settings_bp = Blueprint("settings", __name__)

# Fields stripped from exported site data (credentials).
_CREDENTIAL_FIELDS = ("password", "key_path")


def _settings() -> SettingsService:
    """Retrieve the shared :class:`SettingsService` from the app config."""
    return current_app.config["SETTINGS"]


def _storage() -> SiteStorage:
    """Retrieve the shared :class:`SiteStorage` from the app config."""
    return current_app.config["STORAGE"]


# ── Settings page ─────────────────────────────────────────────────────────────


@settings_bp.route("/settings", methods=["GET", "POST"])
def index():
    """Show or update global application settings.

    ``platform_info`` is injected by the context processor automatically.
    """
    svc = _settings()

    if request.method == "POST":
        updates = {
            "default_port": int(request.form.get("default_port", 22)),
            "ssh_timeout": int(request.form.get("ssh_timeout", 10)),
            "command_timeout": int(request.form.get("command_timeout", 30)),
            "default_username": request.form.get("default_username", ""),
            "default_auth_type": request.form.get("default_auth_type", "password"),
            "default_key_path": request.form.get("default_key_path", "~/.ssh/id_rsa"),
        }
        svc.update(updates)
        flash("Settings saved.", "success")
        return redirect(url_for("settings.index"))

    return render_template("settings.html", settings=svc.get_all())


# ── Export ────────────────────────────────────────────────────────────────────


@settings_bp.route("/settings/export")
def export_sessions():
    """Export all sessions and folder structure to a JSON file.

    Credentials (password, key_path) are **stripped** from the export.
    Usernames and all other session fields are preserved.
    """
    storage = _storage()
    svc = _settings()

    sites = storage.list_sites()
    settings = svc.get_all()
    folders: list[str] = settings.get("folders", [])

    # Build export payload — strip credentials from each site.
    exported_sites = []
    for site in sites:
        d = site.to_dict()
        for field in _CREDENTIAL_FIELDS:
            d.pop(field, None)
        exported_sites.append(d)

    payload = {
        "connector_export": True,
        "version": 1,
        "exported_at": datetime.utcnow().isoformat() + "Z",
        "folders": folders,
        "sites": exported_sites,
    }

    timestamp = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
    filename = f"connector_export_{timestamp}.json"

    return Response(
        json.dumps(payload, indent=2, ensure_ascii=False),
        mimetype="application/json",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


# ── Import ────────────────────────────────────────────────────────────────────


@settings_bp.route("/settings/import", methods=["POST"])
def import_sessions():
    """Import sessions and folder structure from a JSON file.

    The import restores folders, session metadata, and usernames.
    Passwords and SSH key paths are **not** included in the export file
    and must be entered separately after import.

    Duplicate sites (matched by name + hostname + protocol) are skipped.
    """
    uploaded = request.files.get("import_file")
    if not uploaded or not uploaded.filename:
        flash("No file selected.", "danger")
        return redirect(url_for("settings.index"))

    try:
        raw = uploaded.read().decode("utf-8")
        data = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        flash(f"Invalid JSON file: {exc}", "danger")
        return redirect(url_for("settings.index"))

    if not isinstance(data, dict) or not data.get("connector_export"):
        flash("File is not a valid Connector export.", "danger")
        return redirect(url_for("settings.index"))

    storage = _storage()
    svc = _settings()

    # ── Import folders ────────────────────────────────────────────────────
    import_folders: list[str] = data.get("folders", [])
    if import_folders:
        current_settings = svc.get_all()
        current_folders: list[str] = current_settings.get("folders", [])
        current_set = set(current_folders)
        for fname in import_folders:
            if fname and fname not in current_set:
                current_folders.append(fname)
                current_set.add(fname)
        svc.update({"folders": current_folders})

    # ── Import sites ──────────────────────────────────────────────────────
    import_sites: list[dict] = data.get("sites", [])
    existing = storage.list_sites()

    # Build a dedup key set from existing sites.
    existing_keys = {
        (s.name, s.hostname, getattr(s, "protocol", "ssh2"))
        for s in existing
    }

    imported_count = 0
    skipped_count = 0
    for site_dict in import_sites:
        if not isinstance(site_dict, dict) or "name" not in site_dict:
            continue

        # Ensure credentials are blank (even if someone edited the file).
        site_dict["password"] = ""
        site_dict["key_path"] = ""

        name = site_dict.get("name", "")
        hostname = site_dict.get("hostname", "")
        protocol = site_dict.get("protocol", "ssh2")

        if (name, hostname, protocol) in existing_keys:
            skipped_count += 1
            continue

        # Drop the old ID so a fresh UUID is generated.
        site_dict.pop("id", None)

        try:
            site = Site.from_dict(site_dict)
            storage.create_site(site)
            existing_keys.add((name, hostname, protocol))
            imported_count += 1
        except (TypeError, ValueError):
            skipped_count += 1

    parts = []
    if imported_count:
        parts.append(f"{imported_count} session(s) imported")
    if skipped_count:
        parts.append(f"{skipped_count} skipped (duplicate or invalid)")
    if not parts:
        parts.append("No sessions found in file")

    flash(". ".join(parts) + ".", "success" if imported_count else "info")
    return redirect(url_for("settings.index"))
