#!/usr/bin/env bash
# Install the Frontier-CS (algorithmic track) environment into a run directory.
#
#   setup.sh <run_dir>
#
# Creates, inside the run directory:
#   ENVIRONMENT.md          the goal and how to evaluate
#   run.sh                  the evaluation
#   eval/                   harbor's venv, the problem tree, the patched adapter
#                           copy, the generated dataset, the defaults
#   agent/terminus_2/       the terminus-2 agent (the edit surface), at the package
#                           path harbor imports it from
#   .target                 declares that edit surface: `agent/terminus_2`
#   .target_pristine/       what this run was handed, for run.sh's guards
#
# Honours, from the environment:
#   FRONTIER_AGENT_SRC      start from an agent a previous run left behind
#   FRONTIER_PROBLEMS_SRC   install the problem tree from here instead of the
#                           checkout resolved below
#   FRONTIER_CS_ROOT        a Frontier-CS checkout to take the problem tree from.
#                           Unset: one is cloned at a pinned commit and cached
#                           (lib/ensure_checkout.sh)
#
# The problem tree is not vendored beside this script: it is 2.6 GB, essentially all
# generated test data, and upstream (MIT) publishes it. It is cloned once into the
# shared cache and reused by every run directory afterwards. Docker Hub is reached
# once too, for the published judge image. The run directory is standalone once set
# up: nothing in it refers back to this directory or to the cache. Idempotent, and
# never clobbers an existing agent.
set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${1:?usage: setup.sh <run_dir>}"
mkdir -p "$WS"
WS="$(cd "$WS" && pwd)"
EVAL="$WS/eval"

# shellcheck source=defaults.env
source "$ENV_DIR/defaults.env"

PUBLISHED_JUDGE_IMAGE="${PUBLISHED_JUDGE_IMAGE:-yanagiorigami/frontier-cs-harbor-judge:latest}"

for c in uv docker rsync curl; do
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

# --- The evaluation: harbor -------------------------------------------------
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
# VIRTUAL_ENV (e.g. when setup runs from inside another venv's activation) and would
# install harbor somewhere else, leaving the terminus_2 source missing.
uv pip install --quiet --python "$VENV_PY" harbor
# litellm's Bedrock provider needs boto3 at runtime; harbor doesn't pull it in.
# pyyaml is what the adapter reads problem configs with.
uv pip install --quiet --python "$VENV_PY" boto3 pyyaml
echo "[setup] harbor: $("$EVAL/.venv/bin/harbor" --version 2>/dev/null || echo installed)"

# --- The problem tree --------------------------------------------------------
# Two things read it: the adapter, once, to generate the dataset (statements, time
# and memory limits, case counts), and the judge container at every trial, which
# gets ONE problem directory bind-mounted from here.
#
# Installed by hardlink where the filesystem allows it. It is 2.6 GB across 12k
# files, essentially all of it test data, and a byte copy of that per run directory is
# minutes of I/O for data that never changes. Hardlinks make the run directory hold
# real entries — it does not point at anything outside itself — at no extra space. A
# real copy is the fallback, so a cache on another filesystem still works, slowly.
#
# Where it comes from: a pinned upstream clone, kept in the shared cache. The helper
# that makes that clone also deletes upstream's per-problem examples/ from it, since
# those hold reference solutions. So upstream's `oracle` agent cannot be run against
# this tree, which is deliberate.
# shellcheck source=../../lib/ensure_checkout.sh
source "$(cd "$ENV_DIR/../.." && pwd)/lib/ensure_checkout.sh"
ALGO_DIR="$EVAL/$ALGORITHMIC_SUBDIR"
if [ -n "${FRONTIER_PROBLEMS_SRC:-}" ]; then
    PROBLEMS_SRC="$FRONTIER_PROBLEMS_SRC"
elif [ -d "$ALGO_DIR/problems" ] && [ -n "$(ls -A "$ALGO_DIR/problems" 2>/dev/null)" ]; then
    # Already installed here; nothing to resolve, and no reason to spend a clone.
    PROBLEMS_SRC="$ALGO_DIR/problems"
else
    ensure_frontier_cs
    PROBLEMS_SRC="$FRONTIER_CS_ROOT/algorithmic/problems"
fi
if [ -d "$ALGO_DIR/problems" ] && [ -n "$(ls -A "$ALGO_DIR/problems" 2>/dev/null)" ]; then
    echo "[setup] problems already present at $ALGO_DIR/problems — leaving them alone"
else
    [ -d "$PROBLEMS_SRC" ] || { echo "[setup] no problem tree at $PROBLEMS_SRC" >&2; exit 1; }
    mkdir -p "$ALGO_DIR"
    if cp -al "$PROBLEMS_SRC" "$ALGO_DIR/problems" 2>/dev/null; then
        echo "[setup] problems hardlinked from $PROBLEMS_SRC"
    else
        echo "[setup] hardlinking unavailable; copying the problem tree (slow)"
        rsync -a "$PROBLEMS_SRC/" "$ALGO_DIR/problems/"
    fi
fi
_n_problems="$(find "$ALGO_DIR/problems" -mindepth 1 -maxdepth 1 -type d | wc -l)"
echo "[setup] problems: $_n_problems at $ALGO_DIR/problems"
[ "$_n_problems" -gt 0 ] || { echo "[setup] problem tree is empty" >&2; exit 1; }

# --- The adapter copy --------------------------------------------------------
# Vendored beside this script rather than read out of a harbor checkout, so setup
# needs nothing outside this directory. Copied into the run so a run records the
# generator it actually used.
ADAPTER_DIR="$EVAL/adapter"
[ -d "$ADAPTER_DIR" ] || rsync -a --exclude='__pycache__/' --exclude='*.pyc' \
    "$ENV_DIR/adapter/" "$ADAPTER_DIR/"

# The vendored adapter carries one local patch, and everything downstream depends on
# it: the verifier must write a reward.json with exactly one key, or harbor's Mean
# metric reports one entry per reward key and `metrics[0].mean` — which every other
# environment here produces and every reader expects — does not exist at all. Checked
# rather than assumed, because re-vendoring upstream would silently drop it and the
# damage would only show up as a missing field in a finished job.
grep -q '>>> freeevolve patch' \
    "$ADAPTER_DIR/src/frontier_cs_algorithm/task-template/tests/evaluate.py" || {
    echo "[setup] the adapter's tests/evaluate.py is missing the freeevolve patch that" >&2
    echo "[setup] keeps reward.json single-keyed. Without it a job has no" >&2
    echo "[setup] metrics[0].mean. See the patch note in that file." >&2
    exit 1
}

# --- The images --------------------------------------------------------------
# One main image and one judge image for the whole dataset, built/pulled once here
# and named in every generated task.
#
# Without this every task carries its own copy of an identical Dockerfile and harbor
# builds it per task, at the evaluation's concurrency. The layer cache makes most of
# those free eventually, but the FIRST evaluation on a node runs `--concurrency`
# simultaneous cold builds of the same image — each one installing Claude Code, nvm,
# Node 22 and codex — which is where build timeouts and phantom zeros come from.
#
# The judge image is pulled from Docker Hub and retagged to a local name, so no trial
# ever depends on a registry being reachable.
if ! docker image inspect "$JUDGE_IMAGE" >/dev/null 2>&1; then
    echo "[setup] pulling $PUBLISHED_JUDGE_IMAGE"
    docker pull "$PUBLISHED_JUDGE_IMAGE"
    docker tag "$PUBLISHED_JUDGE_IMAGE" "$JUDGE_IMAGE"
fi
echo "[setup] judge image: $JUDGE_IMAGE"

if ! docker image inspect "$MAIN_IMAGE" >/dev/null 2>&1; then
    echo "[setup] building $MAIN_IMAGE (several minutes)"
    docker build -t "$MAIN_IMAGE" \
        "$ADAPTER_DIR/src/frontier_cs_algorithm/task-template/environment"
fi
echo "[setup] main image: $MAIN_IMAGE"

# The judge proxy runs on a stock python image, named in the generated compose file
# rather than in task.toml. Pulled here so a burst of trials does not pull it
# concurrently at container-start time, which is where start timeouts come from.
if ! docker image inspect "$PROXY_IMAGE" >/dev/null 2>&1; then
    echo "[setup] pulling $PROXY_IMAGE"
    docker pull "$PROXY_IMAGE"
fi
echo "[setup] proxy image: $PROXY_IMAGE"

# --- The dataset -------------------------------------------------------------
# Generated from the vendored problem tree by the adapter copy. Invoked as a module
# with THIS venv's python rather than through `uv run`: the adapter's pyproject pins
# `harbor = { path = "../../" }`, which only resolves inside a harbor checkout, and
# uv would abort on a name mismatch anywhere else.
#
# --docker-image / --judge-docker-image write the local tags above into every task,
# so nothing is built or pulled at trial time. The judge's test-data mount stays a
# `${FRONTIER_CS_ALGORITHMIC_PATH}` reference in the generated compose file, which is
# what makes the dataset portable — run.sh supplies the value.
DATASET_DIR="$EVAL/$DATASET_SUBDIR"
if [ ! -d "$DATASET_DIR" ] || [ -z "$(ls -A "$DATASET_DIR" 2>/dev/null)" ]; then
    echo "[setup] generating dataset from $_n_problems problems"
    mkdir -p "$(dirname "$DATASET_DIR")"
    PYTHONPATH="$ADAPTER_DIR/src" "$VENV_PY" -m frontier_cs_algorithm.main \
        --source "$EVAL/frontier-cs" \
        --output-dir "$DATASET_DIR" \
        --docker-image "$MAIN_IMAGE" \
        --judge-docker-image "$JUDGE_IMAGE" \
        > "$EVAL/dataset-generation.log" 2>&1 || {
            echo "[setup] dataset generation failed — see $EVAL/dataset-generation.log" >&2
            tail -30 "$EVAL/dataset-generation.log" >&2
            exit 1
        }
fi
_n_tasks="$(find "$DATASET_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)"
echo "[setup] dataset: $_n_tasks tasks at $DATASET_DIR"
[ "$_n_tasks" = "$_n_problems" ] || {
    echo "[setup] $_n_tasks tasks generated from $_n_problems problems — the task set in" >&2
    echo "[setup] defaults.env names $_n_problems and would not resolve." >&2
    exit 1
}

# The adapter copies a reference solution into a task whenever upstream ships one,
# for the benefit of the `oracle` agent. That puts a worked solution inside the run
# directory, where the agent's host-side control loop can read it. Removed: nothing
# here runs the oracle.
_n_ref="$(find "$DATASET_DIR" -path '*/solution/*' -name '*.cpp' -print -delete 2>/dev/null | wc -l)"
[ "$_n_ref" != "0" ] && echo "[setup] removed $_n_ref reference solution(s) from the dataset"

# --- The evaluation ----------------------------------------------------------
cp "$ENV_DIR/defaults.env" "$EVAL/"
[ -f "$ENV_DIR/configure-docker-pool.sh" ] && \
    cp "$ENV_DIR/configure-docker-pool.sh" "$EVAL/"

cp "$ENV_DIR/ENVIRONMENT.md" "$WS/ENVIRONMENT.md"
cp "$ENV_DIR/run.sh" "$WS/run.sh"
chmod +x "$WS/run.sh"

# Where the edit surface lives, relative to the run directory. harbor imports the
# agent as `terminus_2.terminus_2:Terminus2`, so the source must sit in a directory
# named `terminus_2` on PYTHONPATH — agent/ is that PYTHONPATH root. Declaring the
# real path means the agent is edited where it actually runs; no staging copy stands
# between what is edited and what is measured.
echo "agent/terminus_2" > "$WS/.target"

# --- The edit surface --------------------------------------------------------
# harbor ships the agent inside site-packages; copy it out so it can be edited.
TERMINUS_SRC="$EVAL/.venv/lib/python3.12/site-packages/harbor/agents/terminus_2"
[ -d "$TERMINUS_SRC" ] || { echo "[setup] no terminus_2 source at $TERMINUS_SRC" >&2; exit 1; }

# FRONTIER_AGENT_SRC starts this run from an agent someone else left behind, instead
# of the one harbor ships — so a run can continue from a previous run's best rather
# than from scratch. It names a directory holding the contents of the terminus_2
# package (the same files this environment declares in .target). The files are
# COPIED, so the run stays standalone and editing them cannot reach back into
# whatever produced them.
#
# Note what this changes about the numbers: the inherited agent becomes this run's
# `.target_pristine` below, so "unchanged" here means what this run was handed, not
# what harbor ships. A baseline measured in this run is a baseline of the inherited
# agent, and is NOT comparable to a cold run's baseline.
AGENT_SRC_DIR="${FRONTIER_AGENT_SRC:-$TERMINUS_SRC}"
if [ -n "${FRONTIER_AGENT_SRC:-}" ]; then
    [ -d "$AGENT_SRC_DIR" ] || {
        echo "[setup] FRONTIER_AGENT_SRC is not a directory: $AGENT_SRC_DIR" >&2; exit 1; }
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
    # Everything the source holds, not just the modules named here: an agent may have
    # been split into more files than it started with, and copying only known names
    # would drop them silently. Compiled bytecode is stale by construction.
    mkdir -p "$WS/agent/terminus_2"
    rsync -a --exclude='__pycache__/' --exclude='*.pyc' \
        "$AGENT_SRC_DIR/" "$WS/agent/terminus_2/"
    if [ -n "${FRONTIER_AGENT_SRC:-}" ]; then
        echo "[setup] agent at $WS/agent/terminus_2 (inherited from $AGENT_SRC_DIR)"
        # Recorded so a finished run says what it started from. Without it a
        # warm-started run is indistinguishable from a cold one afterwards, and its
        # baseline would be silently misread as the environment's own.
        printf '%s\n' "$AGENT_SRC_DIR" > "$WS/.agent_source"
    else
        echo "[setup] agent at $WS/agent/terminus_2 (shipped by harbor)"
    fi
fi

# The pristine is what THIS run was handed, which is what run.sh's guards compare
# against — so an inherited agent's own capability lines are the baseline, and only
# edits made during this run can trip them.
rm -rf "$WS/.target_pristine"
mkdir -p "$WS/.target_pristine"
rsync -a --exclude='__pycache__/' --exclude='*.pyc' \
    "$WS/agent/terminus_2/" "$WS/.target_pristine/"

echo "[setup] Frontier-CS environment installed in $WS"
