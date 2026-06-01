FROM node:22-slim

RUN apt-get update && apt-get install -y \
    git \
    curl \
    bash \
    python3 \
    python3-pip \
    ca-certificates \
    jq \
    gnupg \
    apt-transport-https \
    dos2unix \
    sudo \
    gosu \
    && rm -rf /var/lib/apt/lists/*

# Install gcloud CLI
RUN curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    | tee /etc/apt/sources.list.d/google-cloud-sdk.list \
    && apt-get update && apt-get install -y google-cloud-cli \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

# Create python symlink (python3 -> python)
RUN ln -s /usr/bin/python3 /usr/bin/python

# node:22-slim already has a 'node' user (UID 1000).
# The gate user owns workflow authority/state files; Claude runs as node.
RUN useradd --create-home --uid 2000 --gid node gate \
    && mkdir -p /opt/harness-workflow-gate \
    && chown gate:node /opt/harness-workflow-gate \
    && chmod 0700 /opt/harness-workflow-gate

RUN printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'PROJECT_DIR="${1:-$(pwd)}"' \
    'SESSION_ID="${2:-}"' \
    'shift 2 || true' \
    'export CLAUDE_PROJECT_DIR="$PROJECT_DIR"' \
    '[ -n "$SESSION_ID" ] && export CLAUDE_SESSION_ID="$SESSION_ID"' \
    'unset NODE_OPTIONS npm_config_prefix npm_config_globalconfig npm_config_userconfig' \
    'cd "$PROJECT_DIR"' \
    'exec node /opt/harness-workflow-gate/workflow-gate.cjs "$@"' \
    > /usr/local/bin/workflow-gate-run \
    && chmod 0750 /usr/local/bin/workflow-gate-run \
    && chown gate:node /usr/local/bin/workflow-gate-run

RUN printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"' \
    'SESSION_ID="${CLAUDE_SESSION_ID:-}"' \
    'exec sudo -n -u gate /usr/local/bin/workflow-gate-run "$PROJECT_DIR" "$SESSION_ID" "$@"' \
    > /usr/local/bin/workflow-gate \
    && chmod 0755 /usr/local/bin/workflow-gate

RUN printf '%s\n' \
    'Defaults:node env_reset' \
    'node ALL=(gate) NOPASSWD: /usr/local/bin/workflow-gate-run' \
    > /etc/sudoers.d/workflow-gate \
    && chmod 0440 /etc/sudoers.d/workflow-gate

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV HOME=/home/node

ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]
