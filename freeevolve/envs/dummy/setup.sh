#!/usr/bin/env bash
# Install the dummy environment into a run directory.
#
#   setup.sh <run_dir>
#
# Creates, inside the run directory:
#   ENVIRONMENT.md   the goal and how to evaluate
#   run.sh           the evaluation
#   eval/            the evaluator and the question sets
#   target/          the agent source (the edit surface)
#   .target          declares where that edit surface is: `target`
#
# The run directory is standalone afterwards: nothing in it refers back to this
# directory. Idempotent, and never clobbers an existing target.
set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${1:?usage: setup.sh <run_dir>}"
mkdir -p "$WS"
WS="$(cd "$WS" && pwd)"

command -v claude >/dev/null || { echo "claude not found on PATH" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found on PATH" >&2; exit 1; }

# --- The evaluation ----------------------------------------------------------
rm -rf "$WS/eval"
mkdir -p "$WS/eval"
cp "$ENV_DIR/evaluate.py" "$WS/eval/"
cp -r "$ENV_DIR/questions" "$WS/eval/"
find "$WS/eval" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true

cp "$ENV_DIR/ENVIRONMENT.md" "$WS/ENVIRONMENT.md"
cp "$ENV_DIR/run.sh" "$WS/run.sh"
chmod +x "$WS/run.sh" "$WS/eval/evaluate.py"

# Where the edit surface lives, relative to the run directory. Nothing about this
# agent constrains its location, so it goes at the conventional path.
echo "target" > "$WS/.target"

# --- The edit surface --------------------------------------------------------
if [ -d "$WS/target" ]; then
    echo "[setup] $WS/target already exists — leaving it alone"
else
    cp -r "$ENV_DIR/target" "$WS/target"
    echo "[setup] pristine target at $WS/target"
fi

# A pristine reference copy, so the original is recoverable even if target/ is
# edited in place.
rm -rf "$WS/.target_pristine"
cp -r "$ENV_DIR/target" "$WS/.target_pristine"

echo "[setup] dummy environment installed in $WS"
