"""Folder management routes for organising sessions in the sidebar."""

from __future__ import annotations

from flask import (
    Blueprint,
    current_app,
    flash,
    jsonify,
    redirect,
    request,
    url_for,
)

from src.services.settings_service import SettingsService
from src.services.storage import SiteStorage

folders_bp = Blueprint("folders", __name__)


def _storage() -> SiteStorage:
    """Retrieve the shared :class:`SiteStorage` from the app config."""
    return current_app.config["STORAGE"]


def _settings() -> SettingsService:
    """Retrieve the shared :class:`SettingsService` from the app config."""
    return current_app.config["SETTINGS"]


# ── Create folder ─────────────────────────────────────────────────────────────


@folders_bp.route("/folders/create", methods=["POST"])
def create():
    """Create a new folder.

    Accepts either form data (``name``) for traditional POST, or JSON
    (``{"name": "..."}``) for AJAX calls from the sidebar.
    """
    if request.is_json:
        data = request.get_json(silent=True) or {}
        name = data.get("name", "").strip()
    else:
        name = request.form.get("name", "").strip()

    if not name:
        if request.is_json:
            return jsonify({"error": "Folder name is required."}), 400
        flash("Folder name is required.", "danger")
        return redirect(url_for("sites.index"))

    svc = _settings()
    settings = svc.get_all()
    folders: list[str] = settings.get("folders", [])

    if name in folders:
        if request.is_json:
            return jsonify({"error": f"Folder '{name}' already exists."}), 409
        flash(f"Folder '{name}' already exists.", "warning")
        return redirect(url_for("sites.index"))

    folders.append(name)
    svc.update({"folders": folders})

    if request.is_json:
        return jsonify({"ok": True, "folder": name, "folders": folders})

    flash(f"Folder '{name}' created.", "success")
    return redirect(url_for("sites.index"))


# ── Rename folder ─────────────────────────────────────────────────────────────


@folders_bp.route("/folders/rename", methods=["POST"])
def rename():
    """Rename an existing folder.

    Also updates the ``folder`` field on every site in the old folder.
    """
    if request.is_json:
        data = request.get_json(silent=True) or {}
        old_name = data.get("old_name", "").strip()
        new_name = data.get("new_name", "").strip()
    else:
        old_name = request.form.get("old_name", "").strip()
        new_name = request.form.get("new_name", "").strip()

    if not old_name or not new_name:
        msg = "Both old and new folder names are required."
        if request.is_json:
            return jsonify({"error": msg}), 400
        flash(msg, "danger")
        return redirect(url_for("sites.index"))

    svc = _settings()
    settings = svc.get_all()
    folders: list[str] = settings.get("folders", [])

    if old_name not in folders:
        msg = f"Folder '{old_name}' not found."
        if request.is_json:
            return jsonify({"error": msg}), 404
        flash(msg, "danger")
        return redirect(url_for("sites.index"))

    if new_name in folders:
        msg = f"Folder '{new_name}' already exists."
        if request.is_json:
            return jsonify({"error": msg}), 409
        flash(msg, "warning")
        return redirect(url_for("sites.index"))

    # Rename in folder list
    idx = folders.index(old_name)
    folders[idx] = new_name
    svc.update({"folders": folders})

    # Update all sites that were in the old folder
    storage = _storage()
    for site in storage.list_sites():
        if site.folder == old_name:
            storage.update_site(site.id, {"folder": new_name})

    if request.is_json:
        return jsonify({"ok": True, "folders": folders})

    flash(f"Folder renamed to '{new_name}'.", "success")
    return redirect(url_for("sites.index"))


# ── Delete folder ─────────────────────────────────────────────────────────────


@folders_bp.route("/folders/delete", methods=["POST"])
def delete():
    """Delete a folder.

    Sites in the folder are moved back to the root (unfoldered).
    """
    if request.is_json:
        data = request.get_json(silent=True) or {}
        name = data.get("name", "").strip()
    else:
        name = request.form.get("name", "").strip()

    if not name:
        msg = "Folder name is required."
        if request.is_json:
            return jsonify({"error": msg}), 400
        flash(msg, "danger")
        return redirect(url_for("sites.index"))

    svc = _settings()
    settings = svc.get_all()
    folders: list[str] = settings.get("folders", [])

    if name not in folders:
        msg = f"Folder '{name}' not found."
        if request.is_json:
            return jsonify({"error": msg}), 404
        flash(msg, "danger")
        return redirect(url_for("sites.index"))

    folders.remove(name)
    svc.update({"folders": folders})

    # Move sites back to root
    storage = _storage()
    for site in storage.list_sites():
        if site.folder == name:
            storage.update_site(site.id, {"folder": ""})

    if request.is_json:
        return jsonify({"ok": True, "folders": folders})

    flash(f"Folder '{name}' deleted.", "success")
    return redirect(url_for("sites.index"))


# ── Move site to folder ──────────────────────────────────────────────────────


@folders_bp.route("/folders/move", methods=["POST"])
def move_site():
    """Move a site into (or out of) a folder.

    Expects JSON: ``{"site_id": "...", "folder": "FolderName"}``
    Pass ``folder: ""`` to move a site back to the root.
    """
    data = request.get_json(silent=True) or {}
    site_id = data.get("site_id", "").strip()
    folder = data.get("folder", "")

    if not site_id:
        return jsonify({"error": "site_id is required."}), 400

    storage = _storage()
    site = storage.get_site(site_id)
    if not site:
        return jsonify({"error": "Site not found."}), 404

    # Validate the target folder exists (unless moving to root)
    if folder:
        svc = _settings()
        folders: list[str] = svc.get_all().get("folders", [])
        if folder not in folders:
            return jsonify({"error": f"Folder '{folder}' not found."}), 404

    storage.update_site(site_id, {"folder": folder})
    return jsonify({"ok": True, "site_id": site_id, "folder": folder})


# ── Reorder folders ──────────────────────────────────────────────────────────


@folders_bp.route("/folders/reorder", methods=["POST"])
def reorder():
    """Persist a new folder ordering.

    Expects JSON: ``{"folders": ["FolderB", "FolderA", ...]}``
    The provided list must contain exactly the same set of folder names
    as the currently stored list — no additions or removals.
    """
    data = request.get_json(silent=True) or {}
    new_order: list = data.get("folders", [])

    if not isinstance(new_order, list):
        return jsonify({"error": "folders must be a list."}), 400

    svc = _settings()
    current: list[str] = svc.get_all().get("folders", [])

    # Validate: same set of names, no duplicates
    if sorted(new_order) != sorted(current):
        return jsonify({
            "error": "Folder list must contain exactly the same folders.",
        }), 400

    if len(new_order) != len(set(new_order)):
        return jsonify({"error": "Duplicate folder names."}), 400

    svc.update({"folders": new_order})
    return jsonify({"ok": True, "folders": new_order})
