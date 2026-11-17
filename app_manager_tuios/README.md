# App Management - tuios Edition

An app manager using [tuios](https://github.com/Gaurav-Gosain/tuios) as the terminal multiplexer. It behaves like
`app_manager_tmux` (same menu, commands, apps.json entries and dashboard), and runs on Linux, macOS and Windows:

| Version | Runs on | Files |
|---|---|---|
| Bash | Linux, macOS | `manager.sh`, `start.sh`, `landing_page.sh`, `lib/` |
| PowerShell 7 | Windows, Linux, macOS | `manager.ps1`, `start.ps1`, `landing_page.ps1`, `Modules/` |

Both use the same `apps.json` and the same tuios session, so either can manage apps the other started.

Every app runs in a named pane of one tuios session (`app_manager`). The tuios daemon keeps the session alive with no
terminal attached; the manager drives it with the tuios CLI (`new-window`, `split-window`, `send-keys`,
`close-window`, ...). Panes are found by name and addressed by their id.

On top of the tmux edition, apps can share a **workspace**: an app and its scheduler open side by side, on a workspace
named after them (see [Workspaces](#workspaces-group-panesideratio-panebeside)).

## Requirements

- tuios on `PATH` (`brew install tuios`, `yay -S tuios-bin`, or a release binary)
- Bash version: Bash 4.0+ (macOS ships 3.2: `brew install bash`) and `jq`
- PowerShell version: PowerShell 7+
- Python 3.8+ for the apps, with `uv` or pip

## Usage

```bash
./manager.sh                     # Interactive menu (+ dashboard on port 1111)
./manager.sh --app "My App"      # Start a specific app
./manager.sh --all               # Start all apps
./manager.sh --dry-run --all     # Show what would run, and where
./manager.sh --attach            # Attach to the tuios session
./manager.sh --no-landing        # Without the dashboard

./start.sh                       # Manager and dashboard side by side in a new tuios session
./start.sh stop | list | attach | all | manager | landing | "My App"
```

```powershell
./manager.ps1                    # Interactive menu (+ dashboard on port 1111)
./manager.ps1 -AppName 'My App'
./manager.ps1 -All
./manager.ps1 -DryRun -All
./manager.ps1 -Attach
./manager.ps1 -NoLanding

./start.ps1                      # Manager and dashboard side by side in a new tuios session
./start.ps1 stop | list | attach | all | manager | landing | 'My App'
```

The interactive commands are those of the tmux edition: start by number(s) or name (`0` for all), `s`/`r`/`u` stop,
restart and update, `aa`/`ap` add an app or a process, `e`/`d` edit or delete, `D` toggles the dashboard, `l` lists
the panes, `t` attaches (`t 3` shows app 3's pane), `R` refreshes and `q` quits. The table has a `WS` column: the
workspace of each running app.

Attach with `t`, detach with the tuios prefix key then `d` (`Ctrl+B`, `d` by default). From inside a tuios pane, `t`
switches the client to the session instead (tuios does not nest a client in its own pane).

## Configuration

`apps.json` is found as in the other editions (see `AGENTS.md`): `$APP_MANAGER_APPS_FILE`, else
`~/code/app_manager_config/machines/<hostname>/tuios/apps.json`, else `apps.json` next to the scripts. Entries are the
same as in the tmux edition (`apps_example.json`, and the "Custom apps" section of the root `README.md`).

| Variable | Default | Use |
|---|---|---|
| `APP_MANAGER_TUIOS_SESSION` | `app_manager` | tuios session for the apps |
| `APP_MANAGER_TUIOS_BIN` | `tuios` | tuios executable |
| `APP_MGMT_NETWORK_URL`, `APP_MGMT_EXTERNAL_URL` | detected | dashboard URL fallbacks |

In the PowerShell version, run commands are PowerShell: leading `VAR=value` settings in a `CustomCommand` become
`$env:VAR = 'value'`, and a pip venv is activated with its `Activate.ps1`.

## Workspaces: Group, PaneSide, PaneRatio, PaneBeside

Four optional fields on an entry. The other editions ignore them, and keep them when they edit an entry.

| Field | Values | Meaning |
|---|---|---|
| `Group` | any name | Entries with the same Group open together on one workspace, labelled with the name |
| `PaneSide` | `left`, `right`, `up`, `down` | Where the pane goes beside the group's app. Leave it out on the app itself |
| `PaneRatio` | 1-99 | Share of the pane it splits, in percent (default: half) |
| `PaneBeside` | an entry's Name | Split that pane of the group instead of the app (e.g. for 2x2) |

How a pane is placed when it starts:

- **No Group**: workspace 1, with the dashboard.
- **First pane of its group to start**: the lowest empty workspace from 2 to 9, labelled with the Group. A group that
  is not running takes no workspace, so there are no blank workspaces for stopped apps, and only the groups running at
  once count against tuios's 9 workspaces. When all of 2-9 are in use, it opens on workspace 1.
- **The group already has a pane running**: it splits the pane `PaneBeside` names, else the group's app (the member
  with a Port), on its `PaneSide`, taking `PaneRatio`. A second pane with the same `PaneSide` splits the first one
  across instead (down/up then right), so the app keeps its share: an app with three `down` schedulers gets the
  schedulers side by side under it. Started the other way round (the app restarting while its scheduler runs), the
  app goes on the opposite side and takes the rest, so the layout comes out the same.
- **The last pane of a group stops**: its workspace label is cleared.

An app with its scheduler below it, at 30%:

```json
{ "Name": "My App", "Type": "Django", "Port": 8000, "AppPath": "/home/user/my_app", "Group": "My App" },
{ "Name": "My App Scheduler", "AppPath": "/home/user/my_app", "CustomCommand": "cache_scheduler",
  "Group": "My App", "PaneSide": "down", "PaneRatio": 30 }
```

2x2: the app top left, then A right of it, B below it, and C below A:

```json
{ "Name": "My App", "Type": "Streamlit", "Port": 8501, "AppPath": "/home/user/my_app", "IndexPath": "app.py", "Group": "My App" },
{ "Name": "A", "AppPath": "/home/user/my_app", "CustomCommand": "python -m a", "Group": "My App", "PaneSide": "right" },
{ "Name": "B", "AppPath": "/home/user/my_app", "CustomCommand": "python -m b", "Group": "My App", "PaneSide": "down" },
{ "Name": "C", "AppPath": "/home/user/my_app", "CustomCommand": "python -m c", "Group": "My App", "PaneSide": "down",
  "PaneBeside": "A" }
```

Panes are placed as they start, so a layout depends on what is running: start the whole group (e.g. `3,4,5,6`) to get
it as configured. `aa`, `ap` and `e` ask for the fields (an empty answer keeps the value shown, `-` clears it). `ap`
puts a new process in the group of the app in the same folder, below it at 30%, and offers to add that app to the group.

tuios notes behind these rules: a session made headless (`tuios new --detach`) floats its panes and refuses
`move-window --beside`, so panes are placed with `split-window`, which tiles them. The session's first window stays
(as `_placeholder`) until something opens on workspace 1; closing it while it is alone there makes tuios pull the
other panes onto workspace 1.

## Tests

```bash
bash tests/test_config.sh          # apps.json lookup
bash tests/test_tuios_helpers.sh   # bash helpers and layout rules, against tests/fake_tuios
```

```powershell
pwsh -File tests/Test-TuiosHelpers.ps1   # PowerShell helpers and layouts, against the real tuios (a throwaway session)
```

## Files

```
app_manager_tuios/
├── manager.sh / manager.ps1          # Interactive manager
├── start.sh / start.ps1              # Quick start helper
├── landing_page.sh / landing_page.ps1 # Dashboard server (port 1111)
├── setup_nginx_app_dashboard.sh      # nginx route for the dashboard (Linux)
├── apps_example.json
├── lib/                              # Bash: config, url, app, json, dashboard and tuios helpers
├── Modules/                          # PowerShell: AppHelpers, TuiosHelpers, Dashboard
└── tests/
```
