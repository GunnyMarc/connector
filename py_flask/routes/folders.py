"""Folder management routes for organising sessions in the sidebar.

Folders use path-based naming with ``/`` as separator to support
arbitrary nesting.  For example, ``"AWS/Production"`` is a subfolder
of ``"AWS"``.  The flat ``folders`` list in settings stores every path
(parents and children); the context processor builds the tree.
"""

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

from py_flask.services.settings_service import SettingsService
from py_flask.services.storage import SiteStorage

folders_bp = Blueprint("folders", __name__)

FOLDER_SEP = "/"


def _storage() -> SiteStorage:
    """Retrieve the shared :class:`SiteStorage` from the app config."""
    return current_app.config["STORAGE"]


def _settings() -> SettingsService:
    """Retrieve the shared :class:`SettingsService` from the app config."""
    return current_app.config["SETTINGS"]


def _sanitise_folder_name(name: str) -> str:
    """Strip whitespace and collapse repeated separators."""
    parts = [p.strip() for p in name.split(FOLDER_SEP) if p.strip()]
    return FOLDER_SEP.join(parts)


# ── Create folder ─────────────────────────────────────────────────────────────


@folders_bp.route("/folders/create", methods=["POST"])
def create():
    """Create a new folder (or subfolder).

    Accepts either form data or JSON.  The ``name`` field may be a simple
    name (created at root) or a path like ``"AWS/Production"`` to create
    a subfolder.  Alternatively, pass ``parent`` to automatically prefix
    the new name — e.g. ``{"name": "Production", "parent": "AWS"}``
    creates ``"AWS/Production"``.

    Any missing intermediate folders are created automatically.
    """
    if request.is_json:
        data = request.get_json(silent=True) or {}
        raw_name = data.get("name", "").strip()
        parent = data.get("parent", "").strip()
    else:
        raw_name = request.form.get("name", "").strip()
        parent = request.form.get("parent", "").strip()

    if not raw_name:
        if request.is_json:
            return jsonify({"error": "Folder name is required."}), 400
        flash("Folder name is required.", "danger")
        return redirect(url_for("sites.index"))

    # Build the full path
    if parent:
        full_path = _sanitise_folder_name(parent + FOLDER_SEP + raw_name)
    else:
        full_path = _sanitise_folder_name(raw_name)

    if not full_path:
        if request.is_json:
            return jsonify({"error": "Folder name is required."}), 400
        flash("Folder name is required.", "danger")
        return redirect(url_for("sites.index"))

    svc = _settings()
    settings = svc.get_all()
    folders: list[str] = settings.get("folders", [])

    if full_path in folders:
        if request.is_json:
            return jsonify({"error": f"Folder '{full_path}' already exists."}), 409
        flash(f"Folder '{full_path}' already exists.", "warning")
        return redirect(url_for("sites.index"))

    # Auto-create intermediate parent folders that don't exist yet.
    parts = full_path.split(FOLDER_SEP)
    for i in range(1, len(parts) + 1):
        ancestor = FOLDER_SEP.join(parts[:i])
        if ancestor not in folders:
            folders.append(ancestor)

    svc.update({"folders": folders})

    if request.is_json:
        return jsonify({"ok": True, "folder": full_path, "folders": folders})

    flash(f"Folder '{full_path}' created.", "success")
    return redirect(url_for("sites.index"))


# ── Rename folder ─────────────────────────────────────────────────────────────


@folders_bp.route("/folders/rename", methods=["POST"])
def rename():
    """Rename an existing folder.

    Also updates the ``folder`` field on every site in the old folder
    (and its subfolders), and renames all descendant folder paths.
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

    # Rename this folder and all descendant paths.
    old_prefix = old_name + FOLDER_SEP
    updated_folders = []
    for f in folders:
        if f == old_name:
            updated_folders.append(new_name)
        elif f.startswith(old_prefix):
            updated_folders.append(new_name + f[len(old_name):])
        else:
            updated_folders.append(f)

    svc.update({"folders": updated_folders})

    # Update all sites whose folder matches (exactly or as a descendant).
    storage = _storage()
    for site in storage.list_sites():
        if site.folder == old_name:
            storage.update_site(site.id, {"folder": new_name})
        elif site.folder.startswith(old_prefix):
            new_folder = new_name + site.folder[len(old_name):]
            storage.update_site(site.id, {"folder": new_folder})

    if request.is_json:
        return jsonify({"ok": True, "folders": updated_folders})

    flash(f"Folder renamed to '{new_name}'.", "success")
    return redirect(url_for("sites.index"))


# ── Delete folder ─────────────────────────────────────────────────────────────


@folders_bp.route("/folders/delete", methods=["POST"])
def delete():
    """Delete a folder and all of its subfolders.

    Sites in the folder (and subfolders) are moved back to the root.
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

    # Remove this folder and all descendants.
    prefix = name + FOLDER_SEP
    removed = {f for f in folders if f == name or f.startswith(prefix)}
    folders = [f for f in folders if f not in removed]
    svc.update({"folders": folders})

    # Move sites in removed folders back to root.
    storage = _storage()
    for site in storage.list_sites():
        if site.folder in removed:
            storage.update_site(site.id, {"folder": ""})

    if request.is_json:
        return jsonify({"ok": True, "folders": folders})

    flash(f"Folder '{name}' deleted.", "success")
    return redirect(url_for("sites.index"))


# ── Move site to folder ──────────────────────────────────────────────────────


@folders_bp.route("/folders/move", methods=["POST"])
def move_site():
    """Move a site into (or out of) a folder.

    Expects JSON: ``{"site_id": "...", "folder": "AWS/Production"}``
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
