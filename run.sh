#!/usr/bin/env bash
# Compatibility shim — delegates to claude-sandbox.sh
exec "$(dirname "${BASH_SOURCE[0]}")/claude-sandbox.sh" "$@"
