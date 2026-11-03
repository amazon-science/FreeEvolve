#!/usr/bin/env bash
# Install the ARC-AGI-2 environment into a run directory.
#
#   setup.sh <run_dir>
#
# Creates, inside the run directory:
#   ENVIRONMENT.md          the goal and how to evaluate
#   run.sh                  the evaluation
#   eval/                   harbor's venv, the adapter, and the generated puzzles
#   agent/arc_agent/        the puzzle agent (the edit surface)
#   .target                 declares that edit surface: `agent/arc_agent`
#
# Environment variables it reads:
#   HARBOR_ROOT       a harbor checkout holding adapters/arc_agi_2. Unset: one is
#                     cloned at a pinned commit and cached (lib/ensure_harbor.sh)
#   ARC_TASK_COUNT    how many puzzles to materialize (default from defaults.env)
#   ARC_SPLIT         which split to draw from (default evaluation)
#   ARC_DATASET_SRC   reuse an already-generated task directory instead of regenerating
#   ARC_AGENT_SRC     start from an agent someone else left behind rather than the
#                     vendored one, so a run can continue from a previous best
#
# The run directory is standalone afterwards: nothing in it refers back here.
set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${1:?usage: setup.sh <run_dir>}"
mkdir -p "$WS"
WS="$(cd "$WS" && pwd)"
EVAL="$WS/eval"
# The harbor checkout this environment reads its adapter from. When HARBOR_ROOT is
# already set it is used as-is; otherwise a clone is made at a pinned commit and
# cached, so setup needs nothing prepared by hand. See lib/ensure_harbor.sh.
# shellcheck source=../../lib/ensure_harbor.sh
source "$(cd "$ENV_DIR/../.." && pwd)/lib/ensure_harbor.sh"
ensure_harbor

for c in uv docker rsync; do
    command -v "$c" >/dev/null || { echo "$c not found on PATH" >&2; exit 1; }
done

source "$ENV_DIR/defaults.env"

# --- The evaluation venv ------------------------------------------------------
# uv's cache defaults to $HOME, which is shared NFS here; concurrent installs then
# race on the same archive entries and the losers die mid-install. A node-local cache
# removes the race and is still reused across runs on that node.
export UV_CACHE_DIR="${UV_CACHE_DIR:-/tmp/uv-cache-$(id -u)}"
mkdir -p "$UV_CACHE_DIR"
echo "[setup] uv cache: $UV_CACHE_DIR"

mkdir -p "$EVAL"
VENV_PY="$EVAL/.venv/bin/python"
if [ ! -x "$VENV_PY" ]; then
    uv venv --python 3.12 "$EVAL/.venv"
fi
# --python pins the install to THIS venv, so an ambient VIRTUAL_ENV cannot send
# harbor somewhere else.
uv pip install --quiet --python "$VENV_PY" harbor
# datasets for generation; boto3 for litellm's Bedrock provider on the harness side.
uv pip install --quiet --python "$VENV_PY" boto3 datasets
echo "[setup] harbor: $("$EVAL/.venv/bin/harbor" --version 2>/dev/null || echo installed)"

cp "$ENV_DIR/defaults.env" "$EVAL/"

# The VAL half is not this run's business. It is declared in the repo's defaults.env, which
# is what tooling reads; the copy installed here has it removed so a run cannot read the
# held-out ids out of its own configuration.
sed -i -E '/^VAL_(TASKS|PUZZLES|GAMES)=/d' "$EVAL/defaults.env"
cp "$ENV_DIR/ENVIRONMENT.md" "$WS/ENVIRONMENT.md"
cp "$ENV_DIR/run.sh" "$WS/run.sh"
chmod +x "$WS/run.sh"

# --- The adapter, copied out of the harbor checkout ---------------------------
# Copied rather than used in place: the checkout is shared and must not be edited, and
# a run that carries its own adapter stays readable after the checkout moves on.
# Nothing needs patching here — unlike the environments with a model-based grader,
# this one's verifier compares grids and calls no model at all.
ADAPTER_SRC="$HARBOR_ROOT/adapters/arc_agi_2"
[ -d "$ADAPTER_SRC" ] || { echo "[setup] no arc_agi_2 adapter at $ADAPTER_SRC" >&2; exit 1; }
rm -rf "$EVAL/adapter"
rsync -a --exclude='__pycache__/' "$ADAPTER_SRC/" "$EVAL/adapter/"
printf '%s\n' "$ADAPTER_SRC" > "$EVAL/.adapter_source"

# --- The puzzles --------------------------------------------------------------
DATASET_DIR="$EVAL/$DATASET_SUBDIR"
if [ -n "${ARC_DATASET_SRC:-}" ]; then
    [ -d "$ARC_DATASET_SRC" ] || {
        echo "[setup] ARC_DATASET_SRC is not a directory: $ARC_DATASET_SRC" >&2; exit 1; }
    echo "[setup] copying prebuilt tasks from $ARC_DATASET_SRC"
    mkdir -p "$(dirname "$DATASET_DIR")"
    rsync -a "$ARC_DATASET_SRC/" "$DATASET_DIR/"
elif [ -d "$DATASET_DIR" ] && [ -n "$(ls -A "$DATASET_DIR" 2>/dev/null)" ]; then
    echo "[setup] tasks already present at $DATASET_DIR — leaving them alone"
else
    COUNT="${ARC_TASK_COUNT:-$DEFAULT_TASK_COUNT}"
    SPLIT="${ARC_SPLIT:-evaluation}"
    echo "[setup] generating $COUNT tasks from the $SPLIT split"
    ( cd "$EVAL/adapter" && PYTHONPATH="$EVAL/adapter/src" "$VENV_PY" -m arc_agi_2.main generate \
        --split "$SPLIT" --limit "$COUNT" --output-dir "$DATASET_DIR" --overwrite \
        --agent-timeout "$AGENT_TIMEOUT_SEC" --verifier-timeout "$VERIFIER_TIMEOUT_SEC" )
fi
echo "[setup] tasks: $(ls -A "$DATASET_DIR" 2>/dev/null | wc -l) at $DATASET_DIR"

# --- The edit surface ---------------------------------------------------------
# ARC_AGENT_SRC starts this run from an agent someone else left behind, instead of the
# vendored one — so a run can continue from a previous run's best rather than from
# scratch. The files are COPIED, so the run stays standalone and editing them cannot
# reach back into whatever produced them.
#
# Note what this changes about the numbers: the inherited agent becomes this run's
# `.target_pristine` below, so "unchanged" here means what this run was handed, not
# what the environment ships. A baseline measured in this run is a baseline of the
# inherited agent and is NOT comparable to a cold run's baseline.
AGENT_DIR="$WS/agent/arc_agent"
AGENT_SRC_DIR="${ARC_AGENT_SRC:-$ENV_DIR/agent}"
if [ -d "$AGENT_DIR" ]; then
    echo "[setup] $AGENT_DIR already exists — leaving it alone"
else
    for f in arc_agent.py run_arc_agent.py; do
        [ -f "$AGENT_SRC_DIR/$f" ] || {
            echo "[setup] agent source $AGENT_SRC_DIR is missing $f" >&2
            echo "[setup] it must hold both agent modules" >&2
            exit 1
        }
    done
    mkdir -p "$AGENT_DIR"
    # Everything the source holds, not just the two required modules: an agent may
    # have been split into more files than it started with, and copying only the names
    # known here would drop them silently — the run would then fail on import, far
    # from the cause.
    rsync -a --exclude='__pycache__/' --exclude='*.pyc' "$AGENT_SRC_DIR/" "$AGENT_DIR/"
    if [ -n "${ARC_AGENT_SRC:-}" ]; then
        echo "[setup] agent at $AGENT_DIR (inherited from $AGENT_SRC_DIR)"
        printf '%s\n' "$AGENT_SRC_DIR" > "$WS/.agent_source"
    else
        echo "[setup] agent at $AGENT_DIR (vendored)"
    fi
fi

# Where the edit surface lives, relative to the run directory. harbor imports the
# agent as `arc_agent:ARCAgent`, so the directory holding the module must be on
# PYTHONPATH — and that is this directory itself, not its parent. Declaring the real
# path means the agent is edited where it runs; no staging copy stands between what is
# edited and what is measured.
echo "agent/arc_agent" > "$WS/.target"

# The fixed model capability must survive an inheritance. An ancestor that lost it
# would change what every later number in a chain means, silently.
for f in arc_agent.py run_arc_agent.py; do
    grep -q 'DEFAULT_MAX_TOKENS = 16384' "$AGENT_DIR/$f" || {
        echo "[setup] $f does not set DEFAULT_MAX_TOKENS = 16384." >&2
        echo "[setup] The model capability is fixed; see ENVIRONMENT.md." >&2
        exit 1
    }
    grep -q 'DEFAULT_REASONING_EFFORT = "medium"' "$AGENT_DIR/$f" || {
        echo "[setup] $f does not set DEFAULT_REASONING_EFFORT = \"medium\"." >&2
        echo "[setup] The model capability is fixed; see ENVIRONMENT.md." >&2
        exit 1
    }
done

rm -rf "$WS/.target_pristine"
mkdir -p "$WS/.target_pristine"
rsync -a --exclude='__pycache__/' --exclude='*.pyc' "$AGENT_DIR/" "$WS/.target_pristine/"

echo "[setup] ARC-AGI-2 environment installed in $WS"
