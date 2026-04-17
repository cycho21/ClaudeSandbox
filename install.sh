#!/usr/bin/env bash
# Install claude-sandbox command (Mac / Linux / Git Bash on Windows)
# Usage: ./install.sh [--prefix /path/to/bin]
set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS="$(uname -s 2>/dev/null || echo 'Windows_NT')"

case "$OS" in
    Darwin*)          PLATFORM="mac" ;;
    Linux*)           PLATFORM="linux" ;;
    MINGW*|MSYS*|CYGWIN*) PLATFORM="gitbash" ;;
    *)                PLATFORM="linux" ;;
esac

# Parse args
PREFIX=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix|-p) PREFIX="$2"; shift 2 ;;
        --prefix=*)  PREFIX="${1#*=}"; shift ;;
        -h|--help)
            echo "Usage: $0 [--prefix /path/to/bin]"
            echo "  Installs the claude-sandbox command."
            echo "  Default prefix: ~/.local/bin (Mac/Linux) or ~/bin (Git Bash)"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Default prefix
if [[ -z "$PREFIX" ]]; then
    case "$PLATFORM" in
        gitbash) PREFIX="$HOME/bin" ;;
        *)       PREFIX="$HOME/.local/bin" ;;
    esac
fi

INSTALL_PATH="$PREFIX/claude-sandbox"
SCRIPT_PATH="$REPO_DIR/claude-sandbox.sh"

echo "=== Claude Sandbox Installer ==="
echo "    Platform  : $PLATFORM"
echo "    Repo      : $REPO_DIR"
echo "    Install → : $INSTALL_PATH"
echo ""

# Validate script exists
if [[ ! -f "$SCRIPT_PATH" ]]; then
    echo "Error: $SCRIPT_PATH not found."
    exit 1
fi

mkdir -p "$PREFIX"
chmod +x "$SCRIPT_PATH"

# Create launcher wrapper pointing back into the repo
cat > "$INSTALL_PATH" << EOF
#!/usr/bin/env bash
exec "${SCRIPT_PATH}" "\$@"
EOF
chmod +x "$INSTALL_PATH"

echo ">>> Installed: $INSTALL_PATH"

# Add PREFIX to PATH if missing
if ! printf '%s\n' "${PATH//:/$'\n'}" | grep -qx "$PREFIX"; then
    if [[ "$SHELL" == */zsh ]] || [[ -n "${ZSH_VERSION:-}" ]]; then
        RC="$HOME/.zshrc"
    elif [[ "$PLATFORM" == "gitbash" ]]; then
        RC="$HOME/.bash_profile"
    else
        RC="$HOME/.bashrc"
    fi
    printf '\n# claude-sandbox\nexport PATH="%s:$PATH"\n' "$PREFIX" >> "$RC"
    echo ">>> Added $PREFIX to PATH in $RC"
    echo "    Run: source $RC   (or restart your shell)"
else
    echo ">>> $PREFIX is already in PATH"
fi

# Docker check
if ! command -v docker &>/dev/null; then
    echo ""
    echo "!!! Docker not found. Install Docker Desktop:"
    echo "    https://www.docker.com/products/docker-desktop/"
fi

echo ""
echo "=== Done! Run: claude-sandbox [project_path]"
