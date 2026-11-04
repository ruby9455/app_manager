# app_manager

This repository contains scripts and helper modules to manage, launch, and generate a dashboard for
locally-hosted Python web apps (Streamlit, Django, Dash, Flask, Custom).

| Folder | Platform |
|---|---|
| `app_manager_win` | Windows (PowerShell 7 + Windows Terminal) |
| `app_manager_psmux` | Windows (psmux) |
| `app_manager_tmux` | Linux (tmux) |

The Windows scripts below live in `app_manager_win`; modules are imported relative to the scripts
(no global module installation required).

Top-level scripts
-----------------

- `manager.ps1` (primary manager)
	- Interactive app manager: list/start/stop/restart/update apps declared in `apps.json`.
	- Launches apps in Windows Terminal tabs (preferred) or falls back to new PowerShell windows.
	- Detects package manager (`uv` when `pyproject.toml` exists, otherwise `pip`), finds venvs,
		and supports update hooks (git pull, dependency sync).
	- Key options: `-AppName`, `-DryRun`, `-AutoStart`.

- `landing_page.ps1` (HTML landing page server / generator)
	- Generates `app_index.html` using the `Dashboard` module and serves it over HTTP (default port 1111).
	- Regenerates HTML on each request so the page reflects current app states.

- `start.ps1` (wrapper)
	- Helper to launch the two scripts concurrently in Windows Terminal using `wt` (opens a new tab
		and splits panes). Resolves absolute pwsh/wt paths and verifies the scripts exist.

Helper modules (in `Modules/`)
-----------------------------

- `AppHelpers.psm1`
	- App-list utilities: normalize/dedupe apps, field getters/setters, venv detection, package manager
		detection, fuzzy index-file picker, repo/venv update helpers.

- `TerminalHelpers.psm1`
	- Windows Terminal helpers and window/tab interaction: detect `wt.exe`, create new tabs, and
		best-effort UI automation to send Enter/close a tab when needed.

- `UrlHelpers.psm1`, `NetworkHelpers.psm1`, `Dashboard.psm1`, `ProcessHelpers.psm1`, `LaunchHelpers.psm1`, `ConfigHelpers.psm1`
	- Small focused helpers used across the scripts: URL prefix detection (local/external/generic),
		port/process utilities (check listener, wait for port), HTML dashboard generation, and process helpers.

Key behaviors and requirements
-----------------------------

- PowerShell 7+ is required. Scripts include `#Requires -Version 7.0`.
- Windows Terminal (`wt.exe`) is the preferred frontend. When `wt` is not available the scripts
	attempt to launch apps in separate PowerShell windows.
- Apps.json
	- `apps.json` (in the same folder) is the canonical source of app definitions. An example
		is included as `apps_example.json`.
	- Types: `Streamlit`, `Django`, `Dash`, `Flask`, `Custom`; an entry with only a `CustomCommand` (no Type/Port)
		is a background process (option 6).

Custom apps (any start command)
-------------------------------

For a web app the built-in types cannot start (FastAPI/uvicorn, gunicorn, a project's own launcher), use
`"Type": "Custom"` with a `CustomCommand` and a `Port`. It gets the same port-based stop/restart, idle-tab cleanup and
dashboard card as the other types. Add one with option 5 (type `c`; FastAPI/uvicorn/gunicorn projects are detected as
Custom). The same entry works in `app_manager_tmux` on Linux.

```json
{
    "Name": "My API",
    "Type": "Custom",
    "Port": 8080,
    "AppPath": "C:\\Users\\me\\code\\my_api",
    "PackageManager": "uv",
    "CustomCommand": "uv run --directory web_ui/backend python -m serve --host 0.0.0.0 --port {port}"
}
```

`CustomCommand` rules (Custom apps and processes):
- Runs in `AppPath`. A command starting with `uv`/`uvx` runs as it is; otherwise `uv run ` is put in front with `uv`, and
  with `pip` the venv is activated first.
- `{port}` is replaced by `Port`, so the port is set in one place.
- Leading `VAR=value` settings (e.g. `TZ=Europe/London`, quoted values allowed) become `$env:VAR = 'value'` before
  the command.
- Without a Type, a command that does not look like a full command (no `python`/`uv`/path) is run as a Django management
  command (`python manage.py <command>`).

Machine-specific settings
-------------------------

- `apps.json` is gitignored. Each manager and landing page uses the first of:
  1. `APP_MANAGER_APPS_FILE` (an explicit path)
  2. `~/code/app_manager_config/machines/<hostname>/<platform>/apps.json`, where `<platform>` is `win`, `psmux` or
     `tmux`. Set `APP_MANAGER_CONFIG_DIR` to use another folder.
  3. `apps.json` next to the scripts

  Keeping one folder per machine in a private config repo means every machine can share it without copying files
  around. Real nginx routes belong there too. See `AGENTS.md` for the layout.
- URL fallbacks default to `http://127.0.0.1`. Override them per machine with environment variables:

```powershell
$env:APP_MGMT_NETWORK_URL  = 'http://192.168.1.10'
$env:APP_MGMT_EXTERNAL_URL = 'http://203.0.113.10'
```

How to run
----------

From the repo root, run the manager and landing page.

Run manager interactively:

```powershell
pwsh -File .\app_manager_win\manager.ps1
```

Generate and host the landing page (default port 1111):

```powershell
pwsh -File .\app_manager_win\landing_page.ps1
```

Launch both in Windows Terminal (wrapper):

```powershell
cd .\app_manager_win
.\start.ps1
```

Or use wt directly (example):

```powershell
wt -w 0 new-tab pwsh -NoExit -NoProfile -ExecutionPolicy Bypass -File .\app_manager_win\manager.ps1 ; split-pane -H pwsh -NoExit -NoProfile -ExecutionPolicy Bypass -File .\app_manager_win\landing_page.ps1
```

Tests
-----

There are some lightweight PowerShell tests in `app_manager_win/tests/`. From the repo root:

```powershell
pwsh -File .\app_manager_win\tests\Test-AppHelpers.ps1
pwsh -File .\app_manager_win\tests\Test-LaunchHelpers.ps1
pwsh -File .\app_manager_win\tests\Test-TerminalHelpers.ps1
```

On Linux, the tmux lookup test runs with `bash app_manager_tmux/tests/test_config.sh`.
