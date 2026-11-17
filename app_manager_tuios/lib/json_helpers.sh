#!/usr/bin/env bash
#
# lib/json_helpers.sh - JSON manipulation helpers for apps.json
#
# Source this file to use the functions:
#   source "$(dirname "${BASH_SOURCE[0]}")/json_helpers.sh"
#

# Get apps.json file path (global for the session)
APPS_JSON_FILE=""

# Initialize the apps JSON file path
# Usage: init_apps_json_file "/path/to/script/dir"
init_apps_json_file() {
    local script_dir="$1"
    APPS_JSON_FILE="$script_dir/apps.json"
}

# Add a new app to apps.json
# Usage: add_app_to_json "$json_file" "$app_json"
add_app_to_json() {
    local json_file="$1"
    local app_json="$2"
    
    if [[ ! -f "$json_file" ]]; then
        echo "[$app_json]" > "$json_file"
    else
        # Add to existing array
        local existing=$(cat "$json_file")
        echo "$existing" | jq ". + [$app_json]" > "$json_file"
    fi
}

# Update an app in apps.json by name
# Usage: update_app_in_json "$json_file" "$app_name" "$new_app_json"
update_app_in_json() {
    local json_file="$1"
    local app_name="$2"
    local new_app_json="$3"
    
    local existing=$(cat "$json_file")
    echo "$existing" | jq --arg name "$app_name" --argjson newapp "$new_app_json" \
        'map(if (.Name | ascii_downcase) == ($name | ascii_downcase) then $newapp else . end)' > "$json_file"
}

# Remove an app from apps.json by name
# Usage: remove_app_from_json "$json_file" "$app_name"
remove_app_from_json() {
    local json_file="$1"
    local app_name="$2"
    
    local existing=$(cat "$json_file")
    echo "$existing" | jq --arg name "$app_name" \
        'map(select((.Name | ascii_downcase) != ($name | ascii_downcase)))' > "$json_file"
}

# Check if an app name already exists
# Usage: app_name_exists "$json_file" "$app_name"
app_name_exists() {
    local json_file="$1"
    local app_name="$2"
    
    if [[ ! -f "$json_file" ]]; then
        return 1
    fi
    
    local count=$(cat "$json_file" | jq --arg name "$app_name" \
        '[.[] | select((.Name | ascii_downcase) == ($name | ascii_downcase))] | length')
    
    [[ "$count" -gt 0 ]]
}

# Detect app type from project directory
# Custom = a web app started with its own command (e.g. FastAPI/uvicorn, gunicorn)
# Usage: detect_app_type "/path/to/project"
detect_app_type() {
    local project_dir="$1"
    
    # Check pyproject.toml first
    if [[ -f "$project_dir/pyproject.toml" ]]; then
        local content=$(cat "$project_dir/pyproject.toml")
        if echo "$content" | grep -qi "streamlit"; then echo "Streamlit"; return; fi
        if echo "$content" | grep -qi "django"; then echo "Django"; return; fi
        if echo "$content" | grep -qi "flask"; then echo "Flask"; return; fi
        if echo "$content" | grep -qi "dash"; then echo "Dash"; return; fi
        if echo "$content" | grep -qiE "fastapi|uvicorn|gunicorn"; then echo "Custom"; return; fi
    fi
    
    # Check requirements.txt
    local req_file=$(find "$project_dir" -maxdepth 2 -name "requirements.txt" -type f 2>/dev/null | head -1)
    if [[ -n "$req_file" ]]; then
        local content=$(cat "$req_file")
        if echo "$content" | grep -qi "streamlit"; then echo "Streamlit"; return; fi
        if echo "$content" | grep -qi "django"; then echo "Django"; return; fi
        if echo "$content" | grep -qi "flask"; then echo "Flask"; return; fi
        if echo "$content" | grep -qi "dash"; then echo "Dash"; return; fi
        if echo "$content" | grep -qiE "fastapi|uvicorn|gunicorn"; then echo "Custom"; return; fi
    fi
    
    echo "Unknown"
}

# Interactive: Select app type
# Usage: select_app_type "$default_type"
select_app_type() {
    local default_type="${1:-Streamlit}"
    local type_choice
    echo "Select app type:" >&2
    echo "  1) Streamlit" >&2
    echo "  2) Django" >&2
    echo "  3) Flask" >&2
    echo "  4) Dash" >&2
    echo "  5) Custom (any web app with its own start command, e.g. FastAPI/uvicorn)" >&2
    read -r -p "Enter choice [1-5]: " type_choice
    case "$type_choice" in
        1) echo "Streamlit" ;;
        2) echo "Django" ;;
        3) echo "Flask" ;;
        4) echo "Dash" ;;
        5) echo "Custom" ;;
        *) echo "$default_type" ;;
    esac
}

# Interactive: Get the start command of a Custom app
# Usage: prompt_custom_command "$port" ["$current_command"]
prompt_custom_command() {
    local port="$1"
    local current="${2:-}"
    local cmd
    echo -e "${CYAN}Start command, run in AppPath. {port} is replaced by the app's port ($port); leading VAR=value" >&2
    echo -e "settings are exported first. With uv, 'uv run' is added unless the command starts with uv. Examples:${NC}" >&2
    echo "  uvicorn app.main:app --host 0.0.0.0 --port {port}" >&2
    echo "  TZ=Europe/London python -m myapp.serve --host 0.0.0.0 --port {port}" >&2
    echo "  uv run --directory backend gunicorn -b 0.0.0.0:{port} app:server" >&2
    if [[ -n "$current" ]]; then
        read -r -p "CustomCommand [$current]: " cmd
        cmd="${cmd:-$current}"
    else
        read -r -p "CustomCommand: " cmd
    fi
    if [[ -n "$cmd" && "$cmd" != *"{port}"* && "$cmd" != *"$port"* ]]; then
        echo -e "${YELLOW}Note: the command has neither {port} nor $port; make sure the app listens on port $port${NC}" >&2
    fi
    echo "$cmd"
}

# Find all Python files in a project (excluding venv)
# Usage: find_python_files "/path/to/project"
find_python_files() {
    local project_dir="$1"
    
    # Exclude common venv directories
    find "$project_dir" -name "*.py" -type f \
        ! -path "*/venv/*" \
        ! -path "*/.venv/*" \
        ! -path "*/env/*" \
        ! -path "*/.env/*" \
        ! -path "*/__pycache__/*" \
        ! -path "*/site-packages/*" \
        2>/dev/null | sort
}

# Interactive: Select index/main Python file
# Usage: select_index_file "/path/to/project"
select_index_file() {
    local project_dir="$1"
    
    local files=()
    mapfile -t files < <(find_python_files "$project_dir")
    
    if [[ ${#files[@]} -eq 0 ]]; then
        echo ""
        return 1
    fi
    
    echo -e "${CYAN}Found Python files:${NC}" >&2
    local i=1
    for file in "${files[@]}"; do
        echo "  $i) $(rel_path "$project_dir" "$file")" >&2
        i=$((i + 1))
    done
    
    local selection
    read -r -p "Select index file (number or path): " selection
    
    if [[ "$selection" =~ ^[0-9]+$ ]]; then
        local idx=$((selection - 1))
        if [[ $idx -ge 0 && $idx -lt ${#files[@]} ]]; then
            rel_path "$project_dir" "${files[$idx]}"
            return 0
        fi
    fi
    
    # Treat as path
    echo "$selection"
}

# Generate a random available port
# Usage: get_random_port
get_random_port() {
    local port
    local max_attempts=50
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        port=$((RANDOM % 6000 + 3000))  # Range: 3000-8999
        
        if ! is_port_in_use "$port" 2>/dev/null; then
            echo "$port"
            return 0
        fi
        attempt=$((attempt + 1))
    done
    
    # Fallback
    echo $((RANDOM % 6000 + 3000))
}

# Interactive: Get port number
# Usage: get_port_number
get_port_number() {
    local response
    read -r -p "Assign a random port? [Y/n]: " response
    
    if [[ -z "$response" || "${response,,}" =~ ^(y|yes)$ ]]; then
        local port=$(get_random_port)
        echo -e "${GREEN}Assigned port: $port${NC}" >&2
        echo "$port"
    else
        local port
        read -r -p "Enter port number: " port
        
        if [[ ! "$port" =~ ^[0-9]+$ ]]; then
            echo -e "${YELLOW}Invalid port, generating random...${NC}" >&2
            port=$(get_random_port)
            echo -e "${GREEN}Assigned port: $port${NC}" >&2
        fi
        
        echo "$port"
    fi
}

# Build app JSON object from parameters
# Usage: build_app_json "name" "type" "port" "app_path" "index_path" "venv_path" "pkg_manager" "nginx_path" "custom_command"
build_app_json() {
    local name="$1"
    local app_type="$2"
    local port="$3"
    local app_path="$4"
    local index_path="${5:-}"
    local venv_path="${6:-}"
    local pkg_manager="${7:-}"
    local nginx_path="${8:-}"
    local custom_command="${9:-}"
    
    local json=$(jq -n \
        --arg name "$name" \
        --arg type "$app_type" \
        --argjson port "$port" \
        --arg appPath "$app_path" \
        '{Name: $name, Type: $type, Port: $port, AppPath: $appPath}')
    
    # Add optional fields if present
    if [[ -n "$index_path" ]]; then
        json=$(echo "$json" | jq --arg val "$index_path" '. + {IndexPath: $val}')
    fi
    
    if [[ -n "$venv_path" ]]; then
        json=$(echo "$json" | jq --arg val "$venv_path" '. + {VenvPath: $val}')
    fi
    
    if [[ -n "$pkg_manager" ]]; then
        json=$(echo "$json" | jq --arg val "$pkg_manager" '. + {PackageManager: $val}')
    fi

    if [[ -n "$nginx_path" ]]; then
        json=$(echo "$json" | jq --arg val "$nginx_path" '. + {NginxPath: $val}')
    fi
    
    if [[ -n "$custom_command" ]]; then
        json=$(echo "$json" | jq --arg val "$custom_command" '. + {CustomCommand: $val}')
    fi
    
    echo "$json"
}

# Keep the fields an editor does not manage (e.g. BasePath, or Port/NginxPath on a process) from the old entry
# Usage: merge_unmanaged_fields "$old_json" "$new_json" Name AppPath ...
merge_unmanaged_fields() {
    local old_json="$1"
    local new_json="$2"
    shift 2
    jq -n --argjson old "$old_json" --argjson new "$new_json" --args \
        '($old | with_entries(select(.key as $k | $ARGS.positional | index($k) | not))) + $new' "$@"
}

# Build process JSON object (custom command, no Type required)
# Usage: build_process_json "name" "app_path" "custom_command" "venv_path" "pkg_manager"
build_process_json() {
    local name="$1"
    local app_path="$2"
    local custom_command="$3"
    local venv_path="${4:-}"
    local pkg_manager="${5:-}"
    
    local json=$(jq -n \
        --arg name "$name" \
        --arg appPath "$app_path" \
        --arg customCmd "$custom_command" \
        '{Name: $name, AppPath: $appPath, CustomCommand: $customCmd}')
    
    # Add optional fields if present
    if [[ -n "$venv_path" ]]; then
        json=$(echo "$json" | jq --arg val "$venv_path" '. + {VenvPath: $val}')
    fi
    
    if [[ -n "$pkg_manager" ]]; then
        json=$(echo "$json" | jq --arg val "$pkg_manager" '. + {PackageManager: $val}')
    fi
    
    echo "$json"
}

# ---------------------------------------------------------------------------------------------------------------------
# Workspace layout fields (tuios edition): Group, PaneSide, PaneRatio, PaneBeside
#   Group      entries with the same Group open together on one workspace
#   PaneSide   left/right/up/down: where the pane goes beside the group's main pane (empty: the main pane, or auto)
#   PaneRatio  1-99: the share in percent it takes of the pane it splits (empty: half)
#   PaneBeside name of the pane of the group to split (empty: the group's app); e.g. for a 2x2 layout
# The other editions ignore these fields and keep them when they edit an entry.
# ---------------------------------------------------------------------------------------------------------------------

# Group of an entry in the same folder, empty when none has one
# Usage: group_for_app_path "$json_file" "$app_path"
group_for_app_path() {
    [[ -f "$1" ]] || return 0
    jq -r --arg p "$2" '[.[] | select(.AppPath == $p and (.Group // "") != "") | .Group][0] // empty' "$1" | tr -d '\r'
}

# Name of the web app (an entry with a Type) in the same folder, empty when there is none
# Usage: app_name_for_app_path "$json_file" "$app_path"
app_name_for_app_path() {
    [[ -f "$1" ]] || return 0
    jq -r --arg p "$2" '[.[] | select(.AppPath == $p and (.Type // "") != "") | .Name][0] // empty' "$1" | tr -d '\r'
}

# Set the Group of an entry, by name
# Usage: set_app_group "$json_file" "$app_name" "$group"
set_app_group() {
    local existing=$(cat "$1")
    echo "$existing" | jq --arg name "$2" --arg group "$3" \
        'map(if (.Name | ascii_downcase) == ($name | ascii_downcase) then . + {Group: $group} else . end)' > "$1"
}

# Interactive: Group, PaneSide, PaneRatio and PaneBeside. An empty answer keeps the value shown; "-" clears it.
# Sets LAYOUT_GROUP, LAYOUT_SIDE, LAYOUT_RATIO and LAYOUT_BESIDE. The pane fields are asked only for an entry in a
# group, and PaneRatio/PaneBeside only with a PaneSide.
# Usage: prompt_layout_fields "$group" "$side" "$ratio" "$beside"
prompt_layout_fields() {
    local answer
    LAYOUT_GROUP="${1:-}"
    LAYOUT_SIDE="${2:-}"
    LAYOUT_RATIO="${3:-}"
    LAYOUT_BESIDE="${4:-}"
    
    read -r -p "Group (entries in one group share a tuios workspace; - for none) [$LAYOUT_GROUP]: " answer
    [[ "$answer" == "-" ]] && LAYOUT_GROUP="" || LAYOUT_GROUP="${answer:-$LAYOUT_GROUP}"
    if [[ -z "$LAYOUT_GROUP" ]]; then
        LAYOUT_SIDE=""
        LAYOUT_RATIO=""
        LAYOUT_BESIDE=""
        return 0
    fi
    
    while true; do
        read -r -p "PaneSide beside the group's app (left/right/up/down; - for none, as for the app itself) [$LAYOUT_SIDE]: " answer
        [[ "$answer" == "-" ]] && answer="" || answer="${answer:-$LAYOUT_SIDE}"
        answer="${answer,,}"
        if [[ -z "$answer" || "$answer" =~ ^(left|right|up|down)$ ]]; then
            LAYOUT_SIDE="$answer"
            break
        fi
        echo -e "${YELLOW}PaneSide must be left, right, up or down${NC}" >&2
    done
    if [[ -z "$LAYOUT_SIDE" ]]; then
        LAYOUT_RATIO=""
        LAYOUT_BESIDE=""
        return 0
    fi
    
    while true; do
        read -r -p "PaneRatio (percent of the pane it splits, 1-99; - for half) [$LAYOUT_RATIO]: " answer
        [[ "$answer" == "-" ]] && answer="" || answer="${answer:-$LAYOUT_RATIO}"
        if [[ -z "$answer" ]] || [[ "$answer" =~ ^[0-9]+$ && "$answer" -ge 1 && "$answer" -le 99 ]]; then
            LAYOUT_RATIO="$answer"
            break
        fi
        echo -e "${YELLOW}PaneRatio must be a whole number from 1 to 99${NC}" >&2
    done
    
    read -r -p "PaneBeside (name of the group's pane to split, e.g. for 2x2; - for the group's app) [$LAYOUT_BESIDE]: " answer
    [[ "$answer" == "-" ]] && LAYOUT_BESIDE="" || LAYOUT_BESIDE="${answer:-$LAYOUT_BESIDE}"
}

# Add the layout fields that are set to an entry
# Usage: add_layout_fields "$app_json" "$group" "$side" "$ratio" "$beside"
add_layout_fields() {
    echo "$1" | jq --arg group "${2:-}" --arg side "${3:-}" --arg ratio "${4:-}" --arg beside "${5:-}" '
        . + (if $group != "" then {Group: $group} else {} end)
          + (if $side != "" then {PaneSide: $side} else {} end)
          + (if $ratio != "" then {PaneRatio: ($ratio | tonumber)} else {} end)
          + (if $beside != "" then {PaneBeside: $beside} else {} end)'
}
