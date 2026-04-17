#!/usr/bin/env bash
# claude-sandbox: Cross-platform Claude Code Docker sandbox
# Usage:
#   claude-sandbox [project_path] [claude_flags...]
#   claude-sandbox --resume <session_id>
#   claude-sandbox --rebuild    # force rebuild the Docker image
set -e

IMAGE="claude-sandbox"
SANDBOX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Platform detection ──────────────────────────────────────────────────────
OS="$(uname -s 2>/dev/null || echo 'Windows_NT')"
case "$OS" in
    Darwin*)  PLATFORM="mac" ;;
    Linux*)
        if grep -qi microsoft /proc/version 2>/dev/null; then
            PLATFORM="wsl"
        else
            PLATFORM="linux"
        fi
        ;;
    MINGW*|MSYS*|CYGWIN*) PLATFORM="gitbash" ;;
    *) PLATFORM="linux" ;;
esac

# ── Path conversion ─────────────────────────────────────────────────────────
# Convert host path → Docker volume mount path
# On Git Bash, Docker Desktop requires Windows-style paths (C:/foo, not /c/foo)
native_to_mount() {
    local p="$1"
    if [[ "$PLATFORM" == "gitbash" ]]; then
        [[ "$p" =~ ^/([a-zA-Z])/(.*) ]] && echo "${BASH_REMATCH[1]^^}:/${BASH_REMATCH[2]}" || echo "$p"
    else
        echo "$p"
    fi
}

# Convert host path → path as seen inside the container
native_to_container() {
    local p="$1"
    case "$PLATFORM" in
        gitbash)
            # C:/foo or /c/foo → /c/foo
            if [[ "$p" =~ ^([a-zA-Z]):/(.*) ]]; then
                echo "/${BASH_REMATCH[1],,}/${BASH_REMATCH[2]}"
            else
                echo "$p"
            fi
            ;;
        wsl)
            # /mnt/c/foo → /c/foo (consistent with Docker Desktop on Windows)
            if [[ "$p" =~ ^/mnt/([a-zA-Z])/(.*) ]]; then
                echo "/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
            else
                echo "$p"
            fi
            ;;
        *)
            echo "$p"
            ;;
    esac
}

# ── Config directories ──────────────────────────────────────────────────────
CLAUDE_DIR="$HOME/.claude"
if [[ "$PLATFORM" == "gitbash" ]]; then
    GCLOUD_DIR="$HOME/AppData/Roaming/gcloud"
else
    GCLOUD_DIR="$HOME/.config/gcloud"
fi

# ── Argument parsing ────────────────────────────────────────────────────────
REBUILD=false
if [[ "${1:-}" == "--rebuild" ]]; then
    REBUILD=true; shift
fi

if [[ "${1:-}" == -* ]]; then
    PROJECT="$(pwd)"
    CLAUDE_FLAGS=("$@")
else
    PROJECT="${1:-$(pwd)}"
    shift 2>/dev/null || true
    CLAUDE_FLAGS=("$@")
fi

PROJECT="$(cd "$PROJECT" && pwd)"

# ── Docker path mappings ────────────────────────────────────────────────────
SANDBOX_MOUNT="$(native_to_mount "$SANDBOX_DIR")"
CLAUDE_MOUNT="$(native_to_mount "$CLAUDE_DIR")"
PROJECT_MOUNT="$(native_to_mount "$PROJECT")"
PROJECT_CONTAINER="$(native_to_container "$PROJECT")"
CONTAINER_NAME="claude-sandbox-$(printf '%s' "$PROJECT_MOUNT" | md5sum | cut -d' ' -f1 | head -c 8)"

# ── Docker check ─────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    echo "Error: Docker is not installed or not on PATH."
    echo "Install Docker Desktop: https://www.docker.com/products/docker-desktop/"
    exit 1
fi

# ── Build image ───────────────────────────────────────────────────────────────
if $REBUILD || ! docker image inspect "$IMAGE" &>/dev/null; then
    echo ">>> Building ${IMAGE} image (first time ~5 min)..."
    if [[ "$PLATFORM" == "gitbash" ]]; then
        MSYS_NO_PATHCONV=1 docker build -t "$IMAGE" "$SANDBOX_MOUNT"
    else
        docker build -t "$IMAGE" "$SANDBOX_DIR"
    fi
    echo ""
fi

echo ">>> Claude Code Sandbox  [$PLATFORM]"
echo "    Project   : $PROJECT"
echo "    Mount at  : $PROJECT_CONTAINER"
echo "    Container : $CONTAINER_NAME"
echo ""

# Remove stale container
docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$" \
    && docker rm -f "$CONTAINER_NAME" &>/dev/null || true

# ── Assemble docker run args ──────────────────────────────────────────────────
DOCKER_ARGS=(
    -it --rm --name "$CONTAINER_NAME"
    -v "${CLAUDE_MOUNT}:/home/node/.claude"
    -v "${PROJECT_MOUNT}:${PROJECT_CONTAINER}"
    -e "HOST_PLATFORM=${PLATFORM}"
    -e "CLAUDE_CODE_USE_VERTEX=1"
    -e "ANTHROPIC_VERTEX_PROJECT_ID=r-uv-admin"
    -e "CLOUD_ML_REGION=global"
    -w "${PROJECT_CONTAINER}"
)

# gcloud credentials (optional)
if [[ -d "$GCLOUD_DIR" ]]; then
    GCLOUD_MOUNT="$(native_to_mount "$GCLOUD_DIR")"
    DOCKER_ARGS+=(-v "${GCLOUD_MOUNT}:/home/node/.config/gcloud")
    DOCKER_ARGS+=(-e "GOOGLE_APPLICATION_CREDENTIALS=/home/node/.config/gcloud/application_default_credentials.json")
fi

# Git config (optional)
if [[ -f "$HOME/.gitconfig" ]]; then
    DOCKER_ARGS+=(-v "$(native_to_mount "$HOME/.gitconfig"):/tmp/.gitconfig.host:ro")
fi

# Corporate CA bundle — place ca-bundle.pem in sandbox dir to enable
if [[ -f "$SANDBOX_DIR/ca-bundle.pem" ]]; then
    DOCKER_ARGS+=(-v "${SANDBOX_MOUNT}/ca-bundle.pem:/etc/ssl/certs/ca-bundle.pem:ro")
    DOCKER_ARGS+=(-e "NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-bundle.pem")
    DOCKER_ARGS+=(-e "NODE_TLS_REJECT_UNAUTHORIZED=0")
fi

# Pass through API key if set (alternative to Vertex AI)
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    DOCKER_ARGS+=(-e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}")
fi

# ── Launch ────────────────────────────────────────────────────────────────────
if [[ "$PLATFORM" == "gitbash" ]]; then
    MSYS_NO_PATHCONV=1 docker run "${DOCKER_ARGS[@]}" "$IMAGE" "${CLAUDE_FLAGS[@]}"
else
    docker run "${DOCKER_ARGS[@]}" "$IMAGE" "${CLAUDE_FLAGS[@]}"
fi
