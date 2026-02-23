"""Connection routes for all protocols (SSH, SFTP, local, raw, telnet, serial)."""

from __future__ import annotations

import os
import tempfile

from flask import (
    Blueprint,
    current_app,
    flash,
    redirect,
    render_template,
    request,
    send_file,
    url_for,
)

from src.services.ssh_service import SSHService
from src.services.storage import SiteStorage
from src.services.terminal_service import PlatformInfo, TerminalService

connections_bp = Blueprint("connections", __name__)


def _storage() -> SiteStorage:
    return current_app.config["STORAGE"]


def _terminal() -> TerminalService:
    return current_app.config["TERMINAL"]


def _platform_info() -> PlatformInfo:
    return current_app.config["PLATFORM_INFO"]


# ── Quick connect ────────────────────────────────────────────────────────────


@connections_bp.route("/quick-connect", methods=["POST"])
def quick_connect():
    """Parse a host string and open an SSH session in the native terminal."""
    raw = request.form.get("host", "").strip()
    if not raw:
        flash("Enter a hostname to connect.", "warning")
        return redirect(url_for("sites.index"))

    # Parse optional user@host:port format
    username = ""
    port = 22
    host = raw

    if "@" in host:
        username, host = host.rsplit("@", 1)
    if ":" in host:
        host, port_str = host.rsplit(":", 1)
        try:
            port = int(port_str)
        except ValueError:
            flash(f"Invalid port: {port_str}", "danger")
            return redirect(url_for("sites.index"))

    try:
        _terminal().launch_ssh(hostname=host, port=port, username=username)
        flash(f"SSH session opened for {raw}.", "success")
    except RuntimeError as exc:
        flash(f"Failed to launch terminal: {exc}", "danger")

    return redirect(url_for("sites.index"))


# ── Connect — native terminal launch (all protocols) ─────────────────────────


@connections_bp.route("/sites/<site_id>/ssh", methods=["GET", "POST"])
def ssh(site_id: str):
    """Show connection details or launch a native terminal session.

    Handles all protocols (ssh1, ssh2, local, raw, telnet, serial).
    The route path is kept as ``/ssh`` for backward compatibility.
    """
    site = _storage().get_site(site_id)
    if not site:
        flash("Site not found.", "danger")
        return redirect(url_for("sites.index"))

    info = _platform_info()
    protocol = getattr(site, "protocol", "ssh2")
    protocol_label = getattr(site, "protocol_label", "SSH2")

    if request.method == "POST":
        try:
            _terminal().launch_session(site)
            flash(
                f"{protocol_label} session opened in {info.terminal}"
                f" for '{site.name}'.",
                "success",
            )
        except RuntimeError as exc:
            flash(f"Failed to launch terminal: {exc}", "danger")

        return redirect(url_for("connections.ssh", site_id=site_id))

    return render_template("ssh.html", site=site)


# ── SFTP file browser ────────────────────────────────────────────────────────


@connections_bp.route("/sites/<site_id>/sftp")
def sftp(site_id: str):
    """List the contents of a remote directory via SFTP.

    The directory is taken from the ``?path=`` query parameter.  When
    omitted the session's ``sftp_root`` is used, falling back to the
    remote home directory.

    All paths are normalised to absolute form via ``sftp.normalize()``
    so that directory links in the template are always unambiguous.
    """
    site = _storage().get_site(site_id)
    if not site:
        flash("Site not found.", "danger")
        return redirect(url_for("sites.index"))

    # Determine the starting path.
    remote_path = request.args.get("path", "").strip()
    if not remote_path:
        sftp_root = getattr(site, "sftp_root", "")
        remote_path = sftp_root if sftp_root else "."

    files = []
    error = None

    try:
        with SSHService(site) as conn:
            # Normalise to an absolute path so the template can build
            # correct links for child directories and the parent.
            remote_path = conn.sftp_normalize(remote_path)
            files = conn.sftp_list(remote_path)
    except Exception as exc:
        error = str(exc)

    # Compute parent directory (None when at filesystem root).
    if remote_path in (".", "", "/"):
        parent = None
    else:
        parent = os.path.dirname(remote_path)
        if not parent:
            parent = "/"

    return render_template(
        "sftp.html",
        site=site,
        files=files,
        current_path=remote_path,
        parent=parent,
        error=error,
    )


# ── SFTP download ────────────────────────────────────────────────────────────


@connections_bp.route("/sites/<site_id>/sftp/download")
def sftp_download(site_id: str):
    """Download a single remote file."""
    site = _storage().get_site(site_id)
    if not site:
        flash("Site not found.", "danger")
        return redirect(url_for("sites.index"))

    remote_path = request.args.get("path", "")
    if not remote_path:
        flash("No file path specified.", "danger")
        return redirect(url_for("connections.sftp", site_id=site_id))

    try:
        filename = os.path.basename(remote_path)
        tmp = tempfile.NamedTemporaryFile(delete=False, suffix=f"_{filename}")
        tmp.close()

        with SSHService(site) as conn:
            conn.sftp_download(remote_path, tmp.name)

        return send_file(tmp.name, as_attachment=True, download_name=filename)
    except Exception as exc:
        flash(f"Download failed: {exc}", "danger")
        return redirect(url_for("connections.sftp", site_id=site_id))


# ── SFTP upload ──────────────────────────────────────────────────────────────


@connections_bp.route("/sites/<site_id>/sftp/upload", methods=["POST"])
def sftp_upload(site_id: str):
    """Upload a file to the remote *remote_dir*."""
    site = _storage().get_site(site_id)
    if not site:
        flash("Site not found.", "danger")
        return redirect(url_for("sites.index"))

    remote_dir = request.form.get("remote_dir", ".")
    uploaded = request.files.get("file")

    if not uploaded or not uploaded.filename:
        flash("No file selected.", "danger")
        return redirect(
            url_for("connections.sftp", site_id=site_id, path=remote_dir),
        )

    try:
        tmp = tempfile.NamedTemporaryFile(delete=False)
        uploaded.save(tmp.name)
        tmp.close()

        remote_path = f"{remote_dir}/{uploaded.filename}".replace("//", "/")

        with SSHService(site) as conn:
            conn.sftp_upload(tmp.name, remote_path)

        os.unlink(tmp.name)
        flash(f"Uploaded '{uploaded.filename}' successfully.", "success")
    except Exception as exc:
        flash(f"Upload failed: {exc}", "danger")

    return redirect(
        url_for("connections.sftp", site_id=site_id, path=remote_dir),
    )
