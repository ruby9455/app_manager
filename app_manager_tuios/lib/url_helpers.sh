#!/usr/bin/env bash
#
# lib/url_helpers.sh - URL prefix detection utilities for Linux and macOS
#
# Source this file to use the functions:
#   source "$(dirname "${BASH_SOURCE[0]}")/url_helpers.sh"
#

# Get the primary local IPv4 address
# Usage: get_network_url_prefix
# Returns: URL like "http://192.168.1.10"
get_network_url_prefix() {
    local ip=""
    
    # Linux: IP of the default route interface
    if command -v ip &>/dev/null; then
        local default_iface=$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')
        if [[ -n "$default_iface" ]]; then
            ip=$(ip -4 addr show "$default_iface" 2>/dev/null | awk '/inet / {sub(/\/.*/, "", $2); print $2; exit}')
        fi
    fi
    
    # macOS: IP of the default route interface
    if [[ -z "$ip" ]] && command -v route &>/dev/null && command -v ipconfig &>/dev/null; then
        local default_iface=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2; exit}')
        if [[ -n "$default_iface" ]]; then
            ip=$(ipconfig getifaddr "$default_iface" 2>/dev/null)
        fi
    fi
    
    # Fallback: get any non-loopback IPv4
    if [[ -z "$ip" ]]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    
    # Fallback to the configured URL
    if [[ -z "$ip" ]]; then
        echo "$DEFAULT_NETWORK_URL_FALLBACK"
        return 0
    fi
    
    echo "http://$ip"
}

# Get external/public IP address
# Usage: get_external_url_prefix [timeout_sec]
# Returns: URL like "http://203.0.113.10"
get_external_url_prefix() {
    local timeout="${1:-5}"
    local services=(
        "https://api.ipify.org?format=text"
        "https://ifconfig.me/ip"
        "https://icanhazip.com"
    )
    
    for service in "${services[@]}"; do
        local ip=""
        if command -v curl &>/dev/null; then
            ip=$(curl -s --connect-timeout "$timeout" --max-time "$timeout" --noproxy "*" "$service" 2>/dev/null)
        elif command -v wget &>/dev/null; then
            ip=$(wget -qO- --timeout="$timeout" --no-proxy "$service" 2>/dev/null)
        fi
        
        # Validate it looks like an IP
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "http://$ip"
            return 0
        fi
    done
    
    # Fallback to the configured URL, else the network URL
    if [[ -n "${APP_MGMT_EXTERNAL_URL:-}" ]]; then
        echo "$APP_MGMT_EXTERNAL_URL"
        return 0
    fi
    get_network_url_prefix
}

# Get generic URL prefix (localhost)
# Usage: get_generic_url_prefix
get_generic_url_prefix() {
    echo "http://localhost"
}

# Build full URL for an app
# Usage: build_app_url "$base_url" "$port" "$base_path"
build_app_url() {
    local base_url="$1"
    local port="$2"
    local base_path="${3:-}"
    
    local url="${base_url}:${port}"
    
    if [[ -n "$base_path" ]]; then
        # Remove leading slash if present, then add it
        base_path="${base_path#/}"
        url="${url}/${base_path}"
    fi
    
    echo "$url"
}

# Get the correct access URL for an app, accounting for nginx reverse proxy.
# Apps with "NginxPath" set are served via nginx at base_url/nginx_path/ (no port).
# Apps without "NginxPath" are served directly at base_url:port.
# Usage: get_app_access_url "$app_json" "$base_url"
# Example: get_app_access_url "$app" "http://192.168.1.10"
get_app_access_url() {
    local app_json="$1"
    local base_url="$2"
    local nginx_path=$(echo "$app_json" | jq -r '.NginxPath // empty')
    local port=$(echo "$app_json" | jq -r '.Port // empty')
    local base_path=$(echo "$app_json" | jq -r '.BasePath // empty')

    if [[ -n "$nginx_path" ]]; then
        echo "${base_url}/${nginx_path}/"
    else
        local url="${base_url}:${port}"
        if [[ -n "$base_path" ]]; then
            base_path="${base_path#/}"
            url="${url}/${base_path}"
        fi
        echo "$url"
    fi
}
