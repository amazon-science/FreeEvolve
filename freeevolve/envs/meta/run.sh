#!/usr/bin/env bash
# Evaluate a SKILL.md by running it as an evolver on an inner environment.
#
#   ./run.sh --artifacts <dir> --inner-env <name>
#
# Always evaluates the skill file at the path declared in .target — the evolver
# under test, edited in place.
#
# ONE inner run per invocation: submits one Slurm job and waits for it. Whatever
# the inner run leaves behind IS the result; nothing is derived on top of it.
# For several inner runs, invoke this several times with different --artifacts;
# they are independent and can proceed at the same time.
#
# For a variant that runs the inner loop on this machine instead of submitting a
# job, see envs/meta_local.
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
[ -d "$SKILL_ROOT/envs/$INNER_ENV" ] || {
    echo "no inner environment $INNER_ENV under $SKILL_ROOT/envs" >&2
    exit 2
}
command -v sbatch >/dev/null || { echo "sbatch not found on PATH" >&2; exit 2; }

mkdir -p "$ARTIFACTS"; ARTIFACTS="$(cd "$ARTIFACTS" && pwd)"
mkdir -p "$ARTIFACTS/slurm_logs"

echo "[meta] skill=$SKILL_FILE"
echo "[meta] inner=$INNER_ENV"

# --- Submit the inner run ----------------------------------------------------
# The job installs the inner environment into <artifacts>/run, invokes evolve.sh
# there, then measures whatever the inner evolver nominated, on the inner
# environment's held-out split.
# FREEEVOLVE_ROOT must be exported: Slurm copies the script into its spool dir,
# so the job cannot find the repo from its own path. Point it at THIS run
# directory's copy, so the inner run uses the tree this meta run was set up with.
JOB="$(sbatch --parsable \
    --export="ALL,FREEEVOLVE_ROOT=$SKILL_ROOT" \
    --output="$ARTIFACTS/slurm_logs/inner_%j.out" \
    --error="$ARTIFACTS/slurm_logs/inner_%j.err" \
    "$EVAL/inner_run.sbatch" \
    "$SKILL_FILE" "$INNER_ENV" "$ARTIFACTS")"
echo "$JOB" > "$ARTIFACTS/slurm_job_id.txt"
echo "[meta] submitted job $JOB"

# --- Wait --------------------------------------------------------------------
while squeue -h -j "$JOB" -o '%T' 2>/dev/null | grep -q .; do
    sleep 60
done
echo "[meta] job $JOB finished"

# --- Results -----------------------------------------------------------------
# Nothing is computed on top of the inner run. What it did is in its own
# directory, at whatever granularity its environment measures — including the
# results of every evaluation it chose to run. Reading it is the job of whoever
# asked for it. See ENVIRONMENT.md.
INNER="$ARTIFACTS/run"
WS="$(ls -d "$INNER"/workspace-* 2>/dev/null | head -1)"
echo "[meta] inner run    -> $INNER"
if [ -n "$WS" ]; then
    echo "[meta] its workspace -> $WS"
    [ -f "$WS/RESULT.md" ] && echo "[meta] it wrote      -> $WS/RESULT.md"
fi
# Explicit: the reporting above is informational, and its absence is not a failure
# of the evaluation. The inner run either happened or it did not, and run.log says.
exit 0
