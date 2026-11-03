#!/usr/bin/env bash
# Local backend adapter for the canonical Slurm meta_chain environment.
set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
META_CHAIN_BACKEND=local \
META_CHAIN_BACKEND_DIR="$ENV_DIR" \
    exec "$ENV_DIR/../meta_chain/setup.sh" "$@"
