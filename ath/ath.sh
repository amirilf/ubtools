#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_FILE="$SCRIPT_DIR/.secrets"
chmod 700 "$SCRIPT_DIR" 2>/dev/null || true

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; NC='\033[0m'
die()  { echo -e "${RED}error: $*${NC}" >&2; exit 1; }
info() { echo -e "${GRN}$*${NC}"; }
warn() { echo -e "${YLW}warn: $*${NC}" >&2; }

for _c in oathtool fzf openssl; do
    command -v "$_c" >/dev/null || die "$_c required — sudo apt install $_c"
done; unset _c

if   command -v xclip   >/dev/null; then CLIP=(xclip -selection clipboard)
elif command -v xsel    >/dev/null; then CLIP=(xsel --clipboard --input)
elif command -v wl-copy >/dev/null; then CLIP=(wl-copy)
else die "no clipboard tool — install xclip, xsel, or wl-clipboard"
fi

# Passphrase is never placed on the command line — passed to openssl via fd
PASSPHRASE=""
_ask_pass() { read -rsp "${1:-ath passphrase: }" PASSPHRASE; echo >&2; [[ -n "$PASSPHRASE" ]] || die "passphrase cannot be empty"; }
_dec_pass() { openssl enc -aes-256-cbc -pbkdf2 -d -in "$1" -pass fd:3 3<<< "$2" 2>/dev/null; }
_enc_pass() { openssl enc -aes-256-cbc -pbkdf2 -e -in "$1" -out "$2" -pass fd:3 3<<< "$3"; }
_dec()      { _dec_pass "$1" "$PASSPHRASE"; }
_enc()      { _enc_pass "$1" "$2" "$PASSPHRASE"; }

# First-run: create encrypted secrets file
_init() {
    [[ -f "$SECRETS_FILE" ]] && return
    warn "First run — set your ath passphrase."
    local p1 p2
    read -rsp "New passphrase: " p1; echo >&2
    read -rsp "Confirm:        " p2; echo >&2
    [[ "$p1" == "$p2" ]] || die "passphrases do not match"
    [[ -n "$p1" ]] || die "passphrase cannot be empty"
    PASSPHRASE="$p1"
    SECRETS=()
    _save
    info "Passphrase set. Add your first entry: ath add"
    exit 0
}

# Secrets array — lines stored as: service|username|secret
SECRETS=()

_load() {
    local raw; raw=$(_dec "$SECRETS_FILE") || die "wrong passphrase or corrupted file"
    mapfile -t SECRETS <<< "$raw"
    local clean=()
    for _l in "${SECRETS[@]+"${SECRETS[@]}"}"; do [[ -n "$_l" ]] && clean+=("$_l"); done
    SECRETS=("${clean[@]+"${clean[@]}"}"); unset clean _l
}

_save() {
    local tmp; tmp=$(mktemp)
    printf '%s\n' "${SECRETS[@]+"${SECRETS[@]}"}" > "$tmp"
    _enc "$tmp" "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
    rm -f "$tmp"
}

_find_entry() {
    local s="$1" u="$2"
    for _l in "${SECRETS[@]+"${SECRETS[@]}"}"; do
        local ls lu; IFS='|' read -r ls lu _ <<< "$_l"
        [[ "$ls" == "$s" && "$lu" == "$u" ]] && { echo "$_l"; return; }
    done
}

_list_indexed() {
    local i=0
    for _l in "${SECRETS[@]+"${SECRETS[@]}"}"; do
        local s u; IFS='|' read -r s u _ <<< "$_l"
        printf '%3d  %-25s  %s\n' $((++i)) "$s" "$u"
    done
}

# --- Default: interactive TOTP picker ---
_pick() {
    local secs=$(( 30 - $(date +%S) % 30 )) rows=()
    for _l in "${SECRETS[@]+"${SECRETS[@]}"}"; do
        local s u sec; IFS='|' read -r s u sec <<< "$_l"
        local code; code=$(oathtool --totp -b "$sec" 2>/dev/null) || { warn "bad secret for $s/$u — skipping"; continue; }
        rows+=("$(printf '%-24s  %-24s  %s' "$s" "$u" "$code")")
    done
    [[ ${#rows[@]} -eq 0 ]] && { warn "No entries. Run: ath add"; return; }
    local sel
    sel=$(printf '%s\n' "${rows[@]}" | fzf \
        --prompt="TOTP > " \
        --header="↑↓ navigate   Enter = copy code   |   codes refresh in ${secs}s" \
        --height=~80% --border --no-sort) || return
    [[ -z "$sel" ]] && return
    local code; code=$(awk '{print $NF}' <<< "$sel")
    echo "$code" | "${CLIP[@]}"
    echo "Copied: $code"
}

# --- Add entry ---
_add() {
    local svc usr sec
    read -rp "Service:  " svc
    [[ -n "$svc" ]] || die "service cannot be empty"
    [[ "$svc" == *'|'* ]] && die "service name cannot contain '|'"
    read -rp "Username: " usr
    [[ -n "$usr" ]] || die "username cannot be empty"
    [[ "$usr" == *'|'* ]] && die "username cannot contain '|'"

    if [[ -n "$(_find_entry "$svc" "$usr")" ]]; then
        warn "Entry already exists: $svc / $usr"
        local ow; read -rp "Overwrite? [y/N]: " ow
        [[ "$ow" =~ ^[Yy]$ ]] || { echo "Aborted."; return; }
        local keep=()
        for _l in "${SECRETS[@]+"${SECRETS[@]}"}"; do
            local s u; IFS='|' read -r s u _ <<< "$_l"
            [[ "$s" == "$svc" && "$u" == "$usr" ]] && continue
            keep+=("$_l")
        done
        SECRETS=("${keep[@]+"${keep[@]}"}")
    fi

    read -rsp "Base32 secret: " sec; echo
    [[ -n "$sec" ]] || die "secret cannot be empty"
    oathtool --totp -b "$sec" &>/dev/null || die "invalid Base32 secret — check your key"

    SECRETS+=("$svc|$usr|$sec")
    _save
    info "Added: $svc / $usr"
}

# --- Drop entry ---
_drop() {
    [[ ${#SECRETS[@]} -eq 0 ]] && { warn "No entries."; return; }
    local sel
    sel=$(_list_indexed | fzf \
        --prompt="Drop > " \
        --header="Select entry to remove" \
        --height=~50% --border) || return
    [[ -z "$sel" ]] && return
    local idx; idx=$(awk '{print $1}' <<< "$sel")
    local line="${SECRETS[$((idx-1))]}"
    local s u; IFS='|' read -r s u _ <<< "$line"
    local c; read -rp "Remove $s / $u? [y/N]: " c
    [[ "$c" =~ ^[Yy]$ ]] || { echo "Aborted."; return; }
    local keep=()
    for _l in "${SECRETS[@]+"${SECRETS[@]}"}"; do [[ "$_l" != "$line" ]] && keep+=("$_l"); done
    SECRETS=("${keep[@]+"${keep[@]}"}"); _save; info "Removed: $s / $u"
}

# --- Edit entry ---
_edit() {
    [[ ${#SECRETS[@]} -eq 0 ]] && { warn "No entries."; return; }
    local sel
    sel=$(_list_indexed | fzf \
        --prompt="Edit > " \
        --header="Select entry to edit" \
        --height=~50% --border) || return
    [[ -z "$sel" ]] && return
    local idx; idx=$(awk '{print $1}' <<< "$sel")
    local orig="${SECRETS[$((idx-1))]}"
    local os ou osec; IFS='|' read -r os ou osec <<< "$orig"

    echo "Editing: $os / $ou   (blank = keep current)"
    local ns nu nsec
    read -rp "Service  [$os]: " ns;  ns="${ns:-$os}"
    read -rp "Username [$ou]: " nu; nu="${nu:-$ou}"
    read -rsp "Secret (hidden, blank = keep): " nsec; echo
    nsec="${nsec:-$osec}"

    [[ "$ns" == *'|'* || "$nu" == *'|'* ]] && die "fields cannot contain '|'"
    oathtool --totp -b "$nsec" &>/dev/null || die "invalid Base32 secret"

    if [[ "$ns|$nu" != "$os|$ou" ]] && [[ -n "$(_find_entry "$ns" "$nu")" ]]; then
        die "entry already exists: $ns / $nu"
    fi

    local keep=()
    for _l in "${SECRETS[@]+"${SECRETS[@]}"}"; do [[ "$_l" != "$orig" ]] && keep+=("$_l"); done
    keep+=("$ns|$nu|$nsec"); SECRETS=("${keep[@]}"); _save; info "Updated: $ns / $nu"
}

# --- Export encrypted backup ---
_export() {
    local out="${1:-}"
    [[ -z "$out" ]] && { read -rp "Export path (file or dir): " out; out="${out/#\~/$HOME}"; }
    [[ -n "$out" ]] || die "output path required"
    out="${out/#\~/$HOME}"
    # If a directory was given, auto-name the file inside it
    [[ -d "$out" ]] && out="$out/ath-backup-$(date +%Y%m%d).enc"
    [[ -d "$(dirname "$out")" ]] || die "directory not found: $(dirname "$out")"
    if [[ -f "$out" ]]; then
        local ow; read -rp "File exists: $out — Overwrite? [y/N]: " ow
        [[ "$ow" =~ ^[Yy]$ ]] || { echo "Aborted."; return; }
    fi
    local ep ep2
    read -rsp "Export passphrase (for the backup file): " ep; echo
    read -rsp "Confirm:                                  " ep2; echo
    [[ "$ep" == "$ep2" ]] || die "passphrases do not match"
    [[ -n "$ep" ]] || die "passphrase cannot be empty"
    local tmp; tmp=$(mktemp)
    printf '%s\n' "${SECRETS[@]+"${SECRETS[@]}"}" > "$tmp"
    _enc_pass "$tmp" "$out" "$ep"
    rm -f "$tmp"; chmod 600 "$out"
    info "Exported ${#SECRETS[@]} entries → $out"
}

# --- Import from encrypted backup ---
_import() {
    local src="${1:-}"
    [[ -z "$src" ]] && { read -rp "Import path: " src; src="${src/#\~/$HOME}"; }
    [[ -f "$src" ]] || die "file not found: $src"
    local ip; read -rsp "Import file passphrase: " ip; echo
    local raw; raw=$(_dec_pass "$src" "$ip") || die "wrong passphrase or corrupted file"
    local added=0 skipped=0 conflicted=0
    while IFS= read -r _l; do
        [[ -z "$_l" ]] && continue
        local s u sec; IFS='|' read -r s u sec <<< "$_l"
        local ex; ex=$(_find_entry "$s" "$u")
        if [[ -n "$ex" ]]; then
            local ex_sec; IFS='|' read -r _ _ ex_sec <<< "$ex"
            if [[ "$ex_sec" == "$sec" ]]; then
                ((skipped++)) || true
            else
                warn "CONFLICT: $s / $u — different secret, skipped"
                ((conflicted++)) || true
            fi
        else
            SECRETS+=("$_l")
            ((added++)) || true
        fi
    done <<< "$raw"
    [[ "$added" -gt 0 ]] && _save
    info "Done: +$added added, $skipped skipped, $conflicted conflicts"
}

# --- Change passphrase ---
_passwd() {
    local np np2
    info "Changing ath passphrase..."
    read -rsp "New passphrase: " np; echo
    read -rsp "Confirm:        " np2; echo
    [[ "$np" == "$np2" ]] || die "passphrases do not match"
    [[ -n "$np" ]] || die "passphrase cannot be empty"
    PASSPHRASE="$np"; _save; info "Passphrase updated."
}

# --- Help (no passphrase needed) ---
_help() {
    cat <<'EOF'

  ath — TOTP authenticator with encrypted vault

  USAGE
    ath               open fzf picker: navigate codes, Enter to copy
    ath add           add a new entry (loops until you stop)
    ath drop          fzf picker to remove an entry (loops)
    ath edit          fzf picker to edit an entry (loops)
    ath export [path] export an encrypted backup file
    ath import [path] import from an encrypted backup file
    ath passwd        change your ath passphrase
    ath --help        show this help

  SECRETS FILE
    Stored at:  ~/.ubtools/ath/.secrets
    Encrypted:  AES-256-CBC + PBKDF2 (openssl)
    Passphrase is required on every run — never stored on disk.

  ENTRY FORMAT
    service | username | Base32-secret
    Duplicates: same secret → skipped; different secret → rejected.

  EXPORT / IMPORT
    Backup files are encrypted with a separate passphrase.
    Safe to transfer between machines.
    ath export ~/backup.enc
    ath import ~/backup.enc

  DEPENDENCIES
    oathtool  fzf  openssl  xclip (or xsel / wl-copy)

EOF
}

# --- Main ---
cmd="${1:-}"

[[ "$cmd" == "--help" ]] && { _help; exit 0; }

_init

_ask_pass "ath passphrase: "
_load

case "$cmd" in
    add)
        while true; do
            _add
            read -rp "Add another? [y/N]: " _again; [[ "$_again" =~ ^[Yy]$ ]] || break
        done
        ;;
    drop)
        while true; do
            _drop
            [[ ${#SECRETS[@]} -eq 0 ]] && break
            read -rp "Drop another? [y/N]: " _again; [[ "$_again" =~ ^[Yy]$ ]] || break
        done
        ;;
    edit)
        while true; do
            _edit
            read -rp "Edit another? [y/N]: " _again; [[ "$_again" =~ ^[Yy]$ ]] || break
        done
        ;;
    export) _export "${2:-}" ;;
    import) _import "${2:-}" ;;
    passwd) _passwd ;;
    *)      _pick ;;
esac
