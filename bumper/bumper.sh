#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; BLD='\033[1m'; NC='\033[0m'
die() { echo -e "${RED}error: $1${NC}" >&2; exit 1; }

if [[ "${1:-}" == "--help" ]]; then
    cat <<'EOF'

  bumper — Maven version bumper

  USAGE
    bumper          interactive bump flow (run from Maven project root)
    bumper --help   show this help

  FLOW
    1. Branch picker  — fzf list of local branches (current at top)
                        select another to switch first (requires clean tree)
    2. Bump type      — choose major / minor / patch / none
    3. Commit confirm — commits: chore(pom): bump version to X.Y.Z

  VERSION FORMATS
    Supports X.Y.Z and X.Y.Z-SNAPSHOT.
    Bumping (major/minor/patch) removes the SNAPSHOT suffix.
    Choosing "none" keeps the version as-is.

  DEPENDENCIES
    fzf  git  awk

EOF
    exit 0
fi

command -v fzf >/dev/null || die "fzf required — sudo apt install fzf"
git rev-parse --git-dir > /dev/null 2>&1 || die "not a git repository"
[ -f "pom.xml" ] || die "no pom.xml found in current directory"

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

SELECTED_BRANCH=$({
    echo "$CURRENT_BRANCH"
    git branch --format='%(refname:short)' | grep -v "^${CURRENT_BRANCH}$"
} | fzf \
    --prompt="Branch > " \
    --header="Select branch for bump commit  |  current: ${CURRENT_BRANCH}" \
    --height=~50% \
    --border \
    --no-sort)

[ -z "$SELECTED_BRANCH" ] && { echo "Aborted."; exit 0; }

if [ "$SELECTED_BRANCH" != "$CURRENT_BRANCH" ]; then
    git diff-index --quiet HEAD -- 2>/dev/null || die "uncommitted changes — stash or commit first"
    echo -e "Switching to ${YLW}${SELECTED_BRANCH}${NC}..."
    git checkout "$SELECTED_BRANCH"
fi

CURRENT=$(awk '
    /<parent>/   { in_parent=1 }
    /<\/parent>/ { in_parent=0; next }
    in_parent    { next }
    /<version>/  { gsub(/.*<version>|<\/version>.*/, ""); gsub(/[[:space:]]/, ""); print; exit }
' pom.xml)

[ -n "$CURRENT" ] || die "could not read project version from pom.xml"

# Strip SNAPSHOT suffix for calculation
SNAPSHOT_SUFFIX=""
if [[ "$CURRENT" == *-SNAPSHOT ]]; then
    SNAPSHOT_SUFFIX="-SNAPSHOT"
    CURRENT="${CURRENT%-SNAPSHOT}"
fi

# Validate semver-like format
if ! [[ "$CURRENT" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    die "unsupported version format: '${CURRENT}${SNAPSHOT_SUFFIX}' — expected X.Y or X.Y.Z"
fi

IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"
PATCH="${PATCH:-0}"

POM_DIRTY=$(git diff -- pom.xml | grep -c '<version>' 2>/dev/null || true)

if [ "$POM_DIRTY" -gt 0 ]; then
    echo -e "${YLW}pom.xml already modified${NC} — skipping bump, will commit current state."
    NEW_VERSION="${CURRENT}${SNAPSHOT_SUFFIX}"
else
    FULL_CURRENT="${CURRENT}${SNAPSHOT_SUFFIX}"
    echo -e "\n${BLD}current version:${NC} ${YLW}${FULL_CURRENT}${NC}\n"
    echo -e "  1)  major  →  ${BLD}$((MAJOR + 1)).0.0${NC}"
    echo -e "  2)  minor  →  ${BLD}${MAJOR}.$((MINOR + 1)).0${NC}"
    echo -e "  3)  patch  →  ${BLD}${MAJOR}.${MINOR}.$((PATCH + 1))${NC}"
    echo -e "  4)  none   →  commit as-is  ${YLW}(${FULL_CURRENT})${NC}\n"

    read -rp "bump [1-4]: " CHOICE

    case $CHOICE in
        1) NEW_VERSION="$((MAJOR + 1)).0.0" ;;
        2) NEW_VERSION="${MAJOR}.$((MINOR + 1)).0" ;;
        3) NEW_VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))" ;;
        4) NEW_VERSION="$FULL_CURRENT" ;;
        *) die "invalid choice '$CHOICE'" ;;
    esac

    # Strip SNAPSHOT when actually bumping (keep it only on "none")
    [[ "$CHOICE" != "4" ]] && SNAPSHOT_SUFFIX=""

    if [ "$NEW_VERSION" != "$FULL_CURRENT" ]; then
        awk -v old="<version>${FULL_CURRENT}</version>" \
            -v new="<version>${NEW_VERSION}</version>" '
            BEGIN { in_parent=0; done=0 }
            /<parent>/   { in_parent=1 }
            /<\/parent>/ { in_parent=0 }
            !in_parent && !done && index($0, old) { sub(old, new); done=1 }
            { print }
        ' pom.xml > pom.xml.tmp && mv pom.xml.tmp pom.xml

        echo -e "\n${GRN}bumped:${NC} ${YLW}${FULL_CURRENT}${NC} → ${YLW}${NEW_VERSION}${NC}"
    else
        echo -e "\n${YLW}no bump applied.${NC}"
        NEW_VERSION="$FULL_CURRENT"
    fi
fi

COMMIT_MSG="chore(pom): bump version to ${NEW_VERSION}"
echo -e "\ncommit message: ${YLW}${COMMIT_MSG}${NC}"
read -rp "commit? [y/N]: " DO_COMMIT

if [[ "$DO_COMMIT" =~ ^[Yy]$ ]]; then
    git add pom.xml
    git commit -m "$COMMIT_MSG"
    echo -e "${GRN}done.${NC}"
else
    echo "skipped commit."
fi
