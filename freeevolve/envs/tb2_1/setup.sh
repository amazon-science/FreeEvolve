#!/usr/bin/env bash
# Install the terminal-bench 2.1 environment into a run directory.
#
#   setup.sh <run_dir>
#
# Creates, inside the run directory:
#   ENVIRONMENT.md   the goal and how to evaluate
#   run.sh           the evaluation
#   eval/            harbor's venv and the task list
#   agent/terminus_2/  the terminus-2 agent (the edit surface), at the package
#                      path harbor imports it from
#   .target          declares that edit surface: `agent/terminus_2`
#
# The run directory is standalone afterwards: nothing in it refers back to this
# directory. Idempotent, and never clobbers an existing target.
set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${1:?usage: setup.sh <run_dir>}"
mkdir -p "$WS"
WS="$(cd "$WS" && pwd)"
EVAL="$WS/eval"

for c in uv docker curl; do
    command -v "$c" >/dev/null || { echo "$c not found on PATH" >&2; exit 1; }
done

# --- Docker Compose v2 (harbor needs the `docker compose` subcommand) --------
if ! docker compose version >/dev/null 2>&1; then
    echo "[setup] installing Docker Compose v2 plugin under ~/.docker/cli-plugins/"
    mkdir -p "$HOME/.docker/cli-plugins"
    curl -fSL \
        "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" \
        -o "$HOME/.docker/cli-plugins/docker-compose"
    chmod +x "$HOME/.docker/cli-plugins/docker-compose"
    docker compose version >/dev/null 2>&1 || {
        echo "[setup] docker compose still not working after install" >&2
        exit 1
    }
fi
echo "[setup] docker compose: $(docker compose version --short 2>/dev/null || echo present)"

# --- The evaluation: harbor and the task list --------------------------------
# uv's cache defaults to $HOME, which is shared NFS on this cluster. Several run
# directories being installed at the same time then hardlink out of the same archive
# entry, and every loser of that race dies with "failed to hardlink ... No such file
# or directory" partway through installing harbor. Each job here owns its node, so a
# node-local cache removes the race entirely and still gets reused across runs on
# that node.
export UV_CACHE_DIR="${UV_CACHE_DIR:-/tmp/uv-cache-$(id -u)}"
mkdir -p "$UV_CACHE_DIR"
echo "[setup] uv cache: $UV_CACHE_DIR"

mkdir -p "$EVAL"
VENV_PY="$EVAL/.venv/bin/python"
if [ ! -x "$VENV_PY" ]; then
    uv venv --python 3.12 "$EVAL/.venv"
fi
# --python pins the install to THIS venv. Without it, uv honors an ambient
# VIRTUAL_ENV (e.g. when setup runs from inside another venv's activation) and
# would install harbor somewhere else, leaving the terminus_2 source missing.
uv pip install --quiet --python "$VENV_PY" harbor
# litellm's Bedrock provider needs boto3 at runtime; harbor doesn't pull it in.
uv pip install --quiet --python "$VENV_PY" boto3
echo "[setup] harbor: $("$EVAL/.venv/bin/harbor" --version 2>/dev/null || echo installed)"

cp "$ENV_DIR/defaults.env" "$EVAL/"

# The VAL half is not this run's business. It is declared in the repo's defaults.env, which
# is what tooling reads; the copy installed here has it removed so a run cannot read the
# held-out ids out of its own configuration.
sed -i -E '/^VAL_(TASKS|PUZZLES|GAMES)=/d' "$EVAL/defaults.env"

# The run's task set IS the TRAIN split. This is how arc_agi_2 and arc_agi_3 already
# behave -- what the run directory contains is the whole set as far as the run is
# concerned, and VAL is simply absent rather than hidden. Narrowing TASK_SET here keeps
# `--tasks all` meaning "the set", so nothing has to be guarded at evaluation time and
# nothing the agent reads is untrue. The agent still picks any subset of it freely:
# scheduling and evaluation allocation stay its own.
#
# TB2_FULL_SET=1 restores all 89 -- used only when measuring a finished nomination on
# VAL, which reads the split from the repo's defaults.env, not this copy.
if [ "${TB2_FULL_SET:-0}" != "1" ]; then
    ( set -a; . "$ENV_DIR/defaults.env"; set +a
      python3 - "$EVAL/defaults.env" "$TRAIN_TASKS" <<'PY'
import re, sys
path, train = sys.argv[1], sys.argv[2]
src = open(path).read()
src = re.sub(r'^TASK_SET="[^"]*"',
             'TASK_SET="%s"' % train,
             src, count=1, flags=re.M)
open(path, "w").write(src)
PY
    )
    echo "[setup] TASK_SET narrowed to the frozen TRAIN split: $( \
        ( . "$EVAL/defaults.env"; echo "$TASK_SET" ) | tr ',' '\n' | wc -l) tasks"
fi
[ -f "$ENV_DIR/configure-docker-pool.sh" ] && \
    cp "$ENV_DIR/configure-docker-pool.sh" "$EVAL/"

cp "$ENV_DIR/ENVIRONMENT.md" "$WS/ENVIRONMENT.md"
cp "$ENV_DIR/run.sh" "$WS/run.sh"
chmod +x "$WS/run.sh"

# Where the edit surface lives, relative to the run directory. harbor imports the
# agent as `terminus_2.terminus_2:Terminus2`, so the source must sit in a
# directory named `terminus_2` on PYTHONPATH — agent/ is that PYTHONPATH root.
# Declaring the real path means the agent is edited where it actually runs; no
# staging copy stands between what is edited and what is measured.
echo "agent/terminus_2" > "$WS/.target"

# --- The edit surface --------------------------------------------------------
# harbor ships the agent inside site-packages; copy it out so it can be edited.
TERMINUS_SRC="$EVAL/.venv/lib/python3.12/site-packages/harbor/agents/terminus_2"
[ -d "$TERMINUS_SRC" ] || { echo "[setup] no terminus_2 source at $TERMINUS_SRC" >&2; exit 1; }

# TB2_AGENT_SRC starts this run from an agent someone else left behind, instead of
# the one harbor ships — so a run can continue from a previous run's best rather
# than from scratch. It names a directory holding the contents of the terminus_2
# package (the same files this environment declares in .target). The files are
# COPIED, so the run stays standalone and editing them cannot reach back into
# whatever produced them.
#
# Note what this changes about the numbers: the inherited agent becomes this run's
# `.target_pristine` below, so "unchanged" here means what this run was handed, not
# what harbor ships. A baseline measured in this run is a baseline of the inherited
# agent, and is NOT comparable to a cold run's baseline.
AGENT_SRC_DIR="${TB2_AGENT_SRC:-$TERMINUS_SRC}"
if [ -n "${TB2_AGENT_SRC:-}" ]; then
    [ -d "$AGENT_SRC_DIR" ] || {
        echo "[setup] TB2_AGENT_SRC is not a directory: $AGENT_SRC_DIR" >&2; exit 1; }
    [ -f "$AGENT_SRC_DIR/terminus_2.py" ] || {
        echo "[setup] agent source $AGENT_SRC_DIR has no terminus_2.py — it must hold" >&2
        echo "[setup] the contents of the terminus_2 package, not the directory above it." >&2
        exit 1
    }
fi

mkdir -p "$WS/agent"
if [ -d "$WS/agent/terminus_2" ]; then
    echo "[setup] $WS/agent/terminus_2 already exists — leaving it alone"
else
    # Everything the source holds, not just the modules named here: an agent may
    # have been split into more files than it started with, and copying only known
    # names would drop them silently. Compiled bytecode is stale by construction.
    mkdir -p "$WS/agent/terminus_2"
    rsync -a --exclude='__pycache__/' --exclude='*.pyc' \
        "$AGENT_SRC_DIR/" "$WS/agent/terminus_2/"
    if [ -n "${TB2_AGENT_SRC:-}" ]; then
        echo "[setup] agent at $WS/agent/terminus_2 (inherited from $AGENT_SRC_DIR)"
        # Recorded so a finished run says what it started from. Without it a
        # warm-started run is indistinguishable from a cold one afterwards, and its
        # baseline would be silently misread as the environment's own.
        printf '%s\n' "$AGENT_SRC_DIR" > "$WS/.agent_source"
    else
        echo "[setup] agent at $WS/agent/terminus_2 (shipped by harbor)"
    fi
fi

# The pristine is what THIS run was handed, which is what run.sh's capability check
# compares against — so an inherited agent's own capability lines are the baseline,
# and only edits made during this run can trip it.
rm -rf "$WS/.target_pristine"
mkdir -p "$WS/.target_pristine"
rsync -a --exclude='__pycache__/' --exclude='*.pyc' \
    "$WS/agent/terminus_2/" "$WS/.target_pristine/"

echo "[setup] terminal-bench 2.1 environment installed in $WS"
