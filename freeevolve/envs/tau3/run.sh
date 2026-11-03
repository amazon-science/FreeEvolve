#!/usr/bin/env bash
# Evaluate a tau3-bench agent.
#
#   ./run.sh --artifacts <dir> [--tasks ids|all] [--attempts n]
#            [--concurrency n] [--model id] [--user-model id] [--timeout s]
#
# One installed evolution set: --tasks picks from it, --attempts repeats.
# Source-only held-out tasks are not copied into this run directory.
#
# Always evaluates the agent where it lives, at the path declared in .target.
# harbor imports it from there directly — no staging copy stands between what is
# edited and what is measured.
#
# See ENVIRONMENT.md for what the flags mean and where the results land.
set -euo pipefail

# This script lives at the run-directory root; the evaluation lives in eval/.
RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL="$RUN_DIR/eval"
source "$EVAL/defaults.env"

HARBOR="$EVAL/.venv/bin/harbor"
[ -x "$HARBOR" ] || { echo "no harbor at $HARBOR — this run directory is not set up" >&2; exit 2; }

# The edit surface, as the environment declared it at setup.
TARGET="$RUN_DIR/$(tr -d '[:space:]' < "$RUN_DIR/.target")"
DATASET_DIR="$EVAL/$DATASET_SUBDIR"

ARTIFACTS=""
TASKS="all" ATTEMPTS=1 CONCURRENCY=8 SPLIT="train"
MODEL="$DEFAULT_MODEL" USER_MODEL="$DEFAULT_USER_MODEL"
JUDGE_MODEL="$DEFAULT_JUDGE_MODEL" TIMEOUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --artifacts)   ARTIFACTS="$2"; shift 2 ;;
        --tasks)       TASKS="$2"; shift 2 ;;
        --attempts)    ATTEMPTS="$2"; shift 2 ;;
        --concurrency) CONCURRENCY="$2"; shift 2 ;;
        --split)       SPLIT="$2"; shift 2 ;;
        --model)       MODEL="$2"; shift 2 ;;
        --user-model)  USER_MODEL="$2"; shift 2 ;;
        --judge-model) JUDGE_MODEL="$2"; shift 2 ;;
        --timeout)     TIMEOUT="$2"; shift 2 ;;
        -h|--help)     sed -n '2,13p' "$0"; exit 0 ;;
        *)             echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

[ -n "$ARTIFACTS" ] || { echo "--artifacts is required" >&2; exit 2; }
[ -d "$TARGET" ]    || { echo "no agent at $TARGET — this run directory is not set up" >&2; exit 2; }
[ -f "$TARGET/tau3_llm_agent.py" ] || {
    echo "no tau3_llm_agent.py in $TARGET — harbor imports the agent as" >&2
    echo "$AGENT_IMPORT_PATH, so that module must exist there." >&2
    exit 2
}
[ -d "$DATASET_DIR" ] || { echo "no dataset at $DATASET_DIR" >&2; exit 2; }

mkdir -p "$ARTIFACTS"; ARTIFACTS="$(cd "$ARTIFACTS" && pwd)"

# --- The fixed capability must still be fixed --------------------------------
# The reasoning effort and the output budget are module constants passed into call
# arguments, so they cannot be checked by looking for a particular value the way a
# single setting could be. What can be checked is that the edit did not touch them:
# compare the edit surface against the pristine copy setup.sh kept, and refuse if any
# changed line mentions one. A score that came from buying more inference per attempt
# teaches nothing about how to build a better agent, and that is the improvement this
# environment is not asking for.
#
# This does mean an innocuous edit to a line that merely names one of them — a
# reflowed comment, say — is refused too. That is the intended direction to err in:
# the message says which line, and moving the edit off it costs a minute.
PRISTINE="$RUN_DIR/.target_pristine"
if [ -d "$PRISTINE" ] && [ -n "${CAPABILITY_KNOBS:-}" ]; then
    # -N so a file the run added is compared against an empty one: without it a whole
    # new module shows up as "Only in ..." and its contents are never looked at, which
    # is the easiest place to put an override.
    OFFENDING="$(diff -r -u -N -x '__pycache__' -x '*.pyc' "$PRISTINE" "$TARGET" 2>/dev/null \
        | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' \
        | grep -E "$CAPABILITY_KNOBS" || true)"
    if [ -n "$OFFENDING" ]; then
        echo "refusing to evaluate: this edit changes a line that sets the model" >&2
        echo "capability, which this environment holds fixed. See ENVIRONMENT.md." >&2
        echo "" >&2
        echo "$OFFENDING" | head -20 >&2
        exit 2
    fi
fi

# --- Resolve the task list ---------------------------------------------------
# One installed evolution set. --split survives only so older invocations still
# work; train and all both mean that set. test is rejected rather than aliased:
# an evolver that asks for held-out data should be told it is not installed, not
# handed the set it tuned on under another name.
if [ "$TASKS" = "all" ]; then
    case "$SPLIT" in
        train|all) TASKS="$TRAIN_TASKS" ;;
        test)
            echo "held-out data is not installed in an evolution run;" >&2
            echo "the available 68-task evolution set is train/all. See ENVIRONMENT.md." >&2
            exit 2 ;;
        *)  echo "unknown --split: $SPLIT (expected train or all)" >&2; exit 2 ;;
    esac
fi

# --- Build the harbor invocation --------------------------------------------
JOB_NAME="eval_$(basename "$ARTIFACTS")_$$"
JOBS_DIR="$ARTIFACTS/jobs"
mkdir -p "$JOBS_DIR"

CMD=(
    "$HARBOR" run
    -p "$DATASET_DIR"
    --agent-import-path "$AGENT_IMPORT_PATH"
    -m "$MODEL"
    --jobs-dir "$JOBS_DIR"
    --job-name "$JOB_NAME"
    -k "$ATTEMPTS"
    -n "$CONCURRENCY"
    # tau3's task.toml pulls OPENAI_*/TAU2_* from the host environment, so harbor
    # asks to confirm host-env access; -y auto-confirms so the run never blocks.
    -y
    # Route the verifier's NL-assertion judge to Bedrock. --ve injects the
    # variable directly into the verifier container.
    --ve "TAU2_NL_ASSERTIONS_MODEL=$JUDGE_MODEL"
)
IFS=',' read -ra _tasks <<< "$TASKS"
for t in "${_tasks[@]}"; do
    t="$(echo "$t" | tr -d '[:space:]')"
    [ -n "$t" ] && CMD+=(-i "$t")
done
IFS=',' read -ra _excl <<< "$ALWAYS_EXCLUDE"
for t in "${_excl[@]}"; do
    t="$(echo "$t" | tr -d '[:space:]')"
    [ -n "$t" ] && CMD+=(-x "$t")
done

echo "[eval] ${#_tasks[@]} tasks x $ATTEMPTS attempts, concurrency $CONCURRENCY, split $SPLIT"
echo "[eval] target=$TARGET"
echo "[eval] agent=$MODEL user=$USER_MODEL judge=$JUDGE_MODEL"
echo "[eval] log -> $ARTIFACTS/harbor.log"

# --- Environment for the three container-side model roles --------------------
# TAU2_* are read from the host environment by harbor's compose invocation (user
# simulator) and task.toml resolution (judge).
#
# OPENAI_* must be present but EMPTY: task.toml references
# ${OPENAI_API_KEY}/${OPENAI_BASE_URL} with no default, so an unset variable
# aborts the run. They must be empty rather than placeholders because the
# sidecar passes a truthy OPENAI_API_KEY to LiteLLM as an OpenAI key, which
# breaks the Bedrock call. Empty is "present" for template resolution but falsy
# for the `if api_key:` guard, so Bedrock creds (IMDS) are used instead.
export PYTHONPATH="$TARGET${PYTHONPATH:+:$PYTHONPATH}"
export TAU2_BENCH_ROOT="$EVAL/tau2-bench"
export TAU2_USER_MODEL="$USER_MODEL"
export TAU2_NL_ASSERTIONS_MODEL="$JUDGE_MODEL"
export OPENAI_API_KEY=""
export OPENAI_BASE_URL=""
export AWS_REGION="${AWS_REGION:-us-west-2}"
export AWS_DEFAULT_REGION="$AWS_REGION"

# --- Run ---------------------------------------------------------------------
RC=0
if [ -n "$TIMEOUT" ]; then
    timeout "${TIMEOUT}s" "${CMD[@]}" > "$ARTIFACTS/harbor.log" 2>&1 || RC=$?
else
    "${CMD[@]}" > "$ARTIFACTS/harbor.log" 2>&1 || RC=$?
fi
[ "$RC" -eq 0 ] || echo "[eval] harbor exited $RC — see $ARTIFACTS/harbor.log"

# Stable handle on the job dir, whatever it got named.
ln -sfn "$JOBS_DIR/$JOB_NAME" "$ARTIFACTS/job"

# --- Results -----------------------------------------------------------------
# harbor writes its own results; nothing is derived on top of them. What ran, and
# what it scored, is in $ARTIFACTS/job/result.json. See ENVIRONMENT.md.
python3 - "$ARTIFACTS/job/result.json" <<'PY' || true
import json, sys
try:
    stats = json.load(open(sys.argv[1]))["stats"]
except Exception as exc:
    sys.exit(f"[eval] no readable result at {sys.argv[1]}: {exc}")
for name, ev in (stats.get("evals") or {}).items():
    mean = (ev.get("metrics") or [{}])[0].get("mean")
    print(f"[eval] {name}: mean={mean} "
          f"trials={ev.get('n_trials')} errors={ev.get('n_errors')}")
print(f"[eval] cost=${stats.get('cost_usd')}")
PY
echo "[eval] results -> $ARTIFACTS/job/result.json"
