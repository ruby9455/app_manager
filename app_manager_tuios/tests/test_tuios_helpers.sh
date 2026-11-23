#!/usr/bin/env bash
#
# tests/test_tuios_helpers.sh - checks lib/tuios_helpers.sh against tests/fake_tuios, and the run commands
# in lib/app_helpers.sh
# Run: bash app_manager_tuios/tests/test_tuios_helpers.sh
#

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export FAKE_TUIOS_STATE="$tmp/state.json"
export APP_MANAGER_TUIOS_BIN="$SCRIPT_DIR/tests/fake_tuios"
export APP_MANAGER_TUIOS_SESSION="test_apps"
chmod +x "$APP_MANAGER_TUIOS_BIN" 2>/dev/null || true
unset TUIOS_SESSION

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/app_helpers.sh"
source "$SCRIPT_DIR/lib/tuios_helpers.sh"

fail=0
assert_eq() {
    if [[ "$1" == "$2" ]]; then
        echo "ok   - $3"
    else
        echo "FAIL - $3"
        echo "       expected: $1"
        echo "       actual:   $2"
        fail=1
    fi
}
assert_true() { if eval "$1"; then echo "ok   - $2"; else echo "FAIL - $2"; fail=1; fi }
assert_false() { if eval "$1"; then echo "FAIL - $2"; fail=1; else echo "ok   - $2"; fi }
window_count() { jq --arg s "$TUIOS_SESSION_NAME" '.sessions[$s] | length' "$FAKE_TUIOS_STATE"; }

assert_eq "test_apps" "$TUIOS_SESSION_NAME" "APP_MANAGER_TUIOS_SESSION names the session"
assert_eq "My_App__v1_2_x" "$(sanitize_window_name 'My App: v1.2/x')" "window names are sanitized as in the tmux edition"

FAKE_TUIOS_NO_DAEMON=1 assert_false "tuios_session_exists" "a saved session of a stopped daemon is not a live session"
assert_false "tuios_session_exists" "no session before the first app"
assert_false "tuios_window_exists 'My App'" "no window before the first app"

ensure_tuios_session >/dev/null
assert_true "tuios_session_exists" "ensure_tuios_session creates the session"
assert_true "tuios_window_exists _placeholder" "the first window is named _placeholder"

assert_true "tuios_new_window 'My App' '$tmp' 'echo hello' >/dev/null" "tuios_new_window creates a window"
assert_true "tuios_window_exists 'My App'" "the app window is found by its name"
assert_false "tuios_window_exists _placeholder" "the placeholder is closed when the first app starts"
assert_eq "1" "$(window_count)" "one window left"
assert_eq "bash" "$(jq -r --arg s "$TUIOS_SESSION_NAME" '.sessions[$s][0].argv[0]' "$FAKE_TUIOS_STATE")" "the window runs bash -c"
assert_true "jq -e --arg s \"\$TUIOS_SESSION_NAME\" '.sessions[\$s][0].argv[2] | contains(\"echo hello\") and contains(\"Press Enter\")' \"\$FAKE_TUIOS_STATE\" >/dev/null" \
    "the window runs the command, then waits for Enter"
# (the folder name: Git Bash on Windows turns /tmp/... into C:/... when it passes the path to a native jq)
assert_eq "$(basename "$tmp")" "$(basename "$(jq -r --arg s "$TUIOS_SESSION_NAME" '.sessions[$s][0].cwd' "$FAKE_TUIOS_STATE")")" "the window starts in the app folder"
assert_false "tuios_new_window 'My App' '$tmp' 'echo again' >/dev/null" "a second window with the same name is refused"

tuios_new_window "0" "$tmp" "echo zero" >/dev/null
zero_id=$(tuios_window_id "0")
assert_eq "$(jq -r --arg s "$TUIOS_SESSION_NAME" '.sessions[$s][] | select(.custom_name == "0") | .window_id' "$FAKE_TUIOS_STATE")" "$zero_id" \
    "a window named like an index is found by its name"
assert_eq "My_App" "$(get_running_window_names | head -1)" "get_running_window_names lists the app windows"

app_id=$(tuios_window_id "My App")
tuios_stop_app "My App" >/dev/null
assert_true "grep -qxF \"send-keys -s test_apps -w $app_id ctrl+c\" \"\$FAKE_TUIOS_STATE.log\"" "stop sends ctrl+c to the window by its full id"
assert_false "tuios_window_exists 'My App'" "stop closes the window"

tuios_kill_all_windows >/dev/null
assert_false "tuios_session_exists" "kill all removes the session"

# Groups: entries with the same Group share a workspace
apps='[
  {"Name": "Shop", "Type": "Django", "Port": 8000, "Group": "Shop"},
  {"Name": "Shop Scheduler", "CustomCommand": "sched", "Group": "Shop", "PaneSide": "down", "PaneRatio": 30},
  {"Name": "Shop Mailer", "CustomCommand": "mail", "Group": "Shop", "PaneSide": "down", "PaneRatio": 30},
  {"Name": "Blog", "Type": "Streamlit", "Port": 8501, "Group": "Blog"},
  {"Name": "Solo", "Type": "Streamlit", "Port": 8502}
]'
app_of() { echo "$apps" | jq -c --arg n "$1" '.[] | select(.Name == $n)'; }
win() { jq -c --arg s "$TUIOS_SESSION_NAME" --arg n "$(sanitize_window_name "$1")" '.sessions[$s][] | select(.custom_name == $n)' "$FAKE_TUIOS_STATE"; }
ws_name() { jq -r --arg s "$TUIOS_SESSION_NAME" --arg i "$1" '.names[$s][$i] // ""' "$FAKE_TUIOS_STATE"; }
launch() { tuios_launch_app_window "$apps" "$(app_of "$1")" "$1" "$tmp" "echo $1" >/dev/null; }

assert_eq "group" "$(tuios_group_placement "$apps" "$(app_of 'Shop Scheduler')")" "a group with nothing running needs a workspace of its own"
launch "Shop Scheduler"
assert_true "tuios_window_exists _placeholder" "the placeholder stays while workspace 1 has nothing else"
assert_eq "2" "$(win 'Shop Scheduler' | jq -r .workspace)" "the first pane of a group opens on the lowest empty workspace (2)"
assert_eq "Shop" "$(ws_name 2)" "the workspace is labelled with the group"
launch "Shop"
assert_eq "up" "$(win Shop | jq -r .split.side)" "the app restarting beside its scheduler goes on the opposite side"
assert_eq "70" "$(win Shop | jq -r .split.ratio)" "and takes the rest of the space"
tuios_stop_app "Shop" >/dev/null
tuios_stop_app "Shop Scheduler" >/dev/null
assert_eq "" "$(ws_name 2)" "stopping the last pane of a group clears its label"

launch "Shop"
assert_eq "2" "$(win Shop | jq -r .workspace)" "the freed workspace is used again"
launch "Shop Scheduler"
assert_eq "down 30 $(win Shop | jq -r .window_id)" "$(win 'Shop Scheduler' | jq -r '"\(.split.side) \(.split.ratio) \(.split.of)"')" \
    "the scheduler splits the app's pane down at 30%"
launch "Shop Mailer"
assert_eq "right $(win 'Shop Scheduler' | jq -r .window_id)" "$(win 'Shop Mailer' | jq -r '"\(.split.side) \(.split.of)"')" \
    "a second pane on the same side splits the first one across, so the app keeps its share"
assert_eq "2" "$(win 'Shop Mailer' | jq -r .workspace)" "every pane of the group is on its workspace"
launch "Blog"
assert_eq "3 Blog" "$(win Blog | jq -r .workspace) $(ws_name 3)" "another group gets the next empty workspace"
launch "Solo"
assert_eq "1" "$(win Solo | jq -r .workspace)" "an app with no Group opens on workspace 1"
assert_false "tuios_window_exists _placeholder" "the placeholder is closed once workspace 1 has a window"

# 2x2: PaneBeside names the pane to split
apps='[
  {"Name": "Grid App", "Type": "Streamlit", "Port": 8503, "Group": "Grid"},
  {"Name": "Grid A", "CustomCommand": "a", "Group": "Grid", "PaneSide": "right"},
  {"Name": "Grid B", "CustomCommand": "b", "Group": "Grid", "PaneSide": "down"},
  {"Name": "Grid C", "CustomCommand": "c", "Group": "Grid", "PaneSide": "down", "PaneBeside": "Grid A"}
]'
for n in "Grid App" "Grid A" "Grid B" "Grid C"; do launch "$n"; done
id_of() { win "$1" | jq -r .window_id; }
assert_eq "right $(id_of 'Grid App')" "$(win 'Grid A' | jq -r '"\(.split.side) \(.split.of)"')" "2x2: A splits the app to the right"
assert_eq "down $(id_of 'Grid App')" "$(win 'Grid B' | jq -r '"\(.split.side) \(.split.of)"')" "2x2: B splits the app down"
assert_eq "down $(id_of 'Grid A')" "$(win 'Grid C' | jq -r '"\(.split.side) \(.split.of)"')" "2x2: C splits the pane PaneBeside names (A) down"
tuios_kill_all_windows >/dev/null

# The dashboard never shares a workspace with the apps
tuios_launch_app_window "$apps" '{"Name": "Solo2", "Type": "Streamlit", "Port": 8504}' "Solo2" "$tmp" "echo solo" >/dev/null
tuios_start_dashboard_window "_Dashboard" "$tmp" "echo dashboard" >/dev/null
assert_eq "2 Dashboard" "$(win _Dashboard | jq -r .workspace) $(ws_name 2)" "outside tuios, the dashboard gets a workspace of its own, labelled Dashboard"
assert_eq "$TUIOS_SESSION_NAME" "$(tuios_dashboard_session _Dashboard)" "the dashboard is found in the apps session"
tuios_kill_all_windows >/dev/null

"$APP_MANAGER_TUIOS_BIN" new manager_session --detach >/dev/null
TUIOS_SESSION_NAME=manager_session tuios_new_window "manager" "$tmp" "echo manager" >/dev/null
manager_pane=$(TUIOS_SESSION_NAME=manager_session tuios_window_id "manager")
(
    export TUIOS_SESSION=manager_session TUIOS_WINDOW_ID="$manager_pane"
    tuios_start_dashboard_window "_Dashboard" "$tmp" "echo dashboard" >/dev/null
    assert_eq "manager_session" "$(tuios_dashboard_session _Dashboard)" "in a tuios pane, the dashboard opens in the manager's session"
    assert_eq "right $manager_pane 40" "$(jq -r '.sessions.manager_session[] | select(.custom_name == "_Dashboard") | "\(.split.side) \(.split.of) \(.split.ratio)"' "$FAKE_TUIOS_STATE")" \
        "beside the manager's pane (right, 40%)"
    assert_false "tuios_session_exists" "and the apps session is not created for it"
    exit $fail
) || fail=1

# Run commands (same rules as the tmux edition)
mkdir -p "$tmp/proj"
custom='{"Name":"api","Type":"Custom","Port":8100,"PackageManager":"uv","CustomCommand":"TZ=Europe/London uvicorn app:app --port {port}"}'
assert_eq "export TZ=Europe/London; uv run uvicorn app:app --port 8100" "$(build_app_run_command "$custom" "$tmp/proj")" \
    "Custom: {port}, VAR=value and uv run"
uvcmd='{"Name":"x","Type":"Custom","Port":1,"PackageManager":"uv","CustomCommand":"uv run --directory b python -m serve"}'
assert_eq "uv run --directory b python -m serve" "$(build_app_run_command "$uvcmd" "$tmp/proj")" "a command starting with uv runs as it is"
streamlit='{"Name":"s","Type":"Streamlit","Port":8501,"IndexPath":"app.py","PackageManager":"uv","NginxPath":"dash"}'
assert_eq "uv run streamlit run 'app.py' --server.port 8501 --server.baseUrlPath 'dash'" "$(build_app_run_command "$streamlit" "$tmp/proj")" \
    "Streamlit takes its base path from NginxPath"
noport='{"Name":"x","Type":"Custom","PackageManager":"uv","CustomCommand":"serve --port {port}"}'
assert_false "build_app_run_command '$noport' '$tmp/proj' 2>/dev/null" "{port} without a Port is an error"

exit $fail
