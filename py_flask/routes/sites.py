"""CRUD routes for site management."""

from __future__ import annotations

import os
import shutil
import subprocess

from flask import (
    Blueprint,
    current_app,
    flash,
    jsonify,
    redirect,
    render_template,
    request,
    url_for,
)

from py_flask.models.site import Site
from py_flask.services.storage import SiteStorage

sites_bp = Blueprint("sites", __name__)


def _storage() -> SiteStorage:
    """Retrieve the shared :class:`SiteStorage` from the app config."""
    return current_app.config["STORAGE"]


# ── List (dashboard) ──────────────────────────────────────────────────────────


@sites_bp.route("/")
def index():
    """Render the session-manager dashboard.

    The context processor injects ``sidebar_sites``, ``active_site``, and
    ``platform_info`` automatically — no need to pass them from the route.
    """
    return render_template("index.html")


# ── Create ────────────────────────────────────────────────────────────────────


@sites_bp.route("/sites/new", methods=["GET", "POST"])
def create():
    """Show the new-site form or process its submission."""
    if request.method == "POST":
        site = Site(
            name=request.form["name"],
            hostname=request.form.get("hostname", ""),
            port=int(request.form.get("port", 22)),
            username=request.form.get("username", ""),
            auth_type=request.form.get("auth_type", "password"),
            password=request.form.get("password", ""),
            key_path=request.form.get("key_path", ""),
            notes=request.form.get("notes", ""),
            folder=request.form.get("folder", ""),
            protocol=request.form.get("protocol", "ssh2"),
            serial_port=request.form.get("serial_port", ""),
            serial_baud=int(request.form.get("serial_baud", 9600)),
            sftp_root=request.form.get("sftp_root", ""),
        )
        _storage().create_site(site)
        flash(f"Site '{site.name}' created.", "success")
        return redirect(url_for("sites.index"))

    return render_template("site_form.html", site=None)


# ── Update ────────────────────────────────────────────────────────────────────


@sites_bp.route("/sites/<site_id>/edit", methods=["GET", "POST"])
def edit(site_id: str):
    """Show the edit form for *site_id* or process the update."""
    site = _storage().get_site(site_id)
    if not site:
        flash("Site not found.", "danger")
        return redirect(url_for("sites.index"))

    if request.method == "POST":
        updates = {
            "name": request.form["name"],
            "hostname": request.form.get("hostname", ""),
            "port": int(request.form.get("port", 22)),
            "username": request.form.get("username", ""),
            "auth_type": request.form.get("auth_type", "password"),
            "password": request.form.get("password", ""),
            "key_path": request.form.get("key_path", ""),
            "notes": request.form.get("notes", ""),
            "folder": request.form.get("folder", ""),
            "protocol": request.form.get("protocol", "ssh2"),
            "serial_port": request.form.get("serial_port", ""),
            "serial_baud": int(request.form.get("serial_baud", 9600)),
            "sftp_root": request.form.get("sftp_root", ""),
        }
        _storage().update_site(site_id, updates)
        flash(f"Site '{updates['name']}' updated.", "success")
        return redirect(url_for("sites.index"))

    return render_template("site_form.html", site=site)


# ── Duplicate ─────────────────────────────────────────────────────────────────


@sites_bp.route("/sites/<site_id>/duplicate", methods=["POST"])
def duplicate(site_id: str):
    """Create a copy of the site with '(Copy)' appended to the name."""
    storage = _storage()
    original = storage.get_site(site_id)
    if not original:
        flash("Site not found.", "danger")
        return redirect(url_for("sites.index"))

    copy = Site(
        name=f"{original.name} (Copy)",
        hostname=original.hostname,
        port=original.port,
        username=original.username,
        auth_type=original.auth_type,
        password=original.password,
        key_path=original.key_path,
        notes=original.notes,
        folder=original.folder,
        protocol=original.protocol,
        serial_port=original.serial_port,
        serial_baud=original.serial_baud,
        sftp_root=original.sftp_root,
    )
    storage.create_site(copy)
    flash(f"Site '{copy.name}' created.", "success")
    return redirect(url_for("sites.index", site=copy.id))


# ── Delete ────────────────────────────────────────────────────────────────────


@sites_bp.route("/sites/<site_id>/delete", methods=["POST"])
def delete(site_id: str):
    """Delete the site identified by *site_id*."""
    site = _storage().get_site(site_id)
    name = site.name if site else "Unknown"

    if _storage().delete_site(site_id):
        flash(f"Site '{name}' deleted.", "success")
    else:
        flash("Site not found.", "danger")

    return redirect(url_for("sites.index"))


# ── File browser API ──────────────────────────────────────────────────────────


@sites_bp.route("/api/browse-key", methods=["POST"])
def browse_key():
    """Open a native file dialog to select an SSH key file.

    Uses platform-specific tools (``osascript`` on macOS, ``zenity`` or
    ``kdialog`` on Linux) to present a file chooser starting in ``~/.ssh``.

    Returns JSON ``{"path": "/path/to/key"}`` on success, or
    ``{"path": ""}`` if the user cancelled or an error occurred.
    """
    platform_info = current_app.config.get("PLATFORM_INFO")
    system = platform_info.system if platform_info else "unknown"

    initial_dir = os.path.expanduser("~/.ssh")
    if not os.path.isdir(initial_dir):
        initial_dir = os.path.expanduser("~")

    selected_path = ""

    try:
        if system == "Darwin":
            script = (
                f'set d to POSIX file "{initial_dir}" as alias\n'
                "POSIX path of (choose file with prompt "
                '"Select SSH Key" default location d)'
            )
            result = subprocess.run(
                ["osascript", "-e", script],
                capture_output=True,
                text=True,
                timeout=120,
            )
            if result.returncode == 0:
                selected_path = result.stdout.strip()

        elif system == "Linux":
            for cmd in [
                [
                    "zenity",
                    "--file-selection",
                    "--title=Select SSH Key",
                    f"--filename={initial_dir}/",
                ],
                [
                    "kdialog",
                    "--getopenfilename",
                    initial_dir,
                    "All Files (*)",
                ],
            ]:
                if shutil.which(cmd[0]):
                    result = subprocess.run(
                        cmd,
                        capture_output=True,
                        text=True,
                        timeout=120,
                    )
                    if result.returncode == 0:
                        selected_path = result.stdout.strip()
                    break

    except (subprocess.TimeoutExpired, OSError):
        pass

    return jsonify({"path": selected_path})
