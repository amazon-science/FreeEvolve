#!/usr/bin/env bash
# Evaluate a dummy-environment agent.
#
#   ./run.sh --artifacts <dir> [--questions ids|all] [--attempts n]
#            [--concurrency n] [--split train|test]
#
# Always evaluates ./target — the agent. See ENVIRONMENT.md.
#
# See ENVIRONMENT.md for what the flags mean and where the results land.
# Safe to run many times concurrently, as long as --artifacts differs.
set -euo pipefail

RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$RUN_DIR/eval/evaluate.py" "$@"
