#!/bin/bash
set -e

# Root-only preparation. Claude itself runs as the unprivileged node user.
if [ "$(id -u)" = "0" ]; then
    WORK_DIR="$(pwd)"

    # Harness-aware hardening (enabled by default when a workflow gate is present).
    # Set CLAUDE_SANDBOX_PROTECT_HARNESS=0 to disable permission changes/command patching.
    if [ "${CLAUDE_SANDBOX_PROTECT_HARNESS:-1}" != "0" ] && [ -f "$WORK_DIR/.claude/hooks/workflow-gate.cjs" ]; then
        echo ">>> Hardening harness workflow gate paths"

        mkdir -p \
            "$WORK_DIR/.harness/.authority-runtime" \
            "$WORK_DIR/.harness/checkpoints" \
            "$WORK_DIR/.harness/dpaa-runs" \
            /opt/harness-workflow-gate

        # Copy the project-provided gate into an image-owned location before Claude starts.
        # The elevated gate user executes this immutable copy, never mutable project JS.
        cp "$WORK_DIR/.claude/hooks/workflow-gate.cjs" /opt/harness-workflow-gate/workflow-gate.cjs
        chown -R gate:node /opt/harness-workflow-gate
        chmod 0700 /opt/harness-workflow-gate
        chmod 0500 /opt/harness-workflow-gate/workflow-gate.cjs
        sha256sum /opt/harness-workflow-gate/workflow-gate.cjs > /opt/harness-workflow-gate/workflow-gate.cjs.sha256 2>/dev/null || true
        chown gate:node /opt/harness-workflow-gate/workflow-gate.cjs.sha256 2>/dev/null || true
        chmod 0400 /opt/harness-workflow-gate/workflow-gate.cjs.sha256 2>/dev/null || true

        # Make git commands work for both node and gate users on mounted workspaces.
        git config --system --add safe.directory "$WORK_DIR" 2>/dev/null || true

        # Route Claude hooks through /usr/local/bin/workflow-gate, which sudo-runs the gate as user 'gate'.
        if [ -f "$WORK_DIR/.claude/settings.json" ]; then
            python3 - "$WORK_DIR/.claude/settings.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    data = json.load(f)
for entries in (data.get('hooks') or {}).values():
    if not isinstance(entries, list):
        continue
    for entry in entries:
        for hook in entry.get('hooks') or []:
            cmd = hook.get('command')
            if isinstance(cmd, str) and 'workflow-gate.cjs' in cmd:
                if 'user-prompt' in cmd:
                    hook['command'] = '/usr/local/bin/workflow-gate user-prompt'
                elif 'check-tool-call' in cmd:
                    hook['command'] = '/usr/local/bin/workflow-gate check-tool-call'
                elif 'reevaluate' in cmd:
                    hook['command'] = '/usr/local/bin/workflow-gate reevaluate'
                hook.pop('args', None)
with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
PY
        fi

        if [ -d "$WORK_DIR/.claude/commands/workflow" ]; then
            find "$WORK_DIR/.claude/commands/workflow" -type f -name '*.md' -print0 \
                | xargs -0 -r sed -i 's#node \.claude/hooks/workflow-gate\.cjs#/usr/local/bin/workflow-gate#g'
        fi

        # Gate-owned mutable authority/state. The node user can execute the gate helper, but
        # cannot directly read/write authority tokens or mutate workflow state through Bash.
        for p in \
            "$WORK_DIR/.harness/authority" \
            "$WORK_DIR/.harness/.authority-runtime" \
            "$WORK_DIR/.harness/checkpoints" \
            "$WORK_DIR/.harness/dpaa-runs"; do
            [ -e "$p" ] && chown -R gate:node "$p" 2>/dev/null || true
            [ -d "$p" ] && chmod -R u+rwX,g-rwx,o-rwx "$p" 2>/dev/null || true
        done
        for f in "$WORK_DIR/.harness/state.json" "$WORK_DIR/.harness/workflow.json" "$WORK_DIR/.harness/policy.yaml"; do
            [ -e "$f" ] && chown gate:node "$f" 2>/dev/null || true
            [ -e "$f" ] && chmod 600 "$f" 2>/dev/null || true
        done

        # Hooks/settings are gate-owned/read-only to the Claude user.
        if [ -d "$WORK_DIR/.claude/hooks" ]; then
            chown -R gate:node "$WORK_DIR/.claude/hooks" 2>/dev/null || true
            find "$WORK_DIR/.claude/hooks" -type d -exec chmod 755 {} + 2>/dev/null || true
            find "$WORK_DIR/.claude/hooks" -type f -exec chmod 555 {} + 2>/dev/null || true
        fi
        if [ -f "$WORK_DIR/.claude/settings.json" ]; then
            chown gate:node "$WORK_DIR/.claude/settings.json" 2>/dev/null || true
            chmod 444 "$WORK_DIR/.claude/settings.json" 2>/dev/null || true
        fi
        if [ -d "$WORK_DIR/.claude/commands/workflow" ]; then
            chown -R gate:node "$WORK_DIR/.claude/commands/workflow" 2>/dev/null || true
            find "$WORK_DIR/.claude/commands/workflow" -type d -exec chmod 755 {} + 2>/dev/null || true
            find "$WORK_DIR/.claude/commands/workflow" -type f -exec chmod 444 {} + 2>/dev/null || true
        fi

        # Protect parent directories so read-only protected children are harder to replace.
        # Keep known user-writable artifact areas available where the workflow expects them.
        [ -d "$WORK_DIR/.claude" ] && chown gate:node "$WORK_DIR/.claude" 2>/dev/null || true
        [ -d "$WORK_DIR/.claude" ] && chmod 755 "$WORK_DIR/.claude" 2>/dev/null || true
        [ -d "$WORK_DIR/.harness" ] && chown gate:node "$WORK_DIR/.harness" 2>/dev/null || true
        [ -d "$WORK_DIR/.harness" ] && chmod 755 "$WORK_DIR/.harness" 2>/dev/null || true
        if [ -d "$WORK_DIR/.harness/proposal" ]; then
            chown -R node:node "$WORK_DIR/.harness/proposal" 2>/dev/null || true
            chmod -R u+rwX,go+rX "$WORK_DIR/.harness/proposal" 2>/dev/null || true
        fi

        # Gate-owned runtime tools that must not be modified by node.
        # node can read/execute these (for diagnostics) but cannot write.
        for pi_dir in \
            "$WORK_DIR/.pi/dpaa" \
            "$WORK_DIR/.pi/sbadr"; do
            [ -d "$pi_dir" ] && chown -R gate:node "$pi_dir" 2>/dev/null || true
            [ -d "$pi_dir" ] && chmod -R u+rwX,g+rX,o-rwx "$pi_dir" 2>/dev/null || true
        done
    fi

    # Ensure 'python' resolves to python3 (some images only have python3)
    command -v python > /dev/null 2>&1 || \
        ln -sf "$(command -v python3)" /usr/local/bin/python 2>/dev/null || true

    exec gosu node "$0" "$@"
fi

export HOME=/home/node

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

# Fix Windows CRLF line endings in hook scripts.
# Scoped to dirs that actually contain shell scripts — avoids traversing plugins/
# or projects/ (100k+ files) through Docker's WSL2 virtual filesystem.
for _d in hooks commands sandbox skills; do
    [ -d "${HOME}/.claude/${_d}" ] && \
        find "${HOME}/.claude/${_d}" -type f -name "*.sh" \
            -exec dos2unix -q {} \; 2>/dev/null || true
done
unset _d

# Install Python dependencies if requirements.txt exists
if [ -f "${HOME}/.claude/llm-wiki/scripts/requirements.txt" ]; then
    pip3 install --user -q -r "${HOME}/.claude/llm-wiki/scripts/requirements.txt" 2>/dev/null || true
fi

# Fix git dubious ownership warning for mounted workspace
WORK_DIR="$(pwd)"
git config --global --add safe.directory "$WORK_DIR"

# Copy host SSH keys with correct permissions (Windows mounts can't be chmodded)
if [ -d "/tmp/.ssh.host" ] && [ ! -d "${HOME}/.ssh" ]; then
    cp -r /tmp/.ssh.host "${HOME}/.ssh"
    chmod 700 "${HOME}/.ssh"
    chmod 600 "${HOME}/.ssh"/id_* 2>/dev/null || true
    chmod 644 "${HOME}/.ssh"/id_*.pub 2>/dev/null || true
    chmod 644 "${HOME}/.ssh/known_hosts" 2>/dev/null || true
fi

# Translate Windows-absolute hook paths to portable python -c form.
# The portable form works on both Windows and Linux, so writing back is safe.
# Background: sh -c strips backslashes (C:\foo → C:foo), breaking Windows paths on Linux.
if [ -f "${HOME}/.claude/settings.json" ]; then
    python3 - "${HOME}/.claude/settings.json" "$HOME" <<'PY'
import json, sys, re
path, home = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path, encoding='utf-8'))
except Exception:
    sys.exit(0)
WIN_HOOK = re.compile(
    r'^(python\d*)\s+[A-Za-z]:[/\\]Users[/\\][^/\\]+[/\\]\.claude[/\\](.+)$',
    re.IGNORECASE
)
def fix(cmd):
    m = WIN_HOOK.match(cmd)
    if not m:
        return cmd
    rel = m.group(2).replace('\\', '/')
    return (m.group(1) + " -c \"import os;"
            "exec(open(os.path.join(os.path.expanduser('~'),'.claude','" + rel + "')).read())\"")
changed = False
for ev in (data.get('hooks') or {}).values():
    for entry in (ev if isinstance(ev, list) else []):
        for hook in (entry.get('hooks') or []):
            if 'command' in hook:
                new = fix(hook['command'])
                if new != hook['command']:
                    hook['command'] = new
                    changed = True
if changed:
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2)
        f.write('\n')
PY
fi

# Windows GCM (credential.helper=manager) doesn't exist in Linux — replace with store
_gl_helper=$(git config --global credential.helper 2>/dev/null || true)
case "$_gl_helper" in
    *manager*) git config --global credential.helper store ;;
esac
unset _gl_helper

# Configure HTTPS credentials when injected from Windows Credential Manager
if [ -n "$GITLAB_TOKEN" ]; then
    _gl_host="${GITLAB_HOST:-gitlab.com}"
    _gl_user="${GITLAB_USER:-oauth2}"
    git config --global credential.helper store
    printf "https://%s:%s@%s\n" "$_gl_user" "$GITLAB_TOKEN" "$_gl_host" >> "${HOME}/.git-credentials"
    chmod 600 "${HOME}/.git-credentials"
    unset _gl_host _gl_user
fi

# Sync sessions between docker (linux-sanitized) and native Windows (win-sanitized) dirs
# Only needed on Git Bash where project paths use Windows drive letters (/c/foo).
# HOST_PLATFORM is injected by claude-sandbox.sh.
# Guard against false-positive matches on Mac/Linux paths like /Users/... or /home/...
LINUX_PROJ=""
WIN_PROJ=""
if [[ "$HOST_PLATFORM" == "gitbash" ]] && [[ "$WORK_DIR" =~ ^//?([a-zA-Z])/(.*) ]]; then
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

# Create workspace .claude directory with permissive settings only for non-harness projects.
# Harness projects bring their own gate settings and are hardened above.
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

set +e
claude --dangerously-skip-permissions "$@"
EXIT_CODE=$?
set -e

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
