# Connector

Multi-protocol session manager with encrypted credential storage and native terminal integration. Available as a **cross-platform web UI** (Python/Flask) and a **native macOS app** (Swift/SwiftUI).

Connector lets you organise remote sessions into folders, store credentials securely (encrypted at rest), and launch connections directly in your platform's native terminal. Supports SSH2, SSH1, Local Shell, Raw TCP, Telnet, and Serial protocols. SSH sessions also include an SFTP file manager.

| | Web UI (Python) | Native macOS (Swift) |
|---|---|---|
| **Platforms** | macOS, Linux, Windows | macOS 14.0+ (Sonoma) |
| **Encryption** | Fernet (AES-128-CBC) | AES-256-GCM (CryptoKit) |
| **SFTP** | Paramiko (in-process) | ssh/scp subprocess |
| **Terminal launch** | AppleScript, gnome-terminal, wt | AppleScript (iTerm / Terminal.app) |
| **Data location** | `./data/` | `~/Library/Application Support/Connector/` |

---

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [macOS Native App](#macos-native-app)
  - [Building from Source](#building-from-source)
  - [Packaging and Installing](#packaging-and-installing)
  - [CI Build (GitHub Actions)](#ci-build-github-actions)
  - [macOS App Architecture](#macos-app-architecture)
- [CLI Reference](#cli-reference)
- [Configuration](#configuration)
- [Architecture](#architecture)
  - [Project Layout](#project-layout)
  - [Component Diagram](#component-diagram)
  - [Request Flow](#request-flow)
  - [Encryption Pipeline](#encryption-pipeline)
  - [Template Hierarchy](#template-hierarchy)
- [Web UI Guide](#web-ui-guide)
  - [Dashboard](#dashboard)
  - [Creating a Session](#creating-a-session)
  - [Protocols](#protocols)
  - [Connecting](#connecting)
  - [SFTP File Browser](#sftp-file-browser)
  - [Folders and Organisation](#folders-and-organisation)
  - [Quick Connect](#quick-connect)
  - [Settings](#settings)
  - [Import and Export](#import-and-export)
- [Running in Production](#running-in-production)
- [Development](#development)
  - [Manual Setup](#manual-setup)
  - [Linting and Formatting](#linting-and-formatting)
  - [Running Tests](#running-tests)
- [Environment Variables](#environment-variables)
- [Security Notes](#security-notes)
- [License](#license)

---

## Features

- **Multi-protocol support** -- SSH2, SSH1, Local Shell, Raw TCP, Telnet, and Serial connections from a single interface
- **Encrypted storage** -- all credentials (passwords, key paths) encrypted at rest with Fernet (AES-128-CBC + HMAC)
- **Native terminal launch** -- opens sessions in your OS terminal (Terminal.app, iTerm, GNOME Terminal, Windows Terminal, and more)
- **SFTP file browser** -- browse, upload, and download files through the web UI (SSH sessions)
- **Hierarchical folders** -- group sessions into collapsible, drag-and-drop folders with arbitrary subfolder nesting (path-based hierarchy, e.g. `AWS/Production`)
- **Import / Export** -- export all sessions and folder structure to a portable JSON file (credentials stripped); import merges folders and deduplicates sessions
- **SSH key file browser** -- native OS file dialog (macOS AppleScript, Linux zenity/kdialog) for selecting SSH key files directly from the session form
- **Quick connect** -- one-shot `user@host:port` connections from the top bar
- **Password auto-login** -- uses `sshpass` when available to pass stored SSH passwords automatically
- **Dynamic forms** -- the session form adapts its fields to the selected protocol (hostname/port for network protocols, serial port/baud for serial, nothing for local shell)
- **Dark-themed UI** -- two-panel session manager layout built with Bootstrap 5
- **Zero external database** -- all data lives in encrypted flat files under `data/`

---

## Requirements

- Python 3.9+
- pip
- A modern web browser
- (Optional) `sshpass` for automatic SSH password login

---

## Quick Start

```bash
# Clone the repository
git clone https://github.com/gunnymarc/connector.git
cd connector

# Start Connector (creates venv, installs deps, launches in background)
./connector.sh --start
```

Open <http://127.0.0.1:5101> in your browser. That's it.

To stop:

```bash
./connector.sh --stop
```

---

## macOS Native App

The `macos/` directory contains a native SwiftUI application that mirrors all features of the web UI. It targets macOS 14.0+ (Sonoma) and uses CryptoKit AES-256-GCM for encrypted storage.

### Building from Source

**Prerequisites:** macOS with Xcode 16+ installed.

```bash
# Install xcodegen (one-time)
brew install xcodegen

# Generate the Xcode project and build
cd macos
xcodegen generate
xcodebuild -project Connector.xcodeproj \
  -scheme Connector \
  -configuration Release \
  build
```

Or open in Xcode and press **Cmd+R**:

```bash
cd macos
xcodegen generate
open Connector.xcodeproj
```

### Packaging and Installing

After building, copy the `.app` bundle to `/Applications/`:

```bash
cd macos

# Build release
xcodebuild -project Connector.xcodeproj \
  -scheme Connector \
  -configuration Release \
  -derivedDataPath ./build \
  build

# Install
cp -R build/Build/Products/Release/Connector.app /Applications/

# Launch
open /Applications/Connector.app
```

The app is unsigned (ad-hoc signed). If macOS Gatekeeper blocks it, go to **System Settings > Privacy & Security > Open Anyway**.

### CI Build (GitHub Actions)

A GitHub Actions workflow automatically builds the macOS app and uploads it as a downloadable artifact. This is useful if you develop on Linux or want automated builds.

The workflow (`.github/workflows/build-macos.yml`) triggers on:
- Push to `main` that modifies `macos/**`
- Pull requests targeting `main` that modify `macos/**`
- Manual trigger via the GitHub Actions UI

**To download a build:**
1. Push code to GitHub.
2. Go to the **Actions** tab in the repository.
3. Click the completed workflow run.
4. Download **Connector-macOS** from the Artifacts section.
5. Unzip on a Mac and move `Connector.app` to `/Applications/`.

### macOS App Architecture

```
macos/
├── project.yml                          # xcodegen project spec
├── Connector/
│   ├── ConnectorApp.swift               # @main entry point, service initialisation
│   ├── Connector.entitlements           # Sandbox disabled (subprocess + AppleEvents access)
│   ├── Assets.xcassets/                 # App icon and accent colour
│   │
│   ├── Models/
│   │   ├── Site.swift                   # Site struct (14 fields), ConnectionProtocol, AuthType
│   │   ├── AppSettings.swift            # Settings with defaults (Codable)
│   │   └── ConnectorError.swift         # LocalizedError enum
│   │
│   ├── Services/
│   │   ├── CryptoService.swift          # AES-256-GCM encryption via CryptoKit
│   │   ├── StorageService.swift         # Encrypted JSON site CRUD
│   │   ├── SettingsService.swift        # Encrypted settings read/write
│   │   └── TerminalService.swift        # Terminal detection, AppleScript launch, SSH/SCP
│   │
│   ├── ViewModels/
│   │   ├── SiteStore.swift              # @Observable site/folder CRUD, export/import
│   │   └── SettingsStore.swift          # @Observable settings wrapper
│   │
│   └── Views/
│       ├── ContentView.swift            # NavigationSplitView layout
│       ├── SidebarView.swift            # Folder tree, site list, search, context menus
│       ├── SiteFormView.swift           # Create/edit form (protocol-adaptive fields)
│       ├── SiteDetailView.swift         # Detail display with action buttons
│       ├── SFTPBrowserView.swift        # Remote file browser (upload/download)
│       ├── SettingsView.swift           # Settings form with export/import
│       └── QuickConnectView.swift       # Quick connect sheet (user@host:port)
```

**Key differences from the web UI:**

| Aspect | Web UI | macOS App |
|---|---|---|
| Encryption | Fernet (AES-128-CBC + HMAC) | AES-256-GCM (CryptoKit) |
| SFTP | Paramiko SSH library (in-process) | `ssh`/`scp` subprocess via `Process` |
| UI framework | Flask + Jinja2 + Bootstrap 5 | SwiftUI with `@Observable` |
| Data directory | `./data/` (configurable) | `~/Library/Application Support/Connector/` |
| State management | Flask `app.config` dict | SwiftUI `@Environment` injection |

The encrypted storage formats are **not cross-compatible** between the two versions. Use the JSON export/import feature (which strips credentials) to migrate session metadata between them.

---

## CLI Reference

All lifecycle management goes through `connector.sh`:

```
Usage: ./connector.sh [OPTION]

Options:
  --start        Start Connector in the background
  --stop         Stop the background process
  --status       Check if Connector is running
  --debug        Start in foreground with debug logging (logs to logs/)
  --clear_cache  Remove __pycache__ dirs and connector_venv
  --clear_all    Remove cache + all encrypted data (destructive, prompts for confirmation)
```

### Details

| Flag | What it does |
|---|---|
| `--start` | Creates `connector_venv` if needed, installs dependencies from `requirements.txt`, launches Flask in the background via `nohup`, writes PID to `data/connector.pid`, prints the URL. |
| `--stop` | Sends SIGTERM to the stored PID, waits up to 5 seconds for graceful shutdown, escalates to SIGKILL if needed, removes the PID file. |
| `--status` | Reports whether Connector is running and shows the PID. |
| `--debug` | Starts in the foreground with `FLASK_DEBUG=1`. Logs stdout/stderr to a timestamped file in `logs/`. Refuses to start if a background instance is already running. |
| `--clear_cache` | Recursively deletes all `__pycache__/` directories and the `connector_venv/` virtual environment. Does not touch encrypted data. |
| `--clear_all` | Displays a warning box, prompts for `[y/N]` confirmation, then deletes the venv, `__pycache__`, the encryption key (`.key`), all `.enc` files, and the PID file. **This permanently destroys all stored sessions and settings.** |

---

## Configuration

Copy the example file and edit as needed:

```bash
cp .env.example .env
```

| Variable | Default | Description |
|---|---|---|
| `FLASK_SECRET_KEY` | random (auto-generated) | Flask session signing key |
| `CONNECTOR_DATA_DIR` | `./data` | Directory for encrypted files and the PID file |
| `CONNECTOR_HOST` | `127.0.0.1` | Listen address |
| `CONNECTOR_PORT` | `5101` | Listen port |
| `SSH_TIMEOUT` | `10` | SSH connection timeout in seconds |
| `SSH_COMMAND_TIMEOUT` | `30` | SSH command execution timeout in seconds |

All configuration is centralised in `src/config.py` and read from environment variables with sensible defaults. You never need a `.env` file for local development -- the defaults work out of the box.

---

## Architecture

### Project Layout

```
connector/
├── connector.sh                 # Shell bootstrap (venv, deps, start/stop/debug)
├── requirements.txt             # Python dependencies
├── .env.example                 # Environment variable template
│
├── data/                        # Runtime encrypted storage (git-ignored)
│   ├── .key                     #   Fernet encryption key (auto-generated, chmod 600)
│   ├── sites.enc                #   Encrypted session entries
│   ├── settings.enc             #   Encrypted global settings
│   └── connector.pid            #   Background process PID
│
├── logs/                        # Debug log files (git-ignored)
│
├── src/                         # Python/Flask web UI
│   ├── app.py                   # Flask application factory + context processor
│   ├── config.py                # Centralised configuration from env vars
│   │
│   ├── models/
│   │   └── site.py              # Site dataclass (session definition)
│   │
│   ├── services/
│   │   ├── crypto_service.py    # Fernet encrypt / decrypt + key management
│   │   ├── storage.py           # Site CRUD over encrypted file
│   │   ├── settings_service.py  # Global settings read / write
│   │   ├── ssh_service.py       # Paramiko SSH commands + SFTP operations
│   │   └── terminal_service.py  # Platform detection + native terminal launcher
│   │
│   ├── routes/
│   │   ├── sites.py             # Session CRUD (create / edit / duplicate / delete)
│   │   ├── connections.py       # SSH terminal launch, SFTP browse, quick-connect
│   │   ├── settings.py          # Global settings page
│   │   └── folders.py           # Folder CRUD + drag-and-drop reorder API
│   │
│   ├── templates/
│   │   ├── base.html            # Master layout (topbar + sidebar + working pane)
│   │   ├── index.html           # Dashboard / session detail view
│   │   ├── site_form.html       # Create / edit session form
│   │   ├── ssh.html             # SSH connection details + launch button
│   │   ├── sftp.html            # SFTP file browser (upload / download)
│   │   └── settings.html        # Global settings form
│   │
│   └── static/css/
│       └── style.css            # Dark theme + two-panel layout styles
│
├── macos/                       # Native macOS app (Swift/SwiftUI)
│   ├── project.yml              # xcodegen project spec
│   └── Connector/
│       ├── ConnectorApp.swift   # @main entry point
│       ├── Connector.entitlements
│       ├── Assets.xcassets/
│       ├── Models/              # Site, AppSettings, ConnectorError
│       ├── Services/            # CryptoService, StorageService, SettingsService, TerminalService
│       ├── ViewModels/          # SiteStore, SettingsStore
│       └── Views/               # ContentView, SidebarView, SiteFormView, SiteDetailView,
│                                #   SFTPBrowserView, SettingsView, QuickConnectView
│
├── .github/workflows/
│   └── build-macos.yml          # CI: build macOS app + upload artifact
│
└── tests/
    ├── conftest.py              # Shared fixtures (app, client, crypto, storage)
    ├── test_site.py             # Site model (21 tests)
    ├── test_crypto_service.py   # Encryption layer (11 tests)
    ├── test_storage.py          # Storage CRUD (13 tests)
    ├── test_settings_service.py # Settings service (7 tests)
    ├── test_terminal_service.py # Platform detection + protocol commands (23 tests)
    ├── test_routes.py           # Flask route integration (59 tests)
    └── test_folders.py          # Folder + subfolder management (54 tests)
```

### Component Diagram

```
                        +-----------------------+
                        |     Web Browser       |
                        |  http://127.0.0.1:5101|
                        +-----------+-----------+
                                    |
                                    | HTTP
                                    v
+-----------------------------------------------------------------------+
|                          Flask Application                            |
|                          (src/app.py)                                 |
|                                                                       |
|   +-------------------+  +------------------+  +-------------------+  |
|   |    sites_bp       |  | connections_bp   |  |   settings_bp     |  |
|   | (routes/sites.py) |  | (routes/         |  | (routes/          |  |
|   |                   |  |  connections.py)  |  |  settings.py)     |  |
|   | / (dashboard)     |  |                  |  |                   |  |
|   | /sites/new        |  | /quick-connect   |  | /settings         |  |
|   | /sites/<id>/edit  |  | /sites/<id>/ssh  |  | /settings/export  |  |
|   | /sites/<id>/dup   |  | /sites/<id>/sftp |  | /settings/import  |  |
|   | /sites/<id>/del   |  | /sites/<id>/sftp |  +-------------------+  |
|   | /api/browse-key   |  |  /download|upload|                        |
|   +-------------------+  +------------------+  +-------------------+  |
|                                                |   folders_bp      |  |
|   Context Processor (inject_sidebar)           | (routes/          |  |
|   -> sidebar_sites, sidebar_folders,           |  folders.py)      |  |
|      sidebar_folder_tree, active_site,         |                   |  |
|      platform_info                             | /folders/create   |  |
|                                                | /folders/rename   |  |
|                                                | /folders/delete   |  |
|                                                | /folders/move     |  |
|                                                | /folders/reorder  |  |
|                                                +-------------------+  |
+-----------------------------------------------------------------------+
        |                    |                          |
        v                    v                          v
+---------------+  +------------------+  +-------------------------+
| SiteStorage   |  |  SSHService      |  |  TerminalService        |
| (storage.py)  |  |  (ssh_service.py)|  |  (terminal_service.py)  |
|               |  |                  |  |                         |
| list_sites()  |  | connect()        |  | launch_session()        |
| get_site()    |  | execute()        |  | detect_platform()       |
| create_site() |  | sftp_list()      |  |                         |
| update_site() |  | sftp_download()  |  | macOS: AppleScript      |
| delete_site() |  | sftp_upload()    |  | Linux: gnome-terminal,  |
+-------+-------+  +--------+---------+  |   konsole, xterm, etc.  |
        |                    |            | Windows: wt, cmd        |
        v                    v            +-------------------------+
+---------------+     +------------+                |
| CryptoService |     | Paramiko   |                v
| (crypto_      |     | (SSH lib)  |     +---------------------+
|  service.py)  |     +------------+     | Native Terminal App |
|               |                        | (Terminal.app,      |
| encrypt()     |                        |  iTerm, GNOME       |
| decrypt()     |                        |  Terminal, etc.)    |
+-------+-------+                        +---------------------+
        |
        v
+---------------+
|  data/.key    |  Fernet encryption key (auto-generated)
|  data/*.enc   |  Encrypted JSON data files
+---------------+
```

### Request Flow

```
User clicks "Connect" button
         |
         v
Browser POST /sites/<id>/ssh
         |
         v
connections_bp.ssh()
         |
    +----+----+
    |         |
    v         v
SiteStorage  TerminalService
.get_site()  .launch_session(site)
    |              |
    |         _build_command_for_protocol()
    |              |
    |         +----+----+----+----+----+----+
    |         |    |    |    |    |    |    |
    |         v    v    v    v    v    v    v
    |       ssh2 ssh1 local raw  tel  serial
    |         |    |    |    |    |    |
    |         v    v    v    v    v    v
    |    _launch_macos() / _launch_linux() / _launch_windows()
    |              |
    v              v
Encrypted     Native terminal runs protocol command:
data/.enc       ssh2:   ssh user@host -p port
                ssh1:   ssh -o Protocol=1 user@host
                local:  /bin/bash --login
                raw:    nc host port
                telnet: telnet [-l user] host [port]
                serial: screen /dev/ttyUSB0 9600
```

### Encryption Pipeline

```
Site data (Python dict)
         |
         | json.dumps()
         v
    JSON string
         |
         | CryptoService.encrypt()
         | (Fernet: AES-128-CBC + HMAC-SHA256)
         v
    Base64 token string
         |
         | write to disk
         v
    data/sites.enc (opaque text file)

Reading reverses the flow:
    data/sites.enc  -->  decrypt()  -->  json.loads()  -->  list[Site]
```

The encryption key is stored at `data/.key` with permissions `0600` (owner-only read/write). It is auto-generated on first run using `Fernet.generate_key()`.

### Template Hierarchy

```
base.html
  |
  |-- Topbar (brand + quick-connect form)
  |-- Flash messages
  |-- Sidebar (session tree with folders, toolbar, filter)
  |-- Working pane: {% block working_pane %}
        |
        +-- index.html        Session detail or empty state
        +-- site_form.html    Create / edit form
        +-- ssh.html          Connection info + launch button
        +-- sftp.html         File browser table
        +-- settings.html     Global settings form
```

All templates extend `base.html` and render into the `{% block working_pane %}` block. The sidebar is always visible and is populated by the context processor -- individual routes never need to pass sidebar data.

---

## Web UI Guide

### Dashboard

The main page (`/`) shows a two-panel layout:

- **Left sidebar** -- lists all sessions with protocol-specific icons, organised into collapsible folders. Includes a filter input to search by name and a toolbar with Add, Edit, Duplicate, and Delete buttons.
- **Right panel** -- shows details for the selected session (protocol, hostname, port, username, auth type, notes) with action buttons for Connect, SFTP (SSH only), and Edit.

Click any session in the sidebar to select it. The URL updates to `/?site=<id>`.

### Creating a Session

1. Click the **+** button in the sidebar toolbar, or navigate to `/sites/new`.
2. Select a **Protocol** from the dropdown. The form dynamically shows/hides fields based on the selected protocol.
3. Fill in the visible fields:

   | Protocol | Fields shown |
   |---|---|
   | **SSH2** (default) | Hostname, Port, Username, Auth (Password / SSH Key), Notes, Folder |
   | **SSH1** | Same as SSH2 |
   | **Local Shell** | Notes, Folder (no network or auth fields) |
   | **Raw** | Hostname, Port, Notes, Folder |
   | **Telnet** | Hostname, Port, Username, Notes, Folder |
   | **Serial** | Serial Port (e.g. `/dev/ttyUSB0`), Baud Rate, Notes, Folder |

4. For SSH sessions with **SSH Key** auth, click the **Browse** button to open a native OS file dialog (starts in `~/.ssh`). On macOS this uses AppleScript; on Linux it uses zenity or kdialog.
5. Click **Create**.

To edit an existing session, select it and click the pencil icon, or navigate to `/sites/<id>/edit`.

To duplicate, select a session and click the copy icon. The duplicate inherits all fields (including protocol, folder, serial settings) with " (Copy)" appended to the name.

### Protocols

Connector supports six connection protocols:

| Protocol | Description | Terminal command |
|---|---|---|
| **SSH2** | SSH version 2 (default) | `ssh user@host -p port` |
| **SSH1** | SSH version 1 (legacy) | `ssh -o Protocol=1 user@host` |
| **Local Shell** | Opens a local terminal session | `bash --login` (or your `$SHELL`) |
| **Raw** | Raw TCP connection | `nc hostname port` |
| **Telnet** | Telnet connection | `telnet [-l user] hostname [port]` |
| **Serial** | Serial port connection | `screen /dev/ttyUSB0 9600` |

The sidebar uses distinct icons for each protocol type for quick identification.

### Connecting

1. Select a session and click the **Connect** button (or navigate to `/sites/<id>/ssh`).
2. The connection details page shows protocol-specific information and the detected terminal.
3. Click the launch button to open the session.

The button label adapts to the protocol: "Open SSH", "Open Shell", "Open Telnet", "Open Serial", or "Open Connection".

Connector opens your platform's native terminal application:

| Platform | Terminals detected (in preference order) |
|---|---|
| macOS | iTerm, Terminal.app |
| Linux | GNOME Terminal, Konsole, Xfce Terminal, MATE Terminal, LXTerminal, Tilix, Alacritty, xterm |
| Windows | Windows Terminal, Command Prompt |

**Password auto-login (SSH only):** If the session has a stored password and `sshpass` is installed on your system, the password is passed automatically via the `SSHPASS` environment variable. Otherwise, the terminal will prompt you interactively.

To install `sshpass`:

```bash
# macOS
brew install esolitos/ipa/sshpass

# Debian / Ubuntu
sudo apt install sshpass
```

### SFTP File Browser

SFTP is available for **SSH sessions only** (SSH1 and SSH2).

1. Select an SSH session and click **SFTP** (or navigate to `/sites/<id>/sftp`).
2. The browser shows the remote directory listing with file names, sizes, and modification dates.
3. Click a directory name to navigate into it. Click `..` to go up.
4. Click the download icon next to any file to download it.
5. Use the upload form at the top to upload a file to the current directory.

SFTP connections use Paramiko and require valid credentials (password or key) stored in the session.

### Folders and Organisation

**Create a folder:**
- Click the "New Folder" button at the bottom of the sidebar, or use the `/folders/create` API.

**Create subfolders:**
- Hover over a folder header and click the subfolder icon to create a nested folder.
- Alternatively, create a folder with a path like `AWS/Production` -- intermediate parents are auto-created.
- Subfolders can be nested to arbitrary depth.

**Rename or delete a folder:**
- Hover over a folder header in the sidebar to reveal the rename and delete action buttons.
- Renaming a parent folder cascades to all descendant subfolder paths and updates assigned sessions.
- Deleting a folder removes all its descendant subfolders and moves their sessions back to the root level.

**Move sessions into folders:**
- Drag a session and drop it onto a folder header. The sidebar updates immediately.
- Drag a session to the root "Sessions" area to remove it from a folder.

**Reorder folders:**
- Drag a folder header by its grip handle and drop it above or below another folder.

### Quick Connect

The top bar contains a quick-connect input field. Enter a connection string in the format:

```
user@hostname:port
```

Examples:
- `admin@192.168.1.100` (defaults to port 22)
- `root@myserver.com:2222`

Press Enter or click the connect button. Connector opens a one-shot SSH session in your native terminal without saving it.

### Settings

Navigate to `/settings` (or click the gear icon in the sidebar toolbar) to configure:

- **Connection Defaults** -- default SSH port, username, auth type, and key path applied when creating new sessions
- **Timeouts** -- SSH connection timeout (1-300s) and command execution timeout (1-600s)
- **Platform Info** (read-only) -- detected OS, terminal application, and `sshpass` status

### Import and Export

The Settings page includes an Import/Export section for migrating sessions between Connector instances.

**Exporting:**
1. Navigate to `/settings` and click the **Export** button.
2. A JSON file downloads with the naming pattern `connector_export_YYYYMMDD_HHMMSS.json`.
3. The export includes all sessions and folder structure. **Credentials (passwords and key paths) are stripped** for security.

**Importing:**
1. On the Settings page, use the file upload field in the Import section and click **Import**.
2. Connector validates the file format (must contain `connector_export: true`).
3. Folders are merged (no duplicates created). Sessions are deduplicated by `(name, hostname, protocol)` -- existing matches are skipped.
4. Imported sessions receive fresh UUIDs and have credentials blanked. A summary message reports how many sessions and folders were added.

---

## Running in Production

For production deployments, use Gunicorn instead of the built-in Flask server:

```bash
# Activate the virtual environment
source connector_venv/bin/activate

# Run with Gunicorn
gunicorn "src.app:create_app()" --bind 127.0.0.1:5101

# Or with multiple workers
gunicorn "src.app:create_app()" --bind 127.0.0.1:5101 --workers 4
```

Set `FLASK_SECRET_KEY` to a stable value in `.env` so sessions persist across restarts:

```bash
python -c "import secrets; print(secrets.token_hex(32))"
```

---

## Development

### Manual Setup

```bash
# Create and activate virtual environment
python3 -m venv connector_venv
source connector_venv/bin/activate

# Install dependencies
pip install -r requirements.txt

# Run the application
python -m src.app
```

### Linting and Formatting

```bash
# Lint with ruff
ruff check .
ruff check --fix .

# Format with ruff
ruff format .
ruff format --check .    # Check only (for CI)

# Type-check with mypy
mypy src/
```

### Running Tests

The test suite contains 188 tests across 7 test files:

```bash
# Run the full suite
pytest

# Verbose output
pytest -v

# Run a single test file
pytest tests/test_storage.py

# Run tests matching a pattern
pytest -k "test_create_site"

# With coverage report
pytest --cov=src --cov-report=term-missing
```

| Test File | Tests | Coverage |
|---|---|---|
| `test_site.py` | 21 | Site dataclass (creation, serialisation, round-trips, masking, protocol fields/properties) |
| `test_crypto_service.py` | 11 | Key generation, permissions, encrypt/decrypt, error handling |
| `test_storage.py` | 13 | CRUD operations over encrypted storage |
| `test_settings_service.py` | 7 | Settings defaults, overrides, persistence |
| `test_terminal_service.py` | 23 | Platform detection, SSH command building, sshpass, protocol command builders |
| `test_routes.py` | 59 | Flask route integration (CRUD, protocols, export/import, SSH key browse) |
| `test_folders.py` | 54 | Folder CRUD, subfolders, drag-and-drop move/reorder, sidebar rendering |

---

## Environment Variables

All variables are optional. Defaults work for local development.

| Variable | Default | Description |
|---|---|---|
| `FLASK_SECRET_KEY` | Auto-generated random hex | Flask session signing key. Set to a fixed value in production. |
| `CONNECTOR_DATA_DIR` | `./data` | Directory for encryption key and encrypted data files. |
| `CONNECTOR_HOST` | `127.0.0.1` | Address the web server binds to. |
| `CONNECTOR_PORT` | `5101` | Port the web server listens on. |
| `SSH_TIMEOUT` | `10` | SSH connection timeout in seconds. |
| `SSH_COMMAND_TIMEOUT` | `30` | SSH command execution timeout in seconds. |

---

## Security Notes

- **Encryption at rest** -- all session data (including passwords) is encrypted at rest. The web UI uses Fernet (AES-128-CBC + HMAC-SHA256); the macOS app uses AES-256-GCM via CryptoKit. Key files are created with `0600` permissions.
- **No plaintext credentials** -- passwords are never written to disk in plaintext. The `.enc` files are opaque ciphertext.
- **Local-only by default** -- the web server binds to `127.0.0.1`, not `0.0.0.0`. It is not exposed to the network unless you change `CONNECTOR_HOST`. The macOS app has no network listener.
- **Git-ignored secrets** -- `.env`, `data/.key`, `data/*.enc`, `data/*.pid`, and `Connector.xcodeproj/` are all in `.gitignore`.
- **sshpass security** -- when `sshpass` is used, the password is passed via the `SSHPASS` environment variable (not command-line arguments), which avoids exposure in process listings.
- **No external database** -- there is no database server to secure. All state is in encrypted flat files.
- **Export/import safety** -- JSON exports always strip credentials (passwords and key paths). Imported sessions have credentials blanked and receive fresh UUIDs.
- **Not cross-compatible** -- the web UI and macOS app use different encryption schemes. Their encrypted files cannot be read by the other version. Use JSON export/import to transfer session metadata between them.

> **Warning:** The encryption key (`data/.key` for the web UI, `~/Library/Application Support/Connector/.key` for the macOS app) is the master secret. If it is lost, all encrypted data becomes unrecoverable. If it is compromised, all stored credentials are exposed. Back it up securely and restrict file-system access.

---

## License

See [LICENSE](LICENSE) for details.
