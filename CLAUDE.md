# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

A more detailed agent reference exists at `AGENTS.md` (git-ignored, local only). When in doubt, check it for code-style conventions and architecture details.

## Repository Shape

This repo contains **two parallel implementations** of the same product (a multi-protocol session manager with encrypted credential storage):

1. **`py_flask/`** — Python 3.10+ / Flask 3.1 web UI (cross-platform). Uses **Fernet (AES-128-CBC)** for storage, **Paramiko** for SSH/SFTP.
2. **`macos/`** — Native Swift/SwiftUI app (macOS 14+). Uses **AES-256-GCM (CryptoKit)**, `ssh`/`scp` subprocesses for SFTP, AppleScript for terminal launch.

The two encrypted-storage formats are **not cross-compatible**. JSON export/import (credentials stripped) is the only migration path between them. Treat the two implementations as independent — changes to one rarely apply to the other.

## Common Commands

### Python / Flask (`py_flask/`)

```bash
./connector.sh --start       # venv + deps + background launch (writes PID to data/)
./connector.sh --stop        # SIGTERM, SIGKILL after 5s
./connector.sh --debug       # Foreground, FLASK_DEBUG=1, logs/<timestamp>.log
./connector.sh --clear_all   # DESTRUCTIVE: deletes venv, cache, .key, *.enc, PID

# Tests (pytest is in requirements.txt; ruff/mypy/pytest-cov are NOT)
pytest                                                       # Full suite
pytest tests/test_storage.py                                 # Single file
pytest tests/test_routes.py::TestSFTPRoute::test_sftp_page   # Single test
pytest -k "test_create_site"                                 # By name pattern
```

**No Python CI exists.** Run `pytest` locally before pushing.

### macOS Swift (`macos/`)

All operations go through `macos/build.sh`:

```bash
cd macos
./build.sh --build      # Debug build
./build.sh --release    # Release build
./build.sh --test       # Full Swift test suite
./build.sh --run        # Build + launch
./build.sh --generate   # Regenerate .xcodeproj from project.yml (needs xcodegen)
```

CI (`.github/workflows/build-macos.yml`) builds and tests on `macos-15` for any push/PR touching `macos/**`.

## Python Architecture (the parts that aren't obvious from file structure)

- **App factory pattern.** `create_app()` in `py_flask/app.py` is the entry point. It wires services into `app.config` (`STORAGE`, `SETTINGS`, `TERMINAL`, `PLATFORM_INFO`) and registers blueprints (`sites_bp`, `connections_bp`, `settings_bp`, `folders_bp`) **without URL prefixes** — full paths live in route decorators.
- **Sidebar data is injected globally.** The `inject_sidebar` context processor injects `sidebar_sites`, `sidebar_root_sites`, `sidebar_folders`, `sidebar_folder_tree`, `active_site`, `platform_info` into every template. **Route handlers must not pass sidebar data themselves.**
- **Service access pattern.** Routes access services via private helpers like `def _storage() -> SiteStorage: return current_app.config["STORAGE"]`. Follow this when adding new routes — don't reach into `current_app.config` directly throughout a handler.
- **`Config` is a namespace, not an instance.** `py_flask/config.py`'s `Config` class is class-level attributes only, never instantiated. Tests patch with `monkeypatch.setattr("py_flask.config.Config.ATTR", value)`. **Never use `os.getenv` directly in routes/services** — go through `Config`.
- **SSH must use the context manager.** Always `with SSHService(site) as conn:` — `__enter__` connects, `__exit__` disconnects. Don't call `connect()`/`disconnect()` manually.
- **Encrypted storage layout.** Fernet key at `data/.key` (chmod 600); JSON-then-encrypted blobs at `data/sites.enc`, `data/settings.enc`. The `crypto_service` and `storage`/`settings_service` layers are split: storage modules call into crypto, never the other way.
- **Folder routes return both JSON and HTML.** They check `request.is_json` and either `jsonify(...)` or `flash(...) + redirect(...)`. Preserve this dual-response when editing folder routes.
- **Settings export/import.** Export strips credentials via `_CREDENTIAL_FIELDS`. Import deduplicates by `(name, host, protocol)` and assigns fresh UUIDs.

## Test Conventions

- Fixtures in `tests/conftest.py`: `tmp_data_dir`, `crypto`, `storage`, `settings_svc` (temp-dir-backed), `sample_site` / `sample_site_key`, `app` / `client` (Flask test app with monkeypatched `Config`).
- Tests are organized into `Test<Feature>` classes. Every test method has type annotations and a docstring.
- Module-level `_helper()` functions (not fixtures) handle repeated setup like `_create_test_site()`.

## Code Style (highlights)

- `from __future__ import annotations` is **required** at the top of every Python module.
- Imports: stdlib → third-party → project-local, blank-line-separated, alphabetical within groups.
- Double quotes everywhere. 88-char lines. Trailing commas in multi-line collections.
- Section dividers use Unicode box-drawing: `# ── Section Name ──────`.
- `X | None`, never `Optional[X]`. Avoid bare `dict` — prefer dataclasses or `TypedDict`.
- Type-annotate everything — including tests. **Exception:** Flask route handlers omit return type annotations.
- Comments explain *why*, not *what*. TODO format: `# TODO(#issue): description`.

## Secrets & Files Never to Commit

- `.env`, `data/.key`, `data/*.enc`, `data/*.pid`, `data/*.pem`, `logs/`
- `connector_venv/`, `__pycache__/`
- `AGENTS.md` is git-ignored — it exists locally only. `tests/` **is** tracked.

## Git

Conventional commits: `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:`. Atomic — one logical change per commit.
