#!/usr/bin/env bash
# connector.sh — Manage the Connector application.
#
# Usage:
#   ./connector.sh --start        Start the app in the background
#   ./connector.sh --stop         Stop the background app
#   ./connector.sh --status       Show whether the app is running
#   ./connector.sh --debug        Start in foreground with debug logging to logs/
#   ./connector.sh --clear_cache  Remove __pycache__ dirs and the connector_venv
#   ./connector.sh --clear_all    Remove cache + all encrypted data (destructive)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

VENV_DIR="connector_venv"
DATA_DIR="data"
LOG_DIR="logs"
PID_FILE="$DATA_DIR/connector.pid"

# ── Helpers ────────────────────────────────────────────────────────────────────

setup_venv() {
    if [ ! -d "$VENV_DIR" ]; then
        echo "Creating virtual environment '$VENV_DIR'..."
        python3 -m venv "$VENV_DIR"
    fi

    # shellcheck disable=SC1091
    source "$VENV_DIR/bin/activate"

    echo "Installing dependencies..."
    pip install -q -r requirements.txt
}

load_env() {
    mkdir -p "$DATA_DIR"

    if [ -f .env ]; then
        set -a
        # shellcheck disable=SC1091
        source .env
        set +a
    fi
}

get_host_port() {
    HOST="${CONNECTOR_HOST:-127.0.0.1}"
    PORT="${CONNECTOR_PORT:-5101}"
}

is_running() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        # Stale PID file — clean up
        rm -f "$PID_FILE"
    fi
    return 1
}

# ── Commands ───────────────────────────────────────────────────────────────────

do_start() {
    if is_running; then
        echo "Connector is already running (PID $(cat "$PID_FILE"))."
        exit 0
    fi

    setup_venv
    load_env
    get_host_port

    echo "──────────────────────────────────────────"
    echo "  Connector starting on http://$HOST:$PORT"
    echo "──────────────────────────────────────────"

    nohup python -m src.app > /dev/null 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"

    echo "Connector started in background (PID $pid)."
}

do_stop() {
    if ! is_running; then
        echo "Connector is not running."
        exit 0
    fi

    local pid
    pid=$(cat "$PID_FILE")
    echo "Stopping Connector (PID $pid)..."
    kill "$pid" 2>/dev/null || true

    # Wait up to 5 seconds for graceful shutdown
    local waited=0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 5 ]; do
        sleep 1
        waited=$((waited + 1))
    done

    # Force kill if still alive
    if kill -0 "$pid" 2>/dev/null; then
        echo "Forcing shutdown..."
        kill -9 "$pid" 2>/dev/null || true
    fi

    rm -f "$PID_FILE"
    echo "Connector stopped."
}

do_status() {
    if is_running; then
        local pid
        pid=$(cat "$PID_FILE")
        echo "Connector is running (PID $pid)."
    else
        echo "Connector is not running."
    fi
}

do_debug() {
    if is_running; then
        echo "Connector is already running (PID $(cat "$PID_FILE"))."
        echo "Stop it first with: ./connector.sh --stop"
        exit 1
    fi

    setup_venv
    load_env
    get_host_port
    mkdir -p "$LOG_DIR"

    local log_file="$LOG_DIR/connector_$(date +%Y%m%d_%H%M%S).log"

    echo "──────────────────────────────────────────"
    echo "  Connector DEBUG on http://$HOST:$PORT"
    echo "  Logging to: $log_file"
    echo "  Press Ctrl+C to stop"
    echo "──────────────────────────────────────────"

    FLASK_DEBUG=1 python -m src.app 2>&1 | tee "$log_file"
}

do_clear_cache() {
    echo "Clearing __pycache__ directories..."
    find "$SCRIPT_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

    if [ -d "$VENV_DIR" ]; then
        echo "Removing virtual environment '$VENV_DIR'..."
        rm -rf "$VENV_DIR"
    else
        echo "No virtual environment found."
    fi

    echo ""
    echo "Cache cleared.  Run './connector.sh --start' to rebuild."
}

do_clear_all() {
    echo "┌──────────────────────────────────────────────────────┐"
    echo "│  WARNING: --clear_all will permanently remove:       │"
    echo "│                                                      │"
    echo "│    - All __pycache__ directories                     │"
    echo "│    - The virtual environment ($VENV_DIR)        │"
    echo "│    - All encrypted data files (sites, settings)      │"
    echo "│    - The encryption key (data/.key)                  │"
    echo "│                                                      │"
    echo "│  ALL SAVED SESSIONS AND ENCRYPTED PASSWORDS WILL BE  │"
    echo "│  PERMANENTLY DELETED.  This action cannot be undone. │"
    echo "└──────────────────────────────────────────────────────┘"
    echo ""
    printf "Are you sure you want to proceed? [y/N]: "
    read -r confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "Aborted."
        exit 0
    fi

    echo ""

    # Reuse cache cleanup (pycache + venv)
    echo "Clearing __pycache__ directories..."
    find "$SCRIPT_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

    if [ -d "$VENV_DIR" ]; then
        echo "Removing virtual environment '$VENV_DIR'..."
        rm -rf "$VENV_DIR"
    fi

    # Remove encrypted data and the encryption key
    if [ -d "$DATA_DIR" ]; then
        echo "Removing encrypted data files..."
        rm -f "$DATA_DIR"/*.enc
        rm -f "$DATA_DIR"/.key
        rm -f "$DATA_DIR"/*.pid
    fi

    echo ""
    echo "All data cleared.  Sessions, passwords, and cache have been removed."
}

show_usage() {
    echo "Usage: ./connector.sh <option>"
    echo ""
    echo "Options:"
    echo "  --start        Start the application in the background"
    echo "  --stop         Stop the background application"
    echo "  --status       Show whether the application is running"
    echo "  --debug        Start in foreground with debug logging to logs/"
    echo "  --clear_cache  Remove __pycache__ dirs and the virtual environment"
    echo "  --clear_all    Remove cache + all encrypted data (destructive, prompts)"
    echo ""
}

# ── Main ───────────────────────────────────────────────────────────────────────

if [ $# -eq 0 ]; then
    show_usage
    exit 1
fi

case "$1" in
    --start)       do_start ;;
    --stop)        do_stop ;;
    --status)      do_status ;;
    --debug)       do_debug ;;
    --clear_cache) do_clear_cache ;;
    --clear_all)   do_clear_all ;;
    *)
        echo "Unknown option: $1"
        echo ""
        show_usage
        exit 1
        ;;
esac
