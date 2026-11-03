# App Management - tmux Edition

A Bash-based app manager for Linux using **tmux** as the terminal multiplexer.

## Why tmux over Zellij?

**tmux** provides full programmatic control that Zellij lacks:
- ✅ **Kill specific windows/panes by name** - `tmux kill-window -t session:window`
- ✅ **Send keys to panes** - Stop apps gracefully with Ctrl+C
- ✅ **Query running windows** - List all windows and their status
- ✅ **Session management** - Attach/detach sessions reliably
- ✅ **Mature and stable** - 15+ years of development

Zellij doesn't support programmatically stopping/killing specific panes by name, which breaks stop/restart functionality.

## Features

- **Start apps** - Launch Python apps (Streamlit, Django, Flask, Dash, or Custom with its own start command) in tmux windows
- **Stop apps** - Kill apps by terminating their tmux window or sending Ctrl+C
- **Restart apps** - Stop and start apps in the same window
- **Add/Edit/Delete apps** - Manage your apps.json configuration
- **Port detection** - Check which apps are running
- **Auto-detection** - Detect app type and package manager
- **Dashboard generation** - Generate HTML dashboard with app links

## Requirements

- Bash 4.0+
- tmux 2.0+
- jq (JSON processor)
- Python 3.8+ (for running apps)
- Optional: uv or pip

### Install Dependencies

```bash
# Ubuntu/Debian
sudo apt install tmux jq

# Fedora/RHEL
sudo dnf install tmux jq

# Arch
sudo pacman -S tmux jq

# macOS
brew install tmux jq
```

## Usage

### Interactive Mode
```bash
./manager.sh
```

### Command Line
```bash
# Start a specific app
./manager.sh --app "My App"

# Start all apps
./manager.sh --all

# Dry run (show what would be executed)
./manager.sh --dry-run --all

# Attach to the tmux session
./manager.sh --attach
```

### Inside the Interactive Menu
```
Commands:
Dashboard:
  D             - Toggle dashboard (start/stop)
Manage apps:
  [number(s)]   - Start app(s) by index (e.g., 1,2,3) (0 for all)
  [name]        - Start app by name
  s [num]       - Stop app by index (0 for all)
  r [num]       - Restart app by index (0 for all)
  u [num]       - Update app from repo (0 for all)
Edit apps.json:
  aa            - Add a new app
  ap            - Add a new process (custom command)
  e [num]       - Edit app by index
  d [num]       - Delete app by index
Tmux:
  l             - List tmux windows (running apps)
  t             - Attach to tmux session
  t [num]       - Attach and switch to app window
Other:
  R             - Refresh list
  q             - Quit
```

## Configuration

Apps are defined in `apps.json`. Copy from `apps_example.json` to get started:

```bash
cp apps_example.json apps.json
```

### App Configuration

```json
{
    "Name": "My App",
    "Type": "Streamlit",
    "Port": 8501,
    "AppPath": "/path/to/app",
    "IndexPath": "app.py",
    "VenvPath": "/path/to/venv",
    "PackageManager": "uv"
}
```

**Supported Types**: `Streamlit`, `Django`, `Flask`, `Dash`, `Custom`

**Package Managers**: `uv` (auto-detected from pyproject.toml) or `pip`

### Custom apps (any start command)

For a web app the built-in types cannot start (FastAPI/uvicorn, gunicorn, a project's own launcher), use
`"Type": "Custom"` with a `CustomCommand` and a `Port`. It gets the same port check, dashboard card and `NginxPath`
handling as the other types. Add one with `aa` (pick 5 Custom; FastAPI/uvicorn/gunicorn projects are detected as Custom).

```json
{
    "Name": "My API",
    "Type": "Custom",
    "Port": 8000,
    "AppPath": "/path/to/repo",
    "PackageManager": "uv",
    "CustomCommand": "TZ=Europe/London uvicorn app.main:app --host 0.0.0.0 --port {port}"
}
```

`CustomCommand` rules (Custom apps and processes):
- Runs in `AppPath`. With `uv`, `uv run ` is put in front unless the command starts with `uv` or `uvx`
  (e.g. `uv run --directory backend python -m serve`); with `pip`, the venv is activated first.
- `{port}` is replaced by `Port`, so the port is set in one place.
- Leading `VAR=value` settings (e.g. `TZ=Europe/London`, quoted values allowed) are exported before the command,
  so they work together with the `uv run` prefix.
- Without a Type, a command that does not look like a full command (no `python`/`uv`/`bash`/`./`/path) is run as a
  Django management command (`python manage.py <command>`).

### Processes (no port)

Background jobs such as schedulers: `ap`, or an entry with `CustomCommand` and no `Type`/`Port`.

## Session Structure

All apps run in a single tmux session named `app_manager`:
- Each app gets its own named window
- Windows can be attached to see output
- Windows persist until explicitly closed

```bash
# List all windows
tmux list-windows -t app_manager

# Attach to session
tmux attach -t app_manager

# Detach: Press Ctrl+B, then D
```

## Files

```
app_management_tmux/
├── manager.sh          # Main manager script
├── start.sh            # Quick start helper
├── apps.json           # Your app configurations
├── apps_example.json   # Example configuration
├── README.md           # This file
└── lib/
    ├── config.sh       # Configuration helpers
    ├── app_helpers.sh  # App management functions
    ├── tmux_helpers.sh # tmux-specific functions
    ├── json_helpers.sh # JSON manipulation
    └── url_helpers.sh  # URL/network detection
```
