"""Settings routes for global application options."""

from __future__ import annotations

from flask import (
    Blueprint,
    current_app,
    flash,
    redirect,
    render_template,
    request,
    url_for,
)

from src.services.settings_service import SettingsService

settings_bp = Blueprint("settings", __name__)


def _settings() -> SettingsService:
    """Retrieve the shared :class:`SettingsService` from the app config."""
    return current_app.config["SETTINGS"]


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
