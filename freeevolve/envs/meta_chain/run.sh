#!/usr/bin/env bash
# Evaluate a SKILL.md by running it as an evolver on an inner environment.
#
#   ./run.sh --artifacts <dir> --inner-env <name> [--from <dir>]
#
# Always evaluates the skill file at the path declared in .target -- the evolver
# under test, edited in place.
#
# ONE inner run per invocation. The canonical backend submits one Slurm job and
# waits for it. meta_chain_local installs this same script with a local backend,
# which executes the same inner runner directly. Whatever the inner run leaves
# behind IS the result; nothing is derived on top of it.
#
# --from starts the inner run from an agent a previous inner run produced, instead
# of the inner environment's own starting agent. What that is worth, and how to
# sequence runs with it, is not decided here.
#
# See ENVIRONMENT.md for what the flags mean and where the results land.
set -euo pipefail

# This script lives at the run-dir root; the evolver it runs lives in eval/.
RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL="$RUN_DIR/eval"
SKILL_ROOT="$EVAL/freeevolve"
BACKEND="$(tr -d '[:space:]' < "$RUN_DIR/.meta_chain_backend" 2>/dev/null || echo slurm)"
case "$BACKEND" in
    slurm|local) ;;
    *) echo "unknown meta-chain backend: $BACKEND" >&2; exit 2 ;;
esac
[ -x "$SKILL_ROOT/evolve.sh" ] || {
    echo "no evolve.sh at $SKILL_ROOT -- this run directory is not set up" >&2
    exit 2
}

# The edit surface, as the environment declared it at setup: a SKILL.md file.
SKILL_FILE="$RUN_DIR/$(tr -d '[:space:]' < "$RUN_DIR/.target")"
ARTIFACTS="" INNER_ENV="" FROM=""

while [ $# -gt 0 ]; do
    case "$1" in
        --artifacts) ARTIFACTS="$2"; shift 2 ;;
        --inner-env) INNER_ENV="$2"; shift 2 ;;
        --from)      FROM="$2"; shift 2 ;;
        -h|--help)   sed -n '2,19p' "$0"; exit 0 ;;
        *)           echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

[ -n "$ARTIFACTS" ] || { echo "--artifacts is required" >&2; exit 2; }
[ -n "$INNER_ENV" ] || {
    echo "--inner-env is required. Available:" >&2
    (cd "$SKILL_ROOT/envs" && echo "  " */ | tr -d '/') >&2
    exit 2
}
[ -f "$SKILL_FILE" ] || {
    echo "no skill file at $SKILL_FILE -- this run directory is not set up" >&2
    exit 2
}
[ -d "$SKILL_ROOT/envs/$INNER_ENV" ] || {
    echo "no inner environment $INNER_ENV under $SKILL_ROOT/envs" >&2
    exit 2
}
if [ "$BACKEND" = "slurm" ]; then
    command -v sbatch >/dev/null || { echo "sbatch not found on PATH" >&2; exit 2; }
    command -v squeue >/dev/null || { echo "squeue not found on PATH" >&2; exit 2; }
fi

mkdir -p "$ARTIFACTS"
ARTIFACTS="$(cd "$ARTIFACTS" && pwd)"
[ "$BACKEND" = "slurm" ] && mkdir -p "$ARTIFACTS/slurm_logs"

# --- Freeze the skill under test, here, synchronously ------------------------
# What gets measured is the evolver as it stands *at this moment* -- which is what
# this evaluation promises. The inner environment takes time to start, so reading
# target/SKILL.md later could silently evaluate an edit made after this call.
#
# Copy it now and hand the backend the copy. Editing target/SKILL.md while this
# evaluation is in flight then works on the next version, with no effect on this
# one.
FROZEN="$ARTIFACTS/.skill_under_test.md"
cp "$SKILL_FILE" "$FROZEN"
echo "[meta] skill frozen: $(md5sum "$FROZEN" | cut -c1-8) ($(wc -l < "$FROZEN") lines)"
SKILL_FILE="$FROZEN"

# --- --from: inherit a starting agent from an earlier inner run ---------------
# Resolve and check it before holding a node or starting a local inner run.
#
# It must point INSIDE this run directory. Keeping the inherited agent local makes
# the result attributable to this meta run and keeps the run self-contained.
if [ -n "$FROM" ]; then
    [ -d "$FROM" ] || {
        echo "--from is not a directory: $FROM" >&2
        exit 2
    }
    FROM="$(cd "$FROM" && pwd)"
    case "$FROM" in
        "$RUN_DIR"/*) ;;
        *)
            echo "--from must be inside this run directory ($RUN_DIR)." >&2
            echo "given: $FROM" >&2
            echo "Point it at an agent an earlier inner run of THIS run produced." >&2
            exit 2
            ;;
    esac

    # A run directory is not itself an agent -- the agent sits somewhere inside
    # it, and a finished run usually holds several candidates.
    if [ -f "$FROM/.target" ]; then
        echo "--from names an inner run directory, not an agent inside it." >&2
        echo "given: $FROM" >&2
        echo "Its .target says which path that run was measured at; its workspace" >&2
        echo "holds whatever else its evolver kept. Name the directory you want." >&2
        exit 2
    fi

    if [ -z "$(ls -A "$FROM" 2>/dev/null)" ]; then
        echo "--from is an empty directory: $FROM" >&2
        echo "The run it belongs to may not have produced an agent." >&2
        exit 2
    fi
    echo "[meta] from=$FROM ($(ls -A "$FROM" | wc -l) files)"
fi

echo "[meta] skill=$SKILL_FILE"
echo "[meta] inner=$INNER_ENV backend=$BACKEND"

# --- Run the inner evolution -------------------------------------------------
# Both backends execute eval/inner_run.sbatch. Under Slurm, sbatch copies it to a
# spool directory and the submitter waits for completion. Locally, Bash executes
# the same canonical implementation in the foreground.
if [ "$BACKEND" = "slurm" ]; then
    JOB="$(sbatch --parsable \
        --export="ALL,FREEEVOLVE_ROOT=$SKILL_ROOT,EVOLVE_AGENT_SRC=$FROM,FREEEVOLVE_META_BACKEND=slurm" \
        --output="$ARTIFACTS/slurm_logs/inner_%j.out" \
        --error="$ARTIFACTS/slurm_logs/inner_%j.err" \
        "$EVAL/inner_run.sbatch" \
        "$SKILL_FILE" "$INNER_ENV" "$ARTIFACTS")"
    echo "$JOB" > "$ARTIFACTS/slurm_job_id.txt"
    echo "[meta] submitted job $JOB"

    while squeue -h -j "$JOB" -o '%T' 2>/dev/null | grep -q .; do
        sleep 60
    done
    echo "[meta] job $JOB finished"
else
    FREEEVOLVE_ROOT="$SKILL_ROOT" \
    EVOLVE_AGENT_SRC="$FROM" \
    FREEEVOLVE_META_BACKEND=local \
        bash "$EVAL/inner_run.sbatch" \
            "$SKILL_FILE" "$INNER_ENV" "$ARTIFACTS"
fi

# --- Results -----------------------------------------------------------------
# Nothing is computed on top of the inner run. What it did is in its own
# directory, at whatever granularity its environment measures -- including the
# results of every evaluation it chose to run.
INNER="$ARTIFACTS/run"
WS="$(ls -d "$INNER"/workspace-* 2>/dev/null | head -1)"
echo "[meta] inner run       -> $INNER"
if [ -n "$WS" ]; then
    echo "[meta] its workspace -> $WS"
    [ -f "$WS/RESULT.md" ] && echo "[meta] it wrote      -> $WS/RESULT.md"
fi
exit 0
