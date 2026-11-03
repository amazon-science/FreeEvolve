#!/usr/bin/env bash
# Evaluate a SKILL.md by running it as an evolver on an inner environment, with
# the inner loops running on THIS machine rather than submitted as Slurm jobs.
#
#   ./run.sh --artifacts <dir> --inner-env <name>
#
# Always evaluates the skill file at the path declared in .target — the evolver
# under test, edited in place.
#
# ONE inner run per invocation: one full invocation of evolve.sh with that
# SKILL.md, in its own run directory with its own installation of the inner
# environment. For several inner runs, invoke this several times with different
# --artifacts; they are independent and can proceed at the same time.
#
# This is envs/meta with a local backend. Everything else is identical; see
# envs/meta for the Slurm version.
#
# See ENVIRONMENT.md for what the flags mean and where the results land.
set -euo pipefail

# This script lives at the run-dir root; the evolver it runs lives in eval/.
RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL="$RUN_DIR/eval"
SKILL_ROOT="$EVAL/freeevolve"
[ -x "$SKILL_ROOT/evolve.sh" ] || {
    echo "no evolve.sh at $SKILL_ROOT — this run directory is not set up" >&2
    exit 2
}

# The edit surface, as the environment declared it at setup: a SKILL.md file.
SKILL_FILE="$RUN_DIR/$(tr -d '[:space:]' < "$RUN_DIR/.target")"
ARTIFACTS="" INNER_ENV=""

while [ $# -gt 0 ]; do
    case "$1" in
        --artifacts)   ARTIFACTS="$2"; shift 2 ;;
        --inner-env)   INNER_ENV="$2"; shift 2 ;;
        -h|--help)     sed -n '2,17p' "$0"; exit 0 ;;
        *)             echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

[ -n "$ARTIFACTS" ] || { echo "--artifacts is required" >&2; exit 2; }
[ -n "$INNER_ENV" ] || {
    echo "--inner-env is required. Available:" >&2
    (cd "$SKILL_ROOT/envs" && echo "  " */ | tr -d '/') >&2
    exit 2
}
[ -f "$SKILL_FILE" ] || {
    echo "no skill file at $SKILL_FILE — this run directory is not set up" >&2
    exit 2
}

INNER_SRC="$SKILL_ROOT/envs/$INNER_ENV"
[ -d "$INNER_SRC" ] || { echo "no inner environment $INNER_ENV at $INNER_SRC" >&2; exit 2; }

mkdir -p "$ARTIFACTS"; ARTIFACTS="$(cd "$ARTIFACTS" && pwd)"

echo "[meta] skill=$SKILL_FILE"
echo "[meta] inner=$INNER_ENV backend=local"

# --- Run the inner environment -----------------------------------------------
# The model the INNER evolver runs on. PINNED HERE, deliberately independent of
# whatever the outer evolver runs on: the meta metric compares SKILL.md against a
# constant inner model, so a change in outer model can never be mistaken for a
# change in skill quality. Kept identical to envs/meta/inner_run.sbatch.
export EVOLVER_MODEL="global.anthropic.claude-opus-4-8[1m]"
# This process inherits the outer evolver's ANTHROPIC_MODEL. Drop it, so the inner
# run's own pinned settings decide.
unset ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL

# evolve.sh installs the environment into run/ and creates run/workspace/ for the
# inner evolver. Nested one level down so this invocation's own bookkeeping
# (run.log) stays outside the inner run directory. Whatever the inner evolver
# leaves is the result; nothing is installed or re-measured on top of it.
INNER="$ARTIFACTS/run"

bash "$SKILL_ROOT/evolve.sh" "$INNER_ENV" "$INNER" "$SKILL_FILE" \
    > "$ARTIFACTS/run.log" 2>&1 || true

# --- Results -----------------------------------------------------------------
# Nothing is computed on top of the inner run. What it did is in its own
# directory, at whatever granularity its environment measures — including the
# results of every evaluation it chose to run. Reading it is the job of whoever
# asked for it. See ENVIRONMENT.md.
WS="$(ls -d "$INNER"/workspace-* 2>/dev/null | head -1)"
echo "[meta] inner run    -> $INNER"
if [ -n "$WS" ]; then
    echo "[meta] its workspace -> $WS"
    [ -f "$WS/RESULT.md" ] && echo "[meta] it wrote      -> $WS/RESULT.md"
fi
# Explicit: the reporting above is informational, and its absence is not a failure
# of the evaluation. The inner run either happened or it did not, and run.log says.
exit 0
