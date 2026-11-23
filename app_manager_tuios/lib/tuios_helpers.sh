#!/usr/bin/env bash
#
# lib/tuios_helpers.sh - tuios helper functions for app management
#
# The tuios equivalent of tmux_helpers.sh. Every app runs in a named window of one detached tuios session, driven
# through the tuios CLI, which talks to the tuios daemon whether or not a client is attached:
#   - tuios new NAME --detach            create the session (starts the daemon when none runs)
#   - tuios new-window NAME --cwd DIR -- run a command in a named window (argv, no shell in between)
#   - tuios list-windows --json          find a window by its name (custom_name) and get its id
#   - tuios send-keys -w ID ctrl+c       stop the program in a window
#   - tuios close-window ID              close a window
#   - tuios attach / switch-session      show the session (switch-session from inside a tuios pane)
# Windows are addressed by their full id once found, so a name is never taken for an index or an id prefix.
#
# Source this file to use the functions:
#   source "$(dirname "${BASH_SOURCE[0]}")/tuios_helpers.sh"
#

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default session name (can be overridden)
TUIOS_SESSION_NAME="${TUIOS_SESSION_NAME:-app_manager}"

# The tuios executable (override with APP_MANAGER_TUIOS_BIN)
TUIOS_BIN="${APP_MANAGER_TUIOS_BIN:-tuios}"

# Run the tuios CLI
tuios_cmd() {
    "$TUIOS_BIN" "$@"
}

# Check if tuios is available
tuios_available() {
    command -v "$TUIOS_BIN" &>/dev/null
}

# Check if running inside a tuios pane
is_in_tuios() {
    [[ -n "${TUIOS_SESSION:-}" ]]
}

# Names of the live sessions, one per line (saved sessions of a stopped daemon are left out)
tuios_session_names() {
    local json
    # No daemon: `tuios ls` exits 3 and lists the saved sessions, which are not running
    json=$(tuios_cmd ls --json 2>/dev/null) || return 0
    echo "$json" | jq -r '
        (if type == "array" then .[] elif type == "object" and has("sessions") then .sessions[] else . end)
        | select(type == "object" and ((.saved // false) | not)) | .name // empty' 2>/dev/null || true
}

# Check if the app manager session exists
tuios_session_exists() {
    tuios_session_names | grep -qxF "$TUIOS_SESSION_NAME"
}

# Create the app manager session if it doesn't exist
# Names its first window _placeholder; that window is closed when the first app starts
ensure_tuios_session() {
    if ! tuios_session_exists; then
        if ! tuios_cmd new "$TUIOS_SESSION_NAME" --detach >/dev/null; then
            echo -e "${RED}Unable to create tuios session: $TUIOS_SESSION_NAME${NC}" >&2
            return 1
        fi
        tuios_cmd set-window -s "$TUIOS_SESSION_NAME" --name "_placeholder" >/dev/null 2>&1 || true
        echo -e "${GREEN}Created tuios session: $TUIOS_SESSION_NAME${NC}"
    fi
}

# Get sanitized window name (same rule as the tmux edition)
sanitize_window_name() {
    local name="$1"
    # Replace spaces and special chars with underscores
    echo "$name" | tr ' /:.' '_' | tr -cd '[:alnum:]_-'
}

# The windows of the session as JSON (empty when there is no session)
tuios_windows_json() {
    tuios_cmd list-windows -s "$TUIOS_SESSION_NAME" --json 2>/dev/null || true
}

# Full id of the window with the given name, empty when there is none
# Usage: tuios_window_id "window_name"
tuios_window_id() {
    local window_name="$1"
    local sanitized=$(sanitize_window_name "$window_name")
    local json=$(tuios_windows_json)
    [[ -z "$json" ]] && return 0
    echo "$json" | jq -r --arg name "$sanitized" \
        '[.windows[]? | select((.custom_name // "") == $name) | .window_id][0] // empty' 2>/dev/null | tr -d '\r' || true
}

# Check if a window with the given name exists
# Usage: tuios_window_exists "window_name"
tuios_window_exists() {
    local window_name="$1"
    [[ -n "$(tuios_window_id "$window_name")" ]]
}

# Create a new tuios window and run a command
# Placement (optional):
#   workspace N                    open on workspace N
#   split SIDE TARGET_ID [RATIO]   split the pane TARGET_ID and open beside it, on the side SIDE (left/right/up/down),
#                                  taking RATIO percent of its space (default: half)
# Usage: tuios_new_window "App Name" "/path/to/working/dir" "command to run" [placement...]
tuios_new_window() {
    local app_name="$1"
    local working_dir="$2"
    local command="$3"
    local mode="${4:-}"
    local window_name=$(sanitize_window_name "$app_name")
    
    ensure_tuios_session || return 1
    
    # Check if window already exists
    if tuios_window_exists "$app_name"; then
        echo -e "${YELLOW}Window '$app_name' already exists. Use restart to replace it.${NC}"
        return 1
    fi
    
    # Create new window with the command
    # Use bash -c with proper escaping for complex commands
    # The command runs and then waits for user input before closing
    local run=(bash -c "echo '=== Starting: $app_name ==='; echo 'Directory: $working_dir'; echo '---'; $command; ret=\$?; echo ''; echo '=== App exited with code '\$ret' ==='; echo 'Press Enter to close this window...'; read")
    local created=false
    if [[ "$mode" == "split" ]]; then
        # A headless session floats its panes; split-window tiles them (move-window --beside is refused there)
        local ratio_args=()
        [[ -n "${7:-}" ]] && ratio_args=(--ratio "$7")
        tuios_cmd split-window "$5" -s "$TUIOS_SESSION_NAME" -w "$6" ${ratio_args[@]+"${ratio_args[@]}"} \
            --name "$window_name" --cwd "$working_dir" --no-focus -- "${run[@]}" >/dev/null && created=true
    else
        local workspace_args=()
        [[ "$mode" == "workspace" ]] && workspace_args=(--workspace "$5")
        tuios_cmd new-window -s "$TUIOS_SESSION_NAME" "$window_name" ${workspace_args[@]+"${workspace_args[@]}"} \
            --cwd "$working_dir" -- "${run[@]}" >/dev/null && created=true
    fi
    if ! $created; then
        echo -e "${RED}Unable to create tuios window '$app_name'${NC}" >&2
        return 1
    fi
    
    # Remove the placeholder once something else is on workspace 1 (closing the last window there can make tuios
    # pull another workspace's only window onto it)
    local placeholder_id=$(tuios_window_id "_placeholder")
    if [[ -n "$placeholder_id" && "$mode" != "split" && ( "$mode" != "workspace" || "$5" == "1" ) ]]; then
        tuios_cmd close-window -s "$TUIOS_SESSION_NAME" "$placeholder_id" >/dev/null 2>&1 || true
    fi
    
    return 0
}

# The workspaces of the session as JSON (empty when there is no session)
tuios_workspaces_json() {
    tuios_cmd list-workspaces -s "$TUIOS_SESSION_NAME" --json 2>/dev/null || true
}

# Workspace number of a window, empty when there is none
# Usage: tuios_window_workspace "$window_id"
tuios_window_workspace() {
    tuios_windows_json | jq -r --arg id "$1" '[.windows[]? | select(.window_id == $id) | .workspace][0] // empty' 2>/dev/null | tr -d '\r' || true
}

# Lowest empty workspace from 2 to 9 (workspace 1 holds the dashboard and the apps with no Group)
# Usage: tuios_free_workspace
tuios_free_workspace() {
    local free
    free=$(tuios_workspaces_json | jq -r '[.workspaces[]? | select(.workspace >= 2 and .window_count == 0) | .workspace][0] // empty' 2>/dev/null | tr -d '\r')
    [[ -n "$free" ]] || return 1
    echo "$free"
}

# Label a workspace (no name clears it)
# Usage: tuios_set_workspace_name 2 "My App"
tuios_set_workspace_name() {
    if [[ -n "${2:-}" ]]; then
        tuios_cmd set-workspace-name -s "$TUIOS_SESSION_NAME" "$1" "$2" >/dev/null 2>&1 || true
    else
        tuios_cmd set-workspace-name -s "$TUIOS_SESSION_NAME" "$1" >/dev/null 2>&1 || true
    fi
}

# Clear the labels of empty workspaces, so a stopped group leaves no name behind
# Usage: tuios_clear_empty_workspace_names
tuios_clear_empty_workspace_names() {
    local workspace
    while IFS= read -r workspace; do
        workspace="${workspace%$'\r'}"
        [[ -n "$workspace" ]] && tuios_set_workspace_name "$workspace"
    done < <(tuios_workspaces_json | jq -r '.workspaces[]? | select(.window_count == 0 and (.name // "") != "") | .workspace' 2>/dev/null)
}

# Where an app's window goes (apps.json fields Group, PaneSide, PaneRatio, PaneBeside):
#   - no Group: workspace 1, with the dashboard
#   - no other pane of its Group running: a workspace of its own ("group"; the caller picks the lowest empty one)
#   - PaneBeside names a running pane of the group: split that pane on the side PaneSide names (default: right)
#   - else beside the group's main pane (the running member with a Port, else the first running one), split on the
#     side PaneSide names, taking PaneRatio percent. A second pane with the same PaneSide splits the first one across
#     (down/up -> right, left/right -> down), so the main pane keeps its share. An entry with no PaneSide (the app
#     restarting while its scheduler runs) goes on the opposite side of that pane, taking the rest of the space.
# Prints one of: "workspace 1" | "group" | "split SIDE WINDOW_ID [RATIO]"
# Usage: tuios_group_placement "$apps_json" "$app_json"
tuios_group_placement() {
    local apps_json="$1"
    local app_json="$2"
    local windows_json=$(tuios_windows_json)
    [[ -z "$windows_json" ]] && windows_json='{}'
    jq -rn --argjson apps "$apps_json" --argjson app "$app_json" --argjson wins "$windows_json" '
        def sname: gsub("[ /:.]"; "_") | gsub("[^A-Za-z0-9_-]"; "");
        def lc: ascii_downcase;
        def side: (.PaneSide // "" | tostring | lc) as $s | if ($s | IN("left", "right", "up", "down")) then $s else "" end;
        def ratio: (.PaneRatio // null) as $r | if ($r | type) == "number" and $r >= 1 and $r <= 99 then ($r | floor) else null end;
        def across: if . == "down" or . == "up" then "right" else "down" end;
        def opposite: {"down": "up", "up": "down", "left": "right", "right": "left"}[.];
        ($app.Group // "" | tostring) as $group
        | if $group == "" then "workspace 1"
          else
            [ $apps[]
              | select((.Group // "" | tostring | lc) == ($group | lc) and (.Name | lc) != ($app.Name | lc))
              | . as $m
              | ([$wins.windows[]? | select((.custom_name // "") == ($m.Name | sname))][0]) as $w
              | select($w != null)
              | $m + {_id: $w.window_id} ] as $running
            | if ($running | length) == 0 then "group"
              else
                (([$running[] | select((.Port // 0) > 0)] + $running)[0]) as $anchor
                | ($app | side) as $side
                | ($app | ratio) as $ratio
                | ($app.PaneBeside // "" | tostring | lc) as $beside
                | ([$running[] | select($beside != "" and (.Name | lc) == $beside)][0]) as $target
                | if $target != null then
                    "split \(if $side != "" then $side else "right" end) \($target._id)" + (if $ratio then " \($ratio)" else "" end)
                  elif $side != "" then
                    ([$running[] | select(._id != $anchor._id and (side == $side) and ((.PaneBeside // "") == ""))] | last) as $sibling
                    | if $sibling != null then "split \($side | across) \($sibling._id)"
                      else "split \($side) \($anchor._id)" + (if $ratio then " \($ratio)" else "" end)
                      end
                  elif ($anchor | side) != "" then
                    "split \($anchor | side | opposite) \($anchor._id) \(100 - (($anchor | ratio) // 50))"
                  else "split right \($anchor._id)"
                  end
              end
          end' | tr -d '\r'
}

# Open an app's window where its Group puts it (see tuios_group_placement); a group that has no running pane gets the
# lowest empty workspace from 2 to 9, labelled with the group name
# Usage: tuios_launch_app_window "$apps_json" "$app_json" "App Name" "/path/to/working/dir" "command to run"
tuios_launch_app_window() {
    local apps_json="$1" app_json="$2" name="$3" working_dir="$4" run_cmd="$5"
    local group=$(echo "$app_json" | jq -r '.Group // empty' | tr -d '\r')
    
    ensure_tuios_session || return 1
    local placement=()
    read -r -a placement <<< "$(tuios_group_placement "$apps_json" "$app_json")"
    
    case "${placement[0]:-}" in
        split)
            echo -e "${CYAN}Placing '$name' ${placement[1]} of its group '$group'${NC}"
            tuios_new_window "$name" "$working_dir" "$run_cmd" split "${placement[1]}" "${placement[2]}" "${placement[3]:-}"
            ;;
        group)
            tuios_clear_empty_workspace_names
            local workspace
            if workspace=$(tuios_free_workspace); then
                echo -e "${CYAN}Opening group '$group' on workspace $workspace${NC}"
                tuios_new_window "$name" "$working_dir" "$run_cmd" workspace "$workspace" || return 1
                tuios_set_workspace_name "$workspace" "$group"
            else
                echo -e "${YELLOW}Workspaces 2-9 are all in use; opening '$name' on workspace 1${NC}"
                tuios_new_window "$name" "$working_dir" "$run_cmd" workspace 1
            fi
            ;;
        *)
            tuios_new_window "$name" "$working_dir" "$run_cmd" workspace 1
            ;;
    esac
}

# The dashboard never shares a workspace with the apps:
#   - the manager runs in a tuios pane: the dashboard opens beside it (right, 40%), in the manager's session
#   - else: a workspace of its own in the apps' session, the lowest empty one from 2 to 9, labelled "Dashboard"
# Usage: tuios_start_dashboard_window "_Dashboard" "/path/to/working/dir" "command to run"
tuios_start_dashboard_window() {
    local name="$1" working_dir="$2" command="$3"
    if is_in_tuios && [[ -n "${TUIOS_WINDOW_ID:-}" ]]; then
        TUIOS_SESSION_NAME="$TUIOS_SESSION" tuios_new_window "$name" "$working_dir" "$command" split right "$TUIOS_WINDOW_ID" 40
        return
    fi
    ensure_tuios_session || return 1
    tuios_clear_empty_workspace_names
    local workspace
    if workspace=$(tuios_free_workspace); then
        tuios_new_window "$name" "$working_dir" "$command" workspace "$workspace" || return 1
        tuios_set_workspace_name "$workspace" "Dashboard"
    else
        echo -e "${YELLOW}Workspaces 2-9 are all in use; opening the dashboard on workspace 1${NC}"
        tuios_new_window "$name" "$working_dir" "$command" workspace 1
    fi
}

# Session that holds the dashboard window: the manager's own session (when it runs in a tuios pane), else the apps'
# session; empty when neither has it
# Usage: tuios_dashboard_session "_Dashboard"
tuios_dashboard_session() {
    local name="$1"
    if is_in_tuios && TUIOS_SESSION_NAME="$TUIOS_SESSION" tuios_window_exists "$name"; then
        echo "$TUIOS_SESSION"
    elif tuios_window_exists "$name"; then
        echo "$TUIOS_SESSION_NAME"
    fi
}

# Send Ctrl+C to a tuios window to gracefully stop the app
# Usage: tuios_send_ctrl_c "App Name"
tuios_send_ctrl_c() {
    local app_name="$1"
    local window_id=$(tuios_window_id "$app_name")
    
    if [[ -z "$window_id" ]]; then
        echo -e "${YELLOW}Window '$app_name' not found${NC}"
        return 1
    fi
    
    tuios_cmd send-keys -s "$TUIOS_SESSION_NAME" -w "$window_id" ctrl+c >/dev/null 2>&1 || true
    return 0
}

# Kill a tuios window by name
# Usage: tuios_kill_window "App Name"
tuios_kill_window() {
    local app_name="$1"
    local window_id=$(tuios_window_id "$app_name")
    
    if [[ -z "$window_id" ]]; then
        echo -e "${YELLOW}Window '$app_name' not found${NC}"
        return 0
    fi
    
    tuios_cmd close-window -s "$TUIOS_SESSION_NAME" "$window_id" >/dev/null 2>&1 || true
    echo -e "${GREEN}Killed window: $app_name${NC}"
    return 0
}

# Stop an app gracefully (Ctrl+C) then kill the window
# Usage: tuios_stop_app "App Name" [keep_window]
tuios_stop_app() {
    local app_name="$1"
    local keep_window="${2:-false}"
    
    if ! tuios_window_exists "$app_name"; then
        return 0
    fi
    
    # Send Ctrl+C to gracefully stop
    tuios_send_ctrl_c "$app_name"
    sleep 1
    
    # Kill the window unless we're keeping it for restart
    if [[ "$keep_window" != "true" ]]; then
        tuios_kill_window "$app_name"
        # A group that has stopped leaves no label on its workspace
        tuios_clear_empty_workspace_names
    fi
    
    return 0
}

# Restart an app in the same window
# Usage: tuios_restart_app "App Name" "/path/to/working/dir" "command"
tuios_restart_app() {
    local app_name="$1"
    local working_dir="$2"
    local command="$3"
    
    # Stop the app first
    if tuios_window_exists "$app_name"; then
        tuios_stop_app "$app_name" "true"
        sleep 1
        # Kill and recreate window
        tuios_kill_window "$app_name" 2>/dev/null
    fi
    
    # Start fresh
    tuios_new_window "$app_name" "$working_dir" "$command"
}

# List all windows in the app manager session
# Usage: tuios_list_windows
tuios_list_windows() {
    if ! tuios_session_exists; then
        echo -e "${YELLOW}No tuios session found${NC}"
        return 0  # Don't return error - it's a valid state
    fi
    
    echo -e "${CYAN}tuios windows in session '$TUIOS_SESSION_NAME':${NC}"
    tuios_windows_json | jq -r \
        '.windows[]? | "  \(.index): \(.custom_name // .display_name // .title // .window_id) (workspace \(.workspace // "?"))"' \
        2>/dev/null || true
}

# Get list of running window names
# Usage: get_running_window_names
get_running_window_names() {
    tuios_windows_json | jq -r '.windows[]? | .custom_name // empty' 2>/dev/null | grep -v "^_placeholder$" || true
}

# Kill all windows in the session
# Usage: tuios_kill_all_windows
tuios_kill_all_windows() {
    if ! tuios_session_exists; then
        echo -e "${YELLOW}No tuios session found${NC}"
        return 0  # Don't return error - it's a valid state
    fi
    
    # Ctrl+C to every window but the placeholder
    local window_id
    while IFS= read -r window_id; do
        window_id="${window_id%$'\r'}"  # a Windows jq (Git Bash) ends its lines with CRLF
        [[ -z "$window_id" ]] && continue
        tuios_cmd send-keys -s "$TUIOS_SESSION_NAME" -w "$window_id" ctrl+c >/dev/null 2>&1 || true
    done < <(tuios_windows_json | jq -r '.windows[]? | select((.custom_name // "") != "_placeholder") | .window_id' 2>/dev/null)
    
    sleep 1
    
    # Kill the entire session
    tuios_cmd kill-session "$TUIOS_SESSION_NAME" >/dev/null 2>&1 || true
    echo -e "${GREEN}Killed all windows and session${NC}"
}

# Attach to the tuios session
# Usage: tuios_attach
tuios_attach() {
    if ! tuios_session_exists; then
        echo -e "${YELLOW}No tuios session found. Start some apps first.${NC}"
        return 0  # Don't return error - it's a valid state
    fi
    
    if is_in_tuios; then
        # Already in tuios: tuios refuses to nest a client in a pane, so switch this client to the session
        tuios_cmd switch-session "$TUIOS_SESSION_NAME" || true
    else
        tuios_cmd attach "$TUIOS_SESSION_NAME" || true
    fi
}

# Select/focus a specific window
# Usage: tuios_select_window "App Name"
tuios_select_window() {
    local app_name="$1"
    local window_id=$(tuios_window_id "$app_name")
    
    if [[ -z "$window_id" ]]; then
        echo -e "${YELLOW}Window '$app_name' not found${NC}"
        return 1
    fi
    
    tuios_cmd focus-window -s "$TUIOS_SESSION_NAME" "$window_id" >/dev/null
}

# Print a colored header
print_header() {
    local text="$1"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $text${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
}

# Print app info in a formatted way (workspace: the tuios workspace of the app's window, "-" for none)
print_app_info() {
    local index="$1"
    local name="$2"
    local type="$3"
    local port="$4"
    local status="$5"
    local workspace="${6:--}"
    
    local status_color="$RED"
    local status_icon="○"
    if [[ "$status" == "running" ]]; then
        status_color="$GREEN"
        status_icon="●"
    fi
    
    printf "${BLUE}%3d${NC} │ %-30s │ %-10s │ %-6s │ %-2s │ %b%s %s%b\n" \
        "$index" "$name" "$type" "$port" "$workspace" "$status_color" "$status_icon" "$status" "$NC"
}

# Print table header
print_table_header() {
    echo -e "${PURPLE}────┬────────────────────────────────┬────────────┬────────┬────┬──────────${NC}"
    printf "${PURPLE}  # │ %-30s │ %-10s │ %-6s │ %-2s │ Status${NC}\n" "Name" "Type" "Port" "WS"
    echo -e "${PURPLE}────┼────────────────────────────────┼────────────┼────────┼────┼──────────${NC}"
}

# Print table footer
print_table_footer() {
    echo -e "${PURPLE}────┴────────────────────────────────┴────────────┴────────┴────┴──────────${NC}"
}

# Prompt for user input with color
prompt_input() {
    local prompt="$1"
    local response
    echo -ne "${CYAN}$prompt${NC}"
    read -r response
    echo "$response"
}
