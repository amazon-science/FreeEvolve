#!/usr/bin/env bash
# Install the terminal-bench 2.1 / deepagents environment into a run directory.
#
#   setup.sh <run_dir>
#
# Creates, inside the run directory:
#   ENVIRONMENT.md        the goal and how to evaluate
#   run.sh                the evaluation
#   eval/                 the venv, the task list, and the harbor adapter
#   agent/harness.py      the deepagents harness (the edit surface)
#   .target               declares that edit surface: `agent/harness.py`
#   workspace-tb2_da/     empty; everything the agent writes
#
# Environment variables it reads:
#   TB2DA_AGENT_SRC   start from a harness someone else left behind instead of this
#                     environment's seed. A path to a .py file, or to a directory
#                     holding harness.py.
#   TB2DA_FULL_SET    1 installs all 89 tasks instead of the frozen TRAIN split.
#
# The run directory is standalone afterwards: nothing in it refers back to this
# directory or to the repo the adapter was vendored from, so editing either cannot
# change a running evaluation. Idempotent, and never clobbers an existing target.
set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${1:?usage: setup.sh <run_dir>}"
mkdir -p "$WS"
WS="$(cd "$WS" && pwd)"
EVAL="$WS/eval"

for c in uv docker curl rsync; do
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

# --- The evaluation: harbor, the deepagents stack, and the adapter ------------
# uv's cache defaults to $HOME, which is shared NFS on this cluster. Several run
# directories being installed at the same time then hardlink out of the same archive
# entry, and every loser of that race dies with "failed to hardlink ... No such file
# or directory" partway through installing. Each job here owns its node, so a
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
# VIRTUAL_ENV (e.g. when setup runs from inside another venv's activation) and would
# install somewhere else, leaving the run directory without a harbor to call.
#
# requirements.txt carries the pins and says where each came from. It is copied into
# the run directory so a finished run records the stack it installed.
cp "$ENV_DIR/requirements.txt" "$EVAL/requirements.txt"
uv pip install --quiet --python "$VENV_PY" -r "$EVAL/requirements.txt"
echo "[setup] harbor: $("$EVAL/.venv/bin/harbor" --version 2>/dev/null || echo installed)"
"$VENV_PY" - <<'PY'
import importlib.metadata as m
names = ["harbor", "deepagents", "langchain", "langchain-core", "langchain-aws",
         "langgraph", "boto3"]
print("[setup] stack: " + "  ".join(f"{n}=={m.version(n)}" for n in names))
PY

# --- The adapter -------------------------------------------------------------
# The pieces that stand between harbor and the harness: harbor's BaseAgent subclass,
# the sandbox backend that puts the agent's shell/file ops inside harbor's per-task
# container, and the Bedrock model builder. Vendored copies of the source repo's
# files, with the divergences marked in harbor_agent.py's docstring; copied into the
# run directory so the run holds its own and reads nothing outside itself.
rsync -a --exclude='__pycache__/' --exclude='*.pyc' "$ENV_DIR/adapter/" "$EVAL/adapter/"
echo "[setup] adapter at $EVAL/adapter ($(ls "$EVAL/adapter" | tr '\n' ' '))"

cp "$ENV_DIR/defaults.env" "$EVAL/"

# The VAL half is not this run's business. It is declared in the repo's defaults.env,
# which is what tooling reads; the copy installed here has it removed so a run cannot
# read the held-out ids out of its own configuration.
sed -i -E '/^VAL_(TASKS|PUZZLES|GAMES)=/d' "$EVAL/defaults.env"

# The run's task set IS the TRAIN split, the same way tb2_1 and the arc environments
# behave: what the run directory contains is the whole set as far as the run is
# concerned, and VAL is simply absent rather than hidden. Narrowing TASK_SET here keeps
# `--tasks all` meaning "the set", so nothing has to be guarded at evaluation time and
# nothing the agent reads is untrue. The agent still picks any subset of it freely.
#
# TB2DA_FULL_SET=1 restores all 89 — used only when measuring a finished nomination on
# VAL, which reads the split from the repo's defaults.env, not this copy.
if [ "${TB2DA_FULL_SET:-0}" != "1" ]; then
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
else
    echo "[setup] TB2DA_FULL_SET=1 — all $( \
        ( . "$EVAL/defaults.env"; echo "$TASK_SET" ) | tr ',' '\n' | wc -l) tasks installed"
fi

[ -f "$ENV_DIR/configure-docker-pool.sh" ] && \
    cp "$ENV_DIR/configure-docker-pool.sh" "$EVAL/"

cp "$ENV_DIR/ENVIRONMENT.md" "$WS/ENVIRONMENT.md"
cp "$ENV_DIR/run.sh" "$WS/run.sh"
chmod +x "$WS/run.sh"

# Where the edit surface lives, relative to the run directory. Here it is a single
# FILE: the harness is one module, and harbor is pointed straight at its path rather
# than importing it as a package, so there is no layout requirement to satisfy.
echo "agent/harness.py" > "$WS/.target"

# --- The edit surface --------------------------------------------------------
# TB2DA_AGENT_SRC starts this run from a harness someone else left behind, instead of
# this environment's seed — so a run can continue from a previous run's best rather
# than from scratch. It names either the .py file itself or a directory holding
# harness.py (the latter is what tools/evaluate_best.py passes). The file is COPIED,
# so the run stays standalone and editing it cannot reach back into whatever produced
# it.
#
# Note what this changes about the numbers: the inherited harness becomes this run's
# `.target_pristine` below, so "unchanged" here means what this run was handed, not
# the seed. A baseline measured in this run is a baseline of the inherited harness,
# and is NOT comparable to a cold run's baseline.
SEED_HARNESS="$ENV_DIR/agent/harness.py"
AGENT_SRC="${TB2DA_AGENT_SRC:-$SEED_HARNESS}"
if [ -n "${TB2DA_AGENT_SRC:-}" ]; then
    if [ -d "$AGENT_SRC" ]; then
        [ -f "$AGENT_SRC/harness.py" ] || {
            echo "[setup] TB2DA_AGENT_SRC is a directory with no harness.py: $AGENT_SRC" >&2
            echo "[setup] it must hold harness.py, or name the .py file directly." >&2
            exit 1
        }
        # Keep the DIRECTORY: a harness that grew sibling modules imports them, and
        # copying only harness.py installs code that cannot import itself.
        AGENT_SRC_DIR="$AGENT_SRC"
        AGENT_SRC="$AGENT_SRC/harness.py"
    fi
    [ -f "$AGENT_SRC" ] || {
        echo "[setup] TB2DA_AGENT_SRC is neither a .py file nor a directory holding" >&2
        echo "[setup] harness.py: $AGENT_SRC" >&2
        exit 1
    }
fi
# A harness that does not define build_agent(model, backend) cannot be run at all, and
# finding that out at trial time costs a whole evaluation.
grep -qE '^[[:space:]]*def[[:space:]]+build_agent[[:space:]]*\(' "$AGENT_SRC" || {
    echo "[setup] $AGENT_SRC defines no build_agent(model, backend). That function is" >&2
    echo "[setup] how the adapter gets an agent out of the harness." >&2
    exit 1
}

mkdir -p "$WS/agent"
if [ -f "$WS/agent/harness.py" ]; then
    echo "[setup] $WS/agent/harness.py already exists — leaving it alone"
else
    cp "$AGENT_SRC" "$WS/agent/harness.py"
    # Sibling modules beside harness.py come with it. A harness is allowed to grow into
    # several files -- splitting middleware or tools out is exactly the kind of
    # structural change this environment exists to permit -- so copying harness.py alone
    # would install an inherited multi-file harness as code that raises
    # ModuleNotFoundError on its first trial.
    if [ -n "${AGENT_SRC_DIR:-}" ]; then
        _extra=""
        for _f in "$AGENT_SRC_DIR"/*.py; do
            [ -f "$_f" ] || continue
            case "$(basename "$_f")" in harness.py) continue ;; esac
            cp "$_f" "$WS/agent/$(basename "$_f")"
            _extra="$_extra $(basename "$_f")"
        done
        [ -n "$_extra" ] && echo "[setup] sibling modules copied with the harness:$_extra"
    fi
    if [ -n "${TB2DA_AGENT_SRC:-}" ]; then
        echo "[setup] harness at $WS/agent/harness.py (inherited from $AGENT_SRC)"
        # Recorded so a finished run says what it started from. Without it a
        # warm-started run is indistinguishable from a cold one afterwards, and its
        # baseline would be silently misread as the environment's own.
        printf '%s\n' "$AGENT_SRC" > "$WS/.agent_source"
    else
        echo "[setup] harness at $WS/agent/harness.py (this environment's seed)"
    fi
fi

# The pristine is what THIS run was handed, which is what run.sh's capability check
# compares against — so an inherited harness's own capability lines are the baseline,
# and only edits made during this run can trip it.
#
# A directory holding one file, not a bare file: run.sh diffs it with `diff -r -N`, so
# a harness that grew extra modules beside harness.py is still compared rather than
# skipped.
rm -rf "$WS/.target_pristine"
mkdir -p "$WS/.target_pristine"
for _f in "$WS/agent"/*.py; do
    [ -f "$_f" ] && cp "$_f" "$WS/.target_pristine/$(basename "$_f")"
done

# eval/defaults.env declares the model, the output cap and the task set. Snapshot it so
# run.sh can refuse to evaluate if it changed since setup — the CAPABILITY_KNOBS check
# diffs the harness only, and would not notice the ceilings themselves moving.
cp "$EVAL/defaults.env" "$EVAL/.defaults_pristine.env"

# Everything the agent writes. Empty; created here so a run directory installed by
# setup.sh alone still says which environment it is.
mkdir -p "$WS/workspace-tb2_da"

echo "[setup] terminal-bench 2.1 / deepagents environment installed in $WS"
