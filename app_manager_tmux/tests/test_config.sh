#!/usr/bin/env bash
#
# tests/test_config.sh - checks the apps.json lookup order in lib/config.sh
# Run: bash app_manager_tmux/tests/test_config.sh
#

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/config.sh"

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

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/scripts" "$tmp/config"
tmp=$(realpath "$tmp")
host=$(hostname -s 2>/dev/null || true)
host="${host:-${HOSTNAME%%.*}}"

unset APP_MANAGER_APPS_FILE
export APP_MANAGER_CONFIG_DIR="$tmp/config"
cd "$tmp/scripts"

echo '[]' > "$tmp/scripts/apps.json"
assert_eq "$tmp/scripts/apps.json" "$(get_apps_json_path "$tmp/scripts")" "falls back to apps.json next to the scripts"

mkdir -p "$tmp/config/machines/$host/tmux"
echo '[]' > "$tmp/config/machines/$host/tmux/apps.json"
assert_eq "$tmp/config/machines/$host/tmux/apps.json" "$(get_apps_json_path "$tmp/scripts")" "uses machines/<hostname>/tmux/apps.json when it exists"

echo '[]' > "$tmp/explicit.json"
export APP_MANAGER_APPS_FILE="$tmp/explicit.json"
assert_eq "$tmp/explicit.json" "$(get_apps_json_path "$tmp/scripts")" "APP_MANAGER_APPS_FILE overrides everything"

export APP_MANAGER_APPS_FILE="$tmp/missing.json"
if get_apps_json_path "$tmp/scripts" >/dev/null 2>&1; then
    assert_eq "error" "found" "missing APP_MANAGER_APPS_FILE is an error"
else
    assert_eq "error" "error" "missing APP_MANAGER_APPS_FILE is an error"
fi

exit $fail
