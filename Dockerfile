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

# node:22-slim already has a 'node' user (UID 1000)
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER node
ENV HOME=/home/node

ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]
