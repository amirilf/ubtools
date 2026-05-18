#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/.config"
CURRENT_FILE="$SCRIPT_DIR/.current"

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; NC='\033[0m'
die()  { echo -e "${RED}error: $*${NC}" >&2; exit 1; }
info() { echo -e "${GRN}$*${NC}"; }
warn() { echo -e "${YLW}warn: $*${NC}" >&2; }

command -v fzf      >/dev/null || die "fzf required — sudo apt install fzf"
command -v gsettings >/dev/null || die "gsettings required (GNOME desktop)"

touch "$CONFIG_FILE" 2>/dev/null || true
chmod 600 "$CONFIG_FILE"

# --- Config helpers ---
_list_profiles() { grep '^\[' "$CONFIG_FILE" 2>/dev/null | tr -d '[]'; }

_get_field() {
    local profile="$1" field="$2" in_section=0
    while IFS= read -r line; do
        [[ "$line" == "[$profile]" ]] && { in_section=1; continue; }
        [[ "$line" =~ ^\[.*\] ]] && in_section=0
        [[ "$in_section" -eq 1 && "$line" =~ ^$field= ]] && { echo "${line#"$field"=}"; return; }
    done < "$CONFIG_FILE"
}

_profile_exists() { grep -q "^\[$1\]" "$CONFIG_FILE" 2>/dev/null; }

_current() { [[ -f "$CURRENT_FILE" ]] && cat "$CURRENT_FILE" || echo ""; }

_delete_profile() {
    local name="$1" tmp in_section=0
    tmp=$(mktemp)
    while IFS= read -r line; do
        [[ "$line" == "[$name]" ]] && { in_section=1; continue; }
        [[ "$line" =~ ^\[.*\] ]] && in_section=0
        [[ "$in_section" -eq 0 ]] && echo "$line"
    done < "$CONFIG_FILE" > "$tmp"
    mv "$tmp" "$CONFIG_FILE"
}

_validate_host_port() {
    local val="$1" label="$2"
    [[ "$val" =~ ^[^:]+:[0-9]+$ ]] || die "$label must be host:port (e.g. 192.168.1.1:8080)"
    local port="${val##*:}"
    [[ "$port" -ge 1 && "$port" -le 65535 ]] 2>/dev/null || die "invalid port in $label: $port"
}

# --- Apply profile ---
_apply() {
    local profile="$1"
    if [[ "$profile" == "off" ]]; then
        gsettings set org.gnome.system.proxy mode 'none'
        echo "off" > "$CURRENT_FILE"
        info "Proxy disabled."
        return
    fi

    _profile_exists "$profile" || die "profile not found: $profile"

    local http https ignore
    http=$(_get_field "$profile" "http")
    https=$(_get_field "$profile" "https")
    ignore=$(_get_field "$profile" "ignore")

    [[ -n "$http" ]] || die "profile '$profile' is missing 'http' field"

    local hh hp; hh="${http%:*}"; hp="${http##*:}"
    gsettings set org.gnome.system.proxy mode 'manual'
    gsettings set org.gnome.system.proxy.http host  "$hh"
    gsettings set org.gnome.system.proxy.http port  "$hp"

    if [[ -n "$https" ]]; then
        local sh sp; sh="${https%:*}"; sp="${https##*:}"
        gsettings set org.gnome.system.proxy.https host "$sh"
        gsettings set org.gnome.system.proxy.https port "$sp"
    fi

    if [[ -n "$ignore" ]]; then
        local arr="["; IFS=',' read -ra items <<< "$ignore"
        for item in "${items[@]}"; do arr+="'${item// /}',"; done
        arr="${arr%,}]"
        gsettings set org.gnome.system.proxy ignore-hosts "$arr"
    fi

    echo "$profile" > "$CURRENT_FILE"
    info "Active: $profile  ($http)"
}

# --- Default: fzf picker ---
_pick() {
    local current; current=$(_current)
    local profiles; profiles=$(_list_profiles 2>/dev/null || true)

    local rows=()
    local off_m="·"; [[ -z "$current" || "$current" == "off" ]] && off_m="*"
    rows+=("$(printf '%s  %-18s  %s' "$off_m" "off" "— disable proxy")")

    if [[ -n "$profiles" ]]; then
        while IFS= read -r p; do
            local http; http=$(_get_field "$p" "http")
            local m="·"; [[ "$p" == "$current" ]] && m="*"
            rows+=("$(printf '%s  %-18s  %s' "$m" "$p" "$http")")
        done <<< "$profiles"
    fi

    local sel
    sel=$(printf '%s\n' "${rows[@]}" | fzf \
        --prompt="Proxy > " \
        --header="Select profile to activate   * = current   |   px add / drop / edit" \
        --height=~60% --border --no-sort) || return
    [[ -z "$sel" ]] && return

    local chosen; chosen=$(awk '{print $2}' <<< "$sel")
    _apply "$chosen"
}

# --- Add profile ---
_add() {
    local name
    read -rp "Profile name: " name
    [[ -n "$name" ]] || die "name cannot be empty"
    [[ "$name" == "off" ]] && die "'off' is reserved"
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || die "name must be alphanumeric (a-z, 0-9, _, -)"

    if _profile_exists "$name"; then
        warn "Profile '$name' already exists."
        local ow; read -rp "Overwrite? [y/N]: " ow
        [[ "$ow" =~ ^[Yy]$ ]] || { echo "Aborted."; return; }
        _delete_profile "$name"
    fi

    local http https ignore
    read -rp "HTTP  (host:port): " http
    _validate_host_port "$http" "HTTP"
    read -rp "HTTPS (host:port, blank = same as http): " https
    [[ -z "$https" ]] && https="$http" || _validate_host_port "$https" "HTTPS"
    read -rp "Ignore hosts (comma-separated, blank = default): " ignore
    [[ -z "$ignore" ]] && ignore="localhost,127.0.0.1,::1"

    { echo "[$name]"; echo "http=$http"; echo "https=$https"; echo "ignore=$ignore"; echo ""; } >> "$CONFIG_FILE"
    info "Added: $name"
}

# --- Drop profile ---
_drop() {
    local profiles; profiles=$(_list_profiles 2>/dev/null || true)
    [[ -z "$profiles" ]] && { warn "No profiles."; return; }
    local sel
    sel=$(echo "$profiles" | fzf \
        --prompt="Drop > " \
        --header="Select profile to remove" \
        --height=~40% --border) || return
    [[ -z "$sel" ]] && return
    local c; read -rp "Remove '$sel'? [y/N]: " c
    [[ "$c" =~ ^[Yy]$ ]] || { echo "Aborted."; return; }
    _delete_profile "$sel"
    local current; current=$(_current)
    if [[ "$current" == "$sel" ]]; then
        gsettings set org.gnome.system.proxy mode 'none'
        rm -f "$CURRENT_FILE"
        warn "Was active — proxy disabled."
    fi
    info "Removed: $sel"
}

# --- Edit profile ---
_edit() {
    local profiles; profiles=$(_list_profiles 2>/dev/null || true)
    [[ -z "$profiles" ]] && { warn "No profiles."; return; }
    local sel
    sel=$(echo "$profiles" | fzf \
        --prompt="Edit > " \
        --header="Select profile to edit" \
        --height=~40% --border) || return
    [[ -z "$sel" ]] && return

    local ohttp ohttps oignore
    ohttp=$(_get_field "$sel" "http")
    ohttps=$(_get_field "$sel" "https")
    oignore=$(_get_field "$sel" "ignore")

    echo "Editing: $sel   (blank = keep current)"
    local nhttp nhttps nignore
    read -rp "HTTP  [$ohttp]: " nhttp;    nhttp="${nhttp:-$ohttp}"
    read -rp "HTTPS [$ohttps]: " nhttps;  nhttps="${nhttps:-$ohttps}"
    read -rp "Ignore [$oignore]: " nignore; nignore="${nignore:-$oignore}"

    _validate_host_port "$nhttp" "HTTP"
    _validate_host_port "$nhttps" "HTTPS"

    _delete_profile "$sel"
    { echo "[$sel]"; echo "http=$nhttp"; echo "https=$nhttps"; echo "ignore=$nignore"; echo ""; } >> "$CONFIG_FILE"

    local current; current=$(_current)
    [[ "$current" == "$sel" ]] && _apply "$sel"
    info "Updated: $sel"
}

# --- Status ---
_status() {
    local current; current=$(_current)
    local mode; mode=$(gsettings get org.gnome.system.proxy mode 2>/dev/null || echo "'none'")
    if [[ "$mode" == "'none'" || -z "$current" || "$current" == "off" ]]; then
        echo "Proxy: off"
    else
        local http; http=$(_get_field "$current" "http" 2>/dev/null || echo "?")
        echo "Proxy: $current  ($http)"
    fi
}

# --- Help ---
_help() {
    cat <<'EOF'

  px — GNOME proxy switcher

  USAGE
    px              open fzf panel: navigate profiles, Enter to activate
    px add          add a new proxy profile
    px drop         fzf picker to remove a profile
    px edit         fzf picker to edit a profile
    px off          disable proxy immediately
    px status       show current proxy state
    px --help       show this help

  CONFIG FILE
    Stored at:  ~/.ubtools/proxy/.config  (plain INI, not committed)

  PROFILE FORMAT
    [profile-name]
    http=host:port
    https=host:port
    ignore=localhost,127.0.0.1,::1

  DEPENDENCIES
    fzf  gsettings (GNOME)

EOF
}

# --- Main ---
case "${1:-}" in
    add)    _add ;;
    drop)   _drop ;;
    edit)   _edit ;;
    off)    _apply "off" ;;
    status) _status ;;
    --help) _help ;;
    *)      _pick ;;
esac
