#!/usr/bin/env bash
set -euo pipefail

UBTOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASHRC="$HOME/.bashrc"

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; BLD='\033[1m'; NC='\033[0m'
die()  { echo -e "${RED}error: $*${NC}" >&2; exit 1; }
info() { echo -e "${GRN}$*${NC}"; }
warn() { echo -e "${YLW}$*${NC}" >&2; }

if [[ "${1:-}" == "--help" ]]; then
    cat <<'EOF'

  install.sh — ubtools interactive installer

  USAGE
    bash install.sh       launch fzf tool picker and install
    bash install.sh --help  show this help

  WHAT IT DOES
    1. Lets you pick a tool via fzf (✓ = already in ~/.bashrc)
    2. Checks and installs missing system dependencies (apt)
    3. Adds the alias / source line to ~/.bashrc
    4. Shows post-install notes
    5. Asks if you want to install another tool

  TOOLS
    ath     TOTP authenticator (encrypted vault)
    bumper  Maven version bumper
    proxy   GNOME proxy switcher  (command: px)
    mvn     Smart Maven wrapper

EOF
    exit 0
fi

# Install fzf if needed (required by the installer itself)
if ! command -v fzf >/dev/null; then
    warn "fzf is not installed (required for this installer)."
    read -rp "Install fzf now? [Y/n]: " yn
    [[ "$yn" =~ ^[Nn]$ ]] && die "fzf required — sudo apt install fzf"
    sudo apt install -y fzf
fi

declare -A TOOL_DESC=(
    [ath]="TOTP authenticator — encrypted secrets, fzf picker, export/import"
    [bumper]="Maven version bumper — branch picker, semver bump, git commit"
    [proxy]="GNOME proxy switcher — fzf profiles, add/drop/edit"
    [mvn]="Smart Maven wrapper — Java auto-switch, wrapper generator, tab completion"
)

declare -A TOOL_CMDS=(
    [ath]="oathtool fzf openssl"
    [bumper]="fzf git"
    [proxy]="fzf gsettings"
    [mvn]="curl"
)

declare -A TOOL_APT=(
    [ath]="oathtool fzf openssl"
    [bumper]="fzf"
    [proxy]="fzf"
    [mvn]="curl java-common"
)

declare -A TOOL_SCRIPT=(
    [ath]="ath/ath.sh"
    [bumper]="bumper/bumper.sh"
    [proxy]="proxy/px.sh"
    [mvn]="mvn/mvn.sh"
)

declare -A TOOL_BASHRC=(
    [ath]="alias ath=\"$UBTOOLS_DIR/ath/ath.sh\""
    [bumper]="alias bumper=\"$UBTOOLS_DIR/bumper/bumper.sh\""
    [proxy]="alias px=\"$UBTOOLS_DIR/proxy/px.sh\""
    [mvn]="source \"$UBTOOLS_DIR/mvn/mvn.sh\""
)

_is_installed() {
    # Match on script filename only — works whether bashrc uses $HOME or /home/user
    case "$1" in
        ath)    grep -qF "ath/ath.sh"       "$BASHRC" 2>/dev/null ;;
        bumper) grep -qF "bumper/bumper.sh"  "$BASHRC" 2>/dev/null ;;
        proxy)  grep -qF "proxy/px.sh"      "$BASHRC" 2>/dev/null ;;
        mvn)    grep -qF "mvn/mvn.sh"       "$BASHRC" 2>/dev/null ;;
    esac
}

_install_tool() {
    local tool="$1"
    local script="$UBTOOLS_DIR/${TOOL_SCRIPT[$tool]}"

    echo ""
    echo -e "${BLD}═══ $tool ═══${NC}"

    # Verify script exists
    [[ -f "$script" ]] || die "script not found: $script"
    chmod +x "$script"

    # Check and install system dependencies
    local missing=()
    for cmd in ${TOOL_CMDS[$tool]}; do
        command -v "$cmd" >/dev/null || missing+=("$cmd")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Missing: ${missing[*]}"
        local apt_pkgs="${TOOL_APT[$tool]}"
        read -rp "Run: sudo apt install $apt_pkgs ? [Y/n]: " yn
        [[ "$yn" =~ ^[Nn]$ ]] || sudo apt install -y $apt_pkgs
    else
        info "Dependencies: all present"
    fi

    # Add to ~/.bashrc
    local line="${TOOL_BASHRC[$tool]}"
    if _is_installed "$tool"; then
        info "~/.bashrc: already configured"
    else
        if ! grep -qF "# ubtools" "$BASHRC" 2>/dev/null; then
            echo "" >> "$BASHRC"
            echo "# ubtools" >> "$BASHRC"
        fi
        echo "$line" >> "$BASHRC"
        info "~/.bashrc: updated"
    fi

    # Post-install notes
    case "$tool" in
        ath)
            info "Run 'ath' once to set your passphrase and initialize the vault."
            info "Then add entries with: ath add"
            ;;
        proxy)
            info "Add your first proxy profile: px add"
            ;;
        mvn)
            info "Install any JDKs you need, e.g.:"
            info "  sudo apt install openjdk-17-jdk openjdk-21-jdk"
            ;;
        bumper)
            info "Run 'bumper' from any Maven project root."
            ;;
    esac

    info "Done: $tool installed."
}

# ─── Main loop ───
echo ""
echo -e "${BLD}  ubtools installer${NC}"
echo -e "  ─────────────────"
echo ""

while true; do
    local_rows=()
    for t in ath bumper proxy mvn; do
        _is_installed "$t" && tag="✓" || tag="○"
        local_rows+=("$(printf '%s  %-8s  %s' "$tag" "$t" "${TOOL_DESC[$t]}")")
    done

    sel=$(printf '%s\n' "${local_rows[@]}" | fzf \
        --prompt="Install > " \
        --header="Select a tool to install   ✓ = already in ~/.bashrc" \
        --height=~50% --border --no-sort) || break
    [[ -z "$sel" ]] && break

    chosen=$(awk '{print $2}' <<< "$sel")
    _install_tool "$chosen"

    echo ""
    read -rp "Install another tool? [y/N]: " more
    [[ "$more" =~ ^[Yy]$ ]] || break
done

echo ""
info "All done. Reload your shell: source ~/.bashrc"
