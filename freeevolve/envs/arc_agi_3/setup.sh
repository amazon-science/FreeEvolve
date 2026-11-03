#!/usr/bin/env bash
# Install the ARC-AGI-3 environment into a run directory.
#
#   setup.sh <run_dir>
#
# Creates, inside the run directory:
#   ENVIRONMENT.md          the goal and how to evaluate
#   run.sh                  the evaluation
#   eval/                   the venv, the harness, and the games
#   agent/arc3_agent/       the game agent (the edit surface)
#   .target                 declares that edit surface: `agent/arc3_agent`
#
# Environment variables it reads:
#   ARC3_GAMES        comma-separated game ids to install, e.g. ls20,ft09
#   ARC3_GAME_COUNT   how many games to install (a random draw at ARC3_GAME_SEED)
#   ARC3_GAME_SEED    which draw, when ARC3_GAME_COUNT is used (default 0)
#   ARC3_GAMES_SRC    install games from here instead of the vendored copy
#   ARC3_AGENT_SRC    start from an agent someone else left behind rather than the
#                     vendored one, so a run can continue from a previous best
#
# No network is needed: the games are vendored beside this script, already fetched.
# fetch_games.py is what puts them there, and is run by hand when the public set moves.
#
# The run directory is standalone afterwards: nothing in it refers back here.
set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${1:?usage: setup.sh <run_dir>}"
mkdir -p "$WS"
WS="$(cd "$WS" && pwd)"
EVAL="$WS/eval"

command -v uv >/dev/null || { echo "uv not found on PATH" >&2; exit 1; }
command -v rsync >/dev/null || { echo "rsync not found on PATH" >&2; exit 1; }

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
# --python pins the install to THIS venv, so an ambient VIRTUAL_ENV cannot send the
# install somewhere else. Versions are pinned because the games were fetched for this
# engine: a game is Python source that imports arcengine, and an engine that moved on
# would change what the same game does.
uv pip install --quiet --python "$VENV_PY" $TOOLKIT_SPEC
uv pip install --quiet --python "$VENV_PY" $MODEL_CLIENT_SPEC
"$VENV_PY" - <<'PY'
import importlib.metadata as md
for package in ("arc-agi", "arcengine", "litellm", "boto3", "numpy", "tenacity"):
    print(f"[setup] {package} {md.version(package)}")
PY

cp "$ENV_DIR/defaults.env" "$EVAL/"

# The VAL half is not this run's business. It is declared in the repo's defaults.env, which
# is what tooling reads; the copy installed here has it removed so a run cannot read the
# held-out ids out of its own configuration.
sed -i -E '/^VAL_(TASKS|PUZZLES|GAMES)=/d' "$EVAL/defaults.env"
# A reference copy of what the fixed capability was at setup time. defaults.env declares
# the action budget, the attempt clock, the model and the per-call inference, and run.sh
# sources it -- so without this, editing that one file would move every ceiling at once,
# and the CAPABILITY_KNOBS check would not see it (that only diffs the agent directory).
#
# Copied from the INSTALLED file, after the VAL strip above, so the two are identical at
# setup. Copying the repo's version instead would leave the pristine copy holding VAL_*
# that the live one does not, and run.sh would refuse every evaluation.
cp "$EVAL/defaults.env" "$EVAL/.defaults_pristine.env"
cp "$ENV_DIR/ENVIRONMENT.md" "$WS/ENVIRONMENT.md"
cp "$ENV_DIR/run.sh" "$WS/run.sh"
chmod +x "$WS/run.sh"

# --- The harness --------------------------------------------------------------
# Copied in rather than referenced: the run has to still work after this directory
# changes, and the harness is what the run's numbers mean.
rm -rf "$EVAL/harness"
rsync -a --exclude='__pycache__/' --exclude='*.pyc' "$ENV_DIR/harness/" "$EVAL/harness/"

# --- The games ----------------------------------------------------------------
GAMES_DIR="$EVAL/$GAMES_SUBDIR"
GAMES_SRC="${ARC3_GAMES_SRC:-$ENV_DIR/games}"
if [ -d "$GAMES_DIR" ] && [ -n "$(ls -A "$GAMES_DIR" 2>/dev/null)" ]; then
    echo "[setup] games already present at $GAMES_DIR — leaving them alone"
else
    [ -d "$GAMES_SRC" ] || { echo "[setup] no games at $GAMES_SRC" >&2; exit 1; }
    mkdir -p "$GAMES_DIR"
    ALL=()
    while IFS= read -r d; do ALL+=("$d"); done < <(cd "$GAMES_SRC" && ls -d */ 2>/dev/null | tr -d '/' | sort)
    [ "${#ALL[@]}" -gt 0 ] || { echo "[setup] $GAMES_SRC holds no games" >&2; exit 1; }

    if [ -n "${ARC3_GAMES:-}" ]; then
        IFS=',' read -ra CHOSEN <<< "$ARC3_GAMES"
    elif [ -n "${ARC3_GAME_COUNT:-}" ] && [ "${ARC3_GAME_COUNT}" != "0" ]; then
        # A named draw, so the same count and seed always give the same games and a
        # held-out set can be described by naming the seed rather than listing ids.
        mapfile -t CHOSEN < <(SEED="${ARC3_GAME_SEED:-0}" N="$ARC3_GAME_COUNT" \
            python3 -c '
import os, random, sys
games = sys.argv[1:]
random.Random(int(os.environ["SEED"])).shuffle(games)
print("\n".join(sorted(games[: int(os.environ["N"])])))' "${ALL[@]}")
    else
        CHOSEN=("${ALL[@]}")
    fi

    for game in "${CHOSEN[@]}"; do
        game="$(echo "$game" | tr -d '[:space:]')"
        [ -n "$game" ] || continue
        [ -d "$GAMES_SRC/$game" ] || {
            echo "[setup] no such game: $game. Available: ${ALL[*]}" >&2; exit 1; }
        rsync -a "$GAMES_SRC/$game/" "$GAMES_DIR/$game/"
    done
fi
echo "[setup] games: $(ls -A "$GAMES_DIR" | tr '\n' ' ')"
echo "[setup] $(ls -A "$GAMES_DIR" | wc -l) games at $GAMES_DIR"

# --- The edit surface ---------------------------------------------------------
# ARC3_AGENT_SRC starts this run from an agent someone else left behind, instead of the
# vendored one — so a run can continue from a previous run's best rather than from
# scratch. The files are COPIED, so the run stays standalone and editing them cannot
# reach back into whatever produced them.
#
# Note what this changes about the numbers: the inherited agent becomes this run's
# `.target_pristine` below, so "unchanged" here means what this run was handed, not
# what the environment ships. A baseline measured in this run is a baseline of the
# inherited agent and is NOT comparable to a cold run's baseline.
AGENT_DIR="$WS/agent/arc3_agent"
AGENT_SRC_DIR="${ARC3_AGENT_SRC:-$ENV_DIR/agent}"
if [ -d "$AGENT_DIR" ]; then
    echo "[setup] $AGENT_DIR already exists — leaving it alone"
else
    for f in arc3_agent.py run_arc3_agent.py; do
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
    if [ -n "${ARC3_AGENT_SRC:-}" ]; then
        echo "[setup] agent at $AGENT_DIR (inherited from $AGENT_SRC_DIR)"
        printf '%s\n' "$AGENT_SRC_DIR" > "$WS/.agent_source"
    else
        echo "[setup] agent at $AGENT_DIR (vendored)"
    fi
fi

# Where the edit surface lives, relative to the run directory. The harness imports the
# agent as `arc3_agent:ARC3Agent`, so the directory holding the module must be on
# PYTHONPATH — and that is this directory itself, not its parent. Declaring the real
# path means the agent is edited where it runs; no staging copy stands between what is
# edited and what is measured.
echo "agent/arc3_agent" > "$WS/.target"

# The fixed model capability must survive an inheritance. An ancestor that lost it
# would change what every later number in a chain means, silently.
grep -qF "DEFAULT_MAX_TOKENS = $FIXED_MAX_TOKENS" "$AGENT_DIR/run_arc3_agent.py" || {
    echo "[setup] run_arc3_agent.py does not set DEFAULT_MAX_TOKENS = $FIXED_MAX_TOKENS." >&2
    echo "[setup] The model capability is fixed; see ENVIRONMENT.md." >&2
    exit 1
}
grep -qF "DEFAULT_REASONING_EFFORT = \"$FIXED_REASONING_EFFORT\"" "$AGENT_DIR/run_arc3_agent.py" || {
    echo "[setup] run_arc3_agent.py does not set DEFAULT_REASONING_EFFORT = \"$FIXED_REASONING_EFFORT\"." >&2
    echo "[setup] The model capability is fixed; see ENVIRONMENT.md." >&2
    exit 1
}

rm -rf "$WS/.target_pristine"
mkdir -p "$WS/.target_pristine"
rsync -a --exclude='__pycache__/' --exclude='*.pyc' "$AGENT_DIR/" "$WS/.target_pristine/"

# A quick check that the pieces fit together, before an evolver spends an hour finding
# out they do not: load a game, take one action, and score the result. No model call.
echo "[setup] checking the harness against $(ls -A "$GAMES_DIR" | head -1)"
( cd "$WS" && PYTHONPATH="$EVAL/harness" "$VENV_PY" "$EVAL/harness/selfcheck.py" \
    --games-dir "$GAMES_DIR" ) || {
    echo "[setup] the harness self-check failed — this run directory is not usable" >&2
    exit 1
}

echo "[setup] ARC-AGI-3 environment installed in $WS"
