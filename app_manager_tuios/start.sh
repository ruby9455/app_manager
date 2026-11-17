#!/usr/bin/env bash
#
# start.sh - Quick start helper for app manager
#
# This script provides quick access to common operations.
# Default mode launches both the interactive manager and landing page server side by side in a tuios session.
#
# USAGE
#   ./start.sh              # Start manager and landing page in tuios panes
#   ./start.sh all          # Start all apps
#   ./start.sh attach       # Attach to tuios session
#   ./start.sh stop         # Stop all apps
#   ./start.sh list         # List tuios windows
#   ./start.sh manager      # Start only the manager (interactive)
#   ./start.sh landing      # Start only the landing page server
#   ./start.sh help         # Show this help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
BLUE='\033[0;34m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

show_help() {
    echo "App Manager - Quick Start"
    echo ""
    echo "Usage: $(basename "$0") [command]"
    echo ""
    echo "Commands:"
    echo "  (none)    Start manager and landing page (default)"
    echo "  all       Start all apps immediately"
    echo "  attach    Attach to tuios session"
    echo "  stop      Stop all running apps"
    echo "  list      List tuios windows"
    echo "  manager   Start only the interactive manager"
    echo "  landing   Start only the landing page server"
    echo "  help      Show this help"
    echo ""
}

case "${1:-}" in
    all)
        echo -e "${CYAN}Starting all apps...${NC}"
        "$SCRIPT_DIR/manager.sh" --all
        ;;
    attach|a)
        echo -e "${CYAN}Attaching to tuios session...${NC}"
        "$SCRIPT_DIR/manager.sh" --attach
        ;;
    stop|s)
        echo -e "${CYAN}Stopping all apps...${NC}"
        source "$SCRIPT_DIR/lib/config.sh"
        source "$SCRIPT_DIR/lib/tuios_helpers.sh"
        tuios_kill_all_windows
        ;;
    list|l)
        source "$SCRIPT_DIR/lib/config.sh"
        source "$SCRIPT_DIR/lib/tuios_helpers.sh"
        tuios_list_windows
        ;;
    manager)
        echo -e "${CYAN}Starting interactive manager...${NC}"
        "$SCRIPT_DIR/manager.sh"
        ;;
    landing)
        echo -e "${CYAN}Starting landing page server on port 1111...${NC}"
        "$SCRIPT_DIR/landing_page.sh"
        ;;
    help|h|-h|--help)
        show_help
        ;;
    "")
        # Default: launch both manager and landing page side by side in a tuios session
        echo -e "${CYAN}Launching App Manager with Landing Page...${NC}"
        
        # Source config to get URL detection
        source "$SCRIPT_DIR/lib/config.sh"
        source "$SCRIPT_DIR/lib/url_helpers.sh"
        source "$SCRIPT_DIR/lib/tuios_helpers.sh"
        
        # Detect network URLs
        NETWORK_URL=$(get_network_url_prefix)
        EXTERNAL_URL=$(get_external_url_prefix)
        
        echo -e "${BLUE}Network configuration:${NC}"
        echo -e "  ${CYAN}Network:${NC}  ${NETWORK_URL}:1111${NC}"
        echo -e "  ${CYAN}External:${NC} ${EXTERNAL_URL}:1111${NC}"
        echo ""
        
        # Check if tuios is available
        if ! tuios_available; then
            echo -e "${YELLOW}tuios is not installed. Running manager and landing page sequentially.${NC}"
            echo -e "${CYAN}To use panes, install tuios: brew install tuios (or see https://github.com/Gaurav-Gosain/tuios)${NC}"
            
            # Run landing page in background, manager in foreground
            "$SCRIPT_DIR/landing_page.sh" &
            LANDING_PID=$!
            
            trap "kill $LANDING_PID 2>/dev/null || true" EXIT
            
            echo -e "${GREEN}Landing page server started in background (PID: $LANDING_PID)${NC}"
            echo -e "${GREEN}Starting interactive manager...${NC}"
            "$SCRIPT_DIR/manager.sh"
            
            kill $LANDING_PID 2>/dev/null || true
        else
            # Create a new tuios session with two panes
            SESSION_NAME="app-manager-$(date +%s)"
            
            # Create the session headless; it opens with one shell window, closed below
            tuios_cmd new "$SESSION_NAME" --detach --cwd "$SCRIPT_DIR" >/dev/null
            first_ids=$(tuios_cmd list-windows -s "$SESSION_NAME" --json 2>/dev/null | jq -r '.windows[]?.window_id' 2>/dev/null || true)
            
            # Manager in the first pane, landing page beside it (new panes are tiled)
            manager_id=$(tuios_cmd new-window -s "$SESSION_NAME" manager --cwd "$SCRIPT_DIR" --print-id -- "$SCRIPT_DIR/manager.sh")
            tuios_cmd new-window -s "$SESSION_NAME" landing --cwd "$SCRIPT_DIR" --no-focus -- "$SCRIPT_DIR/landing_page.sh" >/dev/null
            for id in $first_ids; do
                tuios_cmd close-window -s "$SESSION_NAME" "$id" >/dev/null 2>&1 || true
            done
            [[ -n "$manager_id" ]] && tuios_cmd focus-window -s "$SESSION_NAME" "$manager_id" >/dev/null 2>&1 || true
            
            # Attach to the session (switch to it when already inside tuios)
            if is_in_tuios; then
                tuios_cmd switch-session "$SESSION_NAME"
            else
                tuios_cmd attach "$SESSION_NAME"
            fi
        fi
        ;;
    *)
        # Try to start app by name
        echo -e "${CYAN}Starting app: $1${NC}"
        "$SCRIPT_DIR/manager.sh" --app "$1"
        ;;
esac
