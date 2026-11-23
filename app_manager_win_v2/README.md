# App Management - Windows Terminal Edition (v2)

The tuios edition's manager on Windows Terminal: the same menu, commands, `apps.json` entries, layouts and dashboard
as `app_manager_tuios` (and `app_manager_tmux`), with Windows Terminal tabs and split panes in place of a tuios
session. It replaces `app_manager_win`, whose numbered menu it does not keep.

Everything opens in **the Windows Terminal window the manager runs in** (run outside Windows Terminal, the window
`app_manager`); starting an app never opens a window.

- An app with no `Group` opens as a **tab**.
- The entries of a `Group` (an app and its schedulers) open **side by side in a tab of their own**, laid out as
  `PaneSide`, `PaneRatio` and `PaneBeside` say (see [Layouts](#layouts-group-paneside-paneratio-panebeside)).
- After a start the manager's tab is selected again, so you can carry on typing; `t 3` shows app 3's tab.

## Requirements

- Windows 10/11, PowerShell 7+
- Windows Terminal (`wt.exe` on `PATH`; `winget install Microsoft.WindowsTerminal`)
- Python 3.8+ for the apps, with `uv` or pip

## Usage

```powershell
./start.ps1                      # Manager and dashboard side by side in a new tab of this window
./start.ps1 stop | list | attach | all | manager | landing | 'My App'

./manager.ps1                    # Interactive menu (+ dashboard on port 1111), from any Windows Terminal tab
./manager.ps1 -AppName 'My App'
./manager.ps1 -All
./manager.ps1 -DryRun -All       # Show what would run, and where
./manager.ps1 -Attach            # Bring the app window(s) to the front
./manager.ps1 -NoLanding         # Without the dashboard
```

The interactive commands are those of the tuios edition: start by number(s) or name (`0` for all), `s`/`r`/`u` stop,
restart and update, `aa`/`ap` add an app or a process, `e`/`d` edit or delete, `D` toggles the dashboard, `l` lists
the panes, `t` brings the app window to the front (`t 3` selects app 3's tab, and its pane in a group), `R` refreshes
and `q` quits. The table's `Where` column shows where each running app is: `tab`, or its group.

## Configuration

`apps.json` is found as in the other editions (see `AGENTS.md`): `$APP_MANAGER_APPS_FILE`, else
`~/code/app_manager_config/machines/<hostname>/win_v2/apps.json`, else `apps.json` next to the scripts. Entries are the
same as in the other editions (`apps_example.json`, and the "Custom apps" section of the root `README.md`). Run
commands are PowerShell: leading `VAR=value` settings in a `CustomCommand` become `$env:VAR = 'value'`, and a pip venv
is activated with its `Activate.ps1`.

| Variable | Default | Use |
|---|---|---|
| `APP_MANAGER_WT_SESSION` | `app_manager` | name of the apps' window when the manager is not run in Windows Terminal, and of the registry folder |
| `APP_MANAGER_WT_BIN` | `wt` | Windows Terminal executable |
| `APP_MANAGER_WT_STATE_DIR` | `%LOCALAPPDATA%\app_manager_wt` | the pane registry |
| `APP_MGMT_NETWORK_URL`, `APP_MGMT_EXTERNAL_URL` | detected | dashboard URL fallbacks |

## Layouts: Group, PaneSide, PaneRatio, PaneBeside

The same four optional fields as the tuios edition, with the same meaning; the other editions keep them when they edit
an entry.

| Field | Values | Meaning |
|---|---|---|
| `Group` | any name | Entries with the same Group open together in one tab |
| `PaneSide` | `left`, `right`, `up`, `down` | Where the pane goes beside the group's app. Leave it out on the app itself |
| `PaneRatio` | 1-99 | Share of the pane it splits, in percent (default: half) |
| `PaneBeside` | an entry's Name | Split that pane of the group instead of the app (e.g. for 2x2) |

How a pane is placed when it starts:

- **No Group**: a tab of the manager's window.
- **First pane of its group to start**: a tab of its own for the group. A group that is not running has no tab.
- **The group already has a pane running**: it splits the pane `PaneBeside` names, else the group's app (the member
  with a Port), on its `PaneSide`, taking `PaneRatio`. A second pane with the same `PaneSide` splits the first one
  across instead (down/up then right), so the app keeps its share: an app with three `down` schedulers gets the
  schedulers side by side under it. Started the other way round (the app restarting while its scheduler runs), the
  app goes on the opposite side and takes the rest, so the layout comes out the same.
- **The last pane of a group stops**: its tab closes.

```json
{ "Name": "My App", "Type": "Django", "Port": 8000, "AppPath": "C:\\Users\\me\\code\\my_app", "Group": "My App" },
{ "Name": "My App Scheduler", "AppPath": "C:\\Users\\me\\code\\my_app", "CustomCommand": "cache_scheduler",
  "Group": "My App", "PaneSide": "down", "PaneRatio": 30 }
```

Panes are placed as they start, so a layout depends on what is running: start the whole group (e.g. `3,4,5,6`) to get
it as configured. `aa`, `ap` and `e` ask for the fields (an empty answer keeps the value shown, `-` clears it). `ap`
puts a new process in the group of the app in the same folder, below it at 30%, and offers to add that app to the group.

## How it works

Windows Terminal's command line (`wt -w <window> new-tab | focus-tab | split-pane | focus-pane | swap-pane`) can open
and arrange tabs and panes, but not list, close or send keys to them, nor select a tab by its title. So:

- The manager's window has no name. `wt -w 0` means the most recently activated Windows Terminal window, so the
  manager brings its window to the front before each `wt` call. Each pane reports the window it opened in, and the
  manager warns if that is not the one intended.
- The manager keeps a registry of the panes it opens (`%LOCALAPPDATA%\app_manager_wt\<session>\panes\*.json`), with
  each group pane's id. Windows Terminal numbers the panes of a tab 0, 1, 2... and a pane keeps its id when a pane
  beside it closes, so a split can target the right pane (`focus-pane -t <id> ; split-pane ...`).
- A split goes into the selected tab, so the group's tab is selected first. Tabs are selected by index only, and UI
  Automation shows the panes of the selected tab only, by their titles (the app names): the manager tries the tab's
  last known index, then 0, 1, 2... until the tab showing one of the group's panes is selected. It finds its own tab
  the same way, by its pane's UI Automation id, to come back to it after a start. Tabs you open, close or move yourself
  are fine; while it looks, the selected tab changes briefly.
- Windows Terminal splits only down and right; `up` and `left` split and then swap the two panes.
- Every pane runs `Modules/PaneHost.ps1`. It records its process in the registry, runs the app, and watches for a stop
  request: then it sends Ctrl+C to its console and exits 0, which makes Windows Terminal close the pane. An app that
  ignores Ctrl+C is ended after 10 seconds.
- An app that exits by itself leaves its pane open with its output and exit code until Enter is pressed (or the app is
  stopped or restarted from the manager). Ctrl+C typed in a pane stops the app and leaves the pane open.

Keep a group's tab to the manager: a pane split there by hand makes later splits land in the wrong place. Close stray
panes and restart the group. If a group's apps are still running in another window (say, the manager was restarted
elsewhere), its new panes go to that window.

## Tests

```powershell
pwsh -File tests/Test-WtHelpers.ps1         # placement rules, wt arguments, apps.json lookup, registry
pwsh -File tests/Test-WtHelpers.ps1 -Live   # also real Windows Terminal windows (a throwaway session): layouts, tabs, stop
```

## Files

```
app_manager_win_v2/
├── manager.ps1          # Interactive manager
├── start.ps1            # Quick start helper
├── landing_page.ps1     # Dashboard server (port 1111)
├── apps_example.json
├── Modules/             # AppHelpers, Dashboard, WtHelpers (panes and layouts), PaneHost.ps1 (what a pane runs)
└── tests/
```
