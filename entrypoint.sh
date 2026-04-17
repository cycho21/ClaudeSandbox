#!/bin/bash

# Restore .claude.json from backup if missing
if [ ! -f "${HOME}/.claude.json" ]; then
    BACKUP=$(ls "${HOME}/.claude/backups/.claude.json.backup."* 2>/dev/null | sort | tail -1)
    if [ -n "$BACKUP" ]; then
        cp "$BACKUP" "${HOME}/.claude.json"
    fi
fi

# Copy host gitconfig if not exists
if [ -f "/tmp/.gitconfig.host" ] && [ ! -f "${HOME}/.gitconfig" ]; then
    cp /tmp/.gitconfig.host "${HOME}/.gitconfig"
fi

# Fix Windows CRLF line endings in hook scripts
find "${HOME}/.claude" -type f -name "*.sh" -exec dos2unix -q {} \;

# Install Python dependencies if requirements.txt exists
if [ -f "${HOME}/.claude/llm-wiki/scripts/requirements.txt" ]; then
    pip3 install --user -q -r "${HOME}/.claude/llm-wiki/scripts/requirements.txt" 2>/dev/null || true
fi

# Fix git dubious ownership warning for mounted workspace
WORK_DIR="$(pwd)"
git config --global --add safe.directory "$WORK_DIR"

# Sync sessions between docker (linux-sanitized) and native Windows (win-sanitized) dirs
# Only needed on Git Bash where project paths use Windows drive letters (/c/foo).
# HOST_PLATFORM is injected by claude-sandbox.sh.
# Guard against false-positive matches on Mac/Linux paths like /Users/... or /home/...
LINUX_PROJ=""
WIN_PROJ=""
if [[ "$HOST_PLATFORM" == "gitbash" ]] && [[ "$WORK_DIR" =~ ^/([a-zA-Z])/(.*) ]]; then
    LINUX_SANITIZED=$(echo "$WORK_DIR" | sed 's/[^a-zA-Z0-9]/-/g')
    WIN_SANITIZED=$(echo "${BASH_REMATCH[1]^^}:/${BASH_REMATCH[2]}" | sed 's/[^a-zA-Z0-9]/-/g')
    LINUX_PROJ="${HOME}/.claude/projects/${LINUX_SANITIZED}"
    WIN_PROJ="${HOME}/.claude/projects/${WIN_SANITIZED}"
    mkdir -p "$LINUX_PROJ"
    # Copy Windows sessions → docker dir (skip existing files)
    if [ -d "$WIN_PROJ" ]; then
        cp -rn "${WIN_PROJ}/." "${LINUX_PROJ}/" 2>/dev/null || true
    fi
fi

# Create workspace .claude directory with permissive settings
if [ ! -f "$WORK_DIR/.claude/settings.json" ]; then
    mkdir -p "$WORK_DIR/.claude"
    cat > "$WORK_DIR/.claude/settings.json" << 'EOF'
{
  "permissions": {
    "allow": ["Write", "Edit", "Read", "Bash", "Grep", "Glob"],
    "defaultMode": "dontAsk"
  }
}
EOF
fi

claude --dangerously-skip-permissions "$@"
EXIT_CODE=$?

# Find most recent session in THIS project
# Matches claude's internal BD() function: replace(/[^a-zA-Z0-9]/g, "-")
SANITIZED=$(echo "$(pwd)" | sed 's/[^a-zA-Z0-9]/-/g')
PROJ_DIR="${HOME}/.claude/projects/${SANITIZED}"

LATEST=$(find "${PROJ_DIR}" -maxdepth 1 -name "*.jsonl" 2>/dev/null \
    | xargs -r ls -t 2>/dev/null | head -1)

# Copy new docker sessions → Windows dir
if [ -n "$WIN_PROJ" ] && [ -d "$LINUX_PROJ" ]; then
    mkdir -p "$WIN_PROJ"
    cp -rn "${LINUX_PROJ}/." "${WIN_PROJ}/" 2>/dev/null || true
fi

if [ -n "$LATEST" ]; then
    SESSION_ID=$(basename "$LATEST" .jsonl)
    echo ""
    echo "─────────────────────────────────────────────────────────"
    echo "  Session : $SESSION_ID"
    echo "  Resume  : claude-sandbox --resume $SESSION_ID"
    echo "─────────────────────────────────────────────────────────"
fi

exit $EXIT_CODE
