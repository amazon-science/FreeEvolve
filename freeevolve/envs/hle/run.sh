#!/usr/bin/env bash
# Evaluate the HLE answering agent.
#
#   ./run.sh --artifacts <dir> [--tasks ids|all] [--attempts n]
#            [--concurrency n] [--timeout s]
#
# Always evaluates the agent where it lives, at the path declared in .target.
# harbor imports it from there directly — no staging copy stands between what is
# edited and what is measured.
#
# The model, and everything that decides how much inference it buys per attempt,
# are fixed in eval/defaults.env and the agent source. They are not flags here,
# and this script refuses to run if the edit surface has changed a line that sets
# one.
#
# See ENVIRONMENT.md for what the flags mean and where the results land.
# Safe to run many times concurrently, as long as --artifacts differs.
set -euo pipefail

RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL="$RUN_DIR/eval"
source "$EVAL/defaults.env"

HARBOR="$EVAL/.venv/bin/harbor"
[ -x "$HARBOR" ] || { echo "no harbor at $HARBOR — this run directory is not set up" >&2; exit 2; }

TARGET="$RUN_DIR/$(tr -d '[:space:]' < "$RUN_DIR/.target")"
TARGET_PARENT="$(dirname "$TARGET")"
DATASET_DIR="$EVAL/$DATASET_SUBDIR"

ARTIFACTS=""
TASKS="all" ATTEMPTS=1 CONCURRENCY=8 TIMEOUT=""
MODEL="$DEFAULT_MODEL" JUDGE_MODEL="$DEFAULT_JUDGE_MODEL"

while [ $# -gt 0 ]; do
    case "$1" in
        --artifacts)   ARTIFACTS="$2"; shift 2 ;;
        --tasks)       TASKS="$2"; shift 2 ;;
        --attempts)    ATTEMPTS="$2"; shift 2 ;;
        --concurrency) CONCURRENCY="$2"; shift 2 ;;
        --timeout)     TIMEOUT="$2"; shift 2 ;;
        -h|--help)     sed -n '2,18p' "$0"; exit 0 ;;
        --model|--reasoning-effort|--max-tokens|--judge-model)
            echo "$1 is not a flag here: the model capability is fixed." >&2
            echo "It is set in eval/defaults.env and in the agent source, and holding" >&2
            echo "it constant is what makes a change in score mean the agent got" >&2
            echo "better rather than bigger. See ENVIRONMENT.md." >&2
            exit 2 ;;
        *)             echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

[ -n "$ARTIFACTS" ] || { echo "--artifacts is required" >&2; exit 2; }
[ -d "$TARGET" ]    || { echo "no agent at $TARGET — this run directory is not set up" >&2; exit 2; }
[ -f "$TARGET/hle_agent.py" ] || {
    echo "no hle_agent.py in $TARGET — harbor imports the agent as" >&2
    echo "$AGENT_IMPORT_PATH, so that module must exist there." >&2
    exit 2
}
[ -d "$DATASET_DIR" ] || { echo "no tasks at $DATASET_DIR" >&2; exit 2; }
mkdir -p "$ARTIFACTS"; ARTIFACTS="$(cd "$ARTIFACTS" && pwd)"

PRISTINE="$RUN_DIR/.target_pristine"
# -N so a file the run added is compared against an empty one: without it a whole
# new module shows up only as "Only in ..." and its contents are never read, which
# is the easiest place to hide something.
DIFF_ARGS=(-r -u -N -x '__pycache__' -x '*.pyc')
CHANGED=""
if [ -d "$PRISTINE" ]; then
    CHANGED="$(diff "${DIFF_ARGS[@]}" "$PRISTINE" "$TARGET" 2>/dev/null \
        | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' || true)"
fi

# --- The fixed capability must still be fixed --------------------------------
# The knobs are module constants passed into call arguments, so they cannot be
# checked by looking for a particular value. What can be checked is that the edit
# did not touch them. A score that came from buying more inference per attempt
# teaches nothing about how to build a better agent.
#
# This does mean an innocuous edit to a line that merely names one of them — a
# reflowed comment, say — is refused too. That is the intended direction to err in:
# the message says which line, and moving the edit off it costs a minute.
if [ -n "$CHANGED" ] && [ -n "${CAPABILITY_KNOBS:-}" ]; then
    OFFENDING="$(printf '%s\n' "$CHANGED" | grep -E "$CAPABILITY_KNOBS" || true)"
    if [ -n "$OFFENDING" ]; then
        echo "refusing to evaluate: this edit changes a line that sets the model" >&2
        echo "capability, which this environment holds fixed. See ENVIRONMENT.md." >&2
        echo "" >&2
        printf '%s\n' "$OFFENDING" | head -20 >&2
        exit 2
    fi
fi

# --- The graded answers are on this disk, and are not an input ---------------
# Each task's tests/answer.txt holds what the grader compares against; it lives in
# this run directory because the verifier reads it at grading time. An agent that
# reads it is not solving anything, so an edit that reaches for it — by path, or by
# carrying an answer string inside itself — is refused rather than measured.
if [ -n "$CHANGED" ]; then
    OFFENDING="$(printf '%s\n' "$CHANGED" | grep -E "${ANSWER_PATH_PATTERNS}" || true)"
    if [ -n "$OFFENDING" ]; then
        echo "refusing to evaluate: this edit references the graded answers or the" >&2
        echo "dataset directory. The answers are the grader's, not the agent's input." >&2
        echo "See ENVIRONMENT.md." >&2
        echo "" >&2
        printf '%s\n' "$OFFENDING" | head -10 >&2
        exit 2
    fi
    # And the answers themselves, in case one was pasted in without naming a path.
    # The length floor is deliberately low: HLE answers are often short — "Rxf3, Rf1#"
    # is ten characters — and a floor set to avoid false positives lets exactly the
    # answers most worth pasting through. Erring the other way costs a rename; erring
    # this way costs every number the run produces.
    LEAKED="$(python3 - "$DATASET_DIR" "$TARGET" <<'PY'
import sys
from pathlib import Path

dataset, target = Path(sys.argv[1]), Path(sys.argv[2])
text = []
for path in target.rglob("*"):
    if path.is_file() and "__pycache__" not in path.parts:
        try:
            text.append(path.read_text(errors="ignore"))
        except Exception:
            pass
blob = "\n".join(text)
hits = []
for answer_file in dataset.glob("*/tests/answer.txt"):
    answer = answer_file.read_text(errors="ignore").strip()
    if len(answer) >= 4 and answer in blob:
        hits.append(f"{answer_file.parent.parent.name}: {answer[:60]!r}")
print("\n".join(hits[:5]))
PY
)" || true
    if [ -n "$LEAKED" ]; then
        echo "refusing to evaluate: the edit surface contains graded answers verbatim." >&2
        echo "" >&2
        printf '%s\n' "$LEAKED" >&2
        exit 2
    fi
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
    # Task tables reference host environment; -y auto-confirms so the run never
    # blocks waiting on a prompt.
    -y
    # One aggregate progress bar instead of one redrawing line per trial: stdout
    # here is a file, and the per-trial redraw buries the errors.
    -q
    --environment-build-timeout-multiplier "$ENV_BUILD_TIMEOUT_MULT"
    # The judge runs inside the verifier container, so its model and region have to
    # be injected there rather than merely exported here.
    --ve "JUDGE_MODEL=$JUDGE_MODEL"
    --ve "AWS_REGION=${AWS_REGION:-us-west-2}"
)
if [ "$TASKS" != "all" ]; then
    IFS=',' read -ra _tasks <<< "$TASKS"
    for t in "${_tasks[@]}"; do
        t="$(echo "$t" | tr -d '[:space:]')"
        [ -n "$t" ] && CMD+=(-i "$t")
    done
fi
IFS=',' read -ra _excl <<< "${ALWAYS_EXCLUDE:-}"
for t in "${_excl[@]}"; do
    t="$(echo "$t" | tr -d '[:space:]')"
    [ -n "$t" ] && CMD+=(-x "$t")
done

N_TASKS="$(ls -A "$DATASET_DIR" | wc -l)"
echo "[eval] $( [ "$TASKS" = all ] && echo "$N_TASKS" || echo "$TASKS" ) tasks x $ATTEMPTS attempts, concurrency $CONCURRENCY"
echo "[eval] target=$TARGET"
echo "[eval] agent model=$MODEL (fixed)  judge=$JUDGE_MODEL"
echo "[eval] log -> $ARTIFACTS/harbor.log"

# The edit surface directory itself, not its parent: harbor imports the agent as
# `hle_agent:HLEAgent`, a bare module rather than a package member, and the surface
# directory happens to share the module's name — so pointing at the parent resolves
# `hle_agent` to the directory as a namespace package and the class is not found.
export PYTHONPATH="$TARGET${PYTHONPATH:+:$PYTHONPATH}"
export AWS_REGION="${AWS_REGION:-us-west-2}"
export AWS_DEFAULT_REGION="$AWS_REGION"
export JUDGE_MODEL

RC=0
if [ -n "$TIMEOUT" ]; then
    timeout "${TIMEOUT}s" "${CMD[@]}" > "$ARTIFACTS/harbor.log" 2>&1 || RC=$?
else
    "${CMD[@]}" > "$ARTIFACTS/harbor.log" 2>&1 || RC=$?
fi
[ "$RC" -eq 0 ] || echo "[eval] harbor exited $RC — see $ARTIFACTS/harbor.log"

ln -sfn "$JOBS_DIR/$JOB_NAME" "$ARTIFACTS/job"

# --- Results ------------------------------------------------------------------
# harbor writes its own results; nothing is derived on top of them. What ran and
# what it scored is in $ARTIFACTS/job/result.json. See ENVIRONMENT.md.
python3 - "$ARTIFACTS/job/result.json" <<'PY' || true
import json, sys
try:
    stats = json.load(open(sys.argv[1]))["stats"]
except Exception as exc:
    sys.exit(f"[eval] no readable result at {sys.argv[1]}: {exc}")
for name, ev in (stats.get("evals") or {}).items():
    mean = (ev.get("metrics") or [{}])[0].get("mean")
    print(f"[eval] correct={mean} trials={ev.get('n_trials')} errors={ev.get('n_errors')}")
    for exc_type, ids in sorted((ev.get("exception_stats") or {}).items(),
                                key=lambda kv: -len(kv[1])):
        print(f"[eval]   {exc_type}: {len(ids)}")
print(f"[eval] cost=${stats.get('cost_usd')}")
PY
echo "[eval] results -> $ARTIFACTS/job/result.json"
