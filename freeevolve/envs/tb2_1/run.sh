#!/usr/bin/env bash
# Evaluate a terminus-2 agent on terminal-bench 2.1.
#
#   ./run.sh --artifacts <dir> [--tasks ids|all] [--attempts n]
#            [--concurrency n] [--timeout s]
#
# Always evaluates the agent where it lives, at the path declared in .target.
# harbor imports it from there directly — no staging copy stands between what is
# edited and what is measured.
#
# The model, and everything that decides how much inference it buys per attempt,
# are fixed in eval/defaults.env and are not flags here. This script passes them
# to harbor itself and refuses to run if the edit surface has changed a line that
# sets one.
#
# See ENVIRONMENT.md for what the flags mean and where the results land.
# Safe to run many times concurrently, as long as --artifacts differs.
set -euo pipefail

# This script lives at the run-directory root; the evaluation lives in eval/.
RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL="$RUN_DIR/eval"
source "$EVAL/defaults.env"

HARBOR="$EVAL/.venv/bin/harbor"
[ -x "$HARBOR" ] || { echo "no harbor at $HARBOR — this run directory is not set up" >&2; exit 2; }

# The edit surface, as the environment declared it at setup.
TARGET="$RUN_DIR/$(tr -d '[:space:]' < "$RUN_DIR/.target")"
# harbor imports `terminus_2.terminus_2`, so PYTHONPATH must be the directory
# CONTAINING the package, and the package directory itself must keep its name.
TARGET_PARENT="$(dirname "$TARGET")"
ARTIFACTS=""
TASKS="all" ATTEMPTS=1 CONCURRENCY=8
MODEL="$DEFAULT_MODEL" TEMPERATURE="$DEFAULT_TEMPERATURE" TIMEOUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --artifacts)   ARTIFACTS="$2"; shift 2 ;;
        --tasks)       TASKS="$2"; shift 2 ;;
        --attempts)    ATTEMPTS="$2"; shift 2 ;;
        --concurrency) CONCURRENCY="$2"; shift 2 ;;
        --timeout)     TIMEOUT="$2"; shift 2 ;;
        -h|--help)     sed -n '2,18p' "$0"; exit 0 ;;
        --model|--temperature|--reasoning-effort|--max-thinking-tokens)
            echo "$1 is not a flag here: the model capability is fixed." >&2
            echo "It is set in eval/defaults.env, and holding it constant is what" >&2
            echo "makes a change in score mean the agent got better rather than" >&2
            echo "bigger. See ENVIRONMENT.md." >&2
            exit 2 ;;
        *)             echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

[ -n "$ARTIFACTS" ] || { echo "--artifacts is required" >&2; exit 2; }
[ -d "$TARGET" ]    || { echo "no agent at $TARGET — this run directory is not set up" >&2; exit 2; }
[ "$(basename "$TARGET")" = "terminus_2" ] || {
    echo "the agent directory must be named terminus_2 (harbor imports it by that" >&2
    echo "name); found $(basename "$TARGET"). Do not rename or move it." >&2
    exit 2
}
mkdir -p "$ARTIFACTS"; ARTIFACTS="$(cd "$ARTIFACTS" && pwd)"

# --- The fixed capability must still be fixed --------------------------------
# The knobs live in the agent's constructor signature, so they cannot be checked
# by looking for a particular value the way a module-level constant could be.
# What can be checked is that the edit did not touch them: compare the edit
# surface against the pristine copy setup.sh kept, and refuse if any changed line
# mentions one. A run whose score came from buying more inference teaches nothing
# about how to build a better agent, and that is the improvement this environment
# is not asking for.
#
# This does mean an innocuous edit to a line that merely names one of these — a
# reflowed docstring, say — is refused too. That is the intended direction to err
# in: the message says which line, and moving the edit off it costs a minute.
PRISTINE="$RUN_DIR/.target_pristine"
if [ -d "$PRISTINE" ] && [ -n "${CAPABILITY_KNOBS:-}" ]; then
    OFFENDING="$(diff -r -u "$PRISTINE" "$TARGET" 2>/dev/null \
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
# `all` means the set this run contains, which setup.sh narrows to the frozen TRAIN
# split. Nothing is guarded here: the agent picks any subset of the set it was given,
# and VAL is absent from the run rather than refused at call time.
if [ "$TASKS" = "all" ]; then
    TASKS="$TASK_SET"
fi

# --- Build the harbor invocation --------------------------------------------
JOB_NAME="eval_$(basename "$ARTIFACTS")_$$"
JOBS_DIR="$ARTIFACTS/jobs"
mkdir -p "$JOBS_DIR"

CMD=(
    "$HARBOR" run
    -d "$DATASET"
    --agent-import-path terminus_2.terminus_2:Terminus2
    -m "$MODEL"
    --jobs-dir "$JOBS_DIR"
    --job-name "$JOB_NAME"
    -k "$ATTEMPTS"
    -n "$CONCURRENCY"
    # Some task.toml files reference host env; -y auto-confirms so the
    # subprocess never blocks waiting on a prompt.
    -y
    # One aggregate progress bar instead of one redrawing line per trial. stdout
    # here is a file, not a terminal, and harbor renders the spinner anyway: a
    # full-set evaluation wrote a 45 MB harbor.log of which essentially all was
    # progress redraw, ~1800 copies of each trial's line. That buries the few
    # hundred lines that say what actually went wrong, and makes the log too big
    # to read. -q keeps the completion count, the metric display, and every error;
    # it drops only the per-trial redraw.
    -q
    # Widen the container build/start window. TB2.1 images are cold on a fresh
    # machine, and a cold-start burst under concurrency otherwise trips the default
    # and produces phantom zeros that look like agent failures but are not. This
    # only changes how long a container is given to come up; the agent's solve
    # budget and the verifier are untouched, and a start failure is still reported
    # as one rather than being retried away.
    --environment-build-timeout-multiplier "$ENV_BUILD_TIMEOUT_MULT"
    # The fixed capability, passed by the harness rather than left to the agent.
    --agent-kwarg "temperature=$TEMPERATURE"
)
# Empty means "do not pass it" — terminus-2's own default, which is where these
# stay. Setting either one would turn extended thinking on.
[ -n "${DEFAULT_REASONING_EFFORT:-}" ] && \
    CMD+=(--agent-kwarg "reasoning_effort=$DEFAULT_REASONING_EFFORT")
[ -n "${DEFAULT_MAX_THINKING_TOKENS:-}" ] && \
    CMD+=(--agent-kwarg "max_thinking_tokens=$DEFAULT_MAX_THINKING_TOKENS")
# TB2.1 namespaces task names ("terminal-bench/fix-git"); harbor's -i/-x accept
# globs, so a bare id is matched with */<id>.
IFS=',' read -ra _tasks <<< "$TASKS"
for t in "${_tasks[@]}"; do
    t="$(echo "$t" | tr -d '[:space:]')"
    [ -n "$t" ] && CMD+=(-i "*/$t")
done
IFS=',' read -ra _excl <<< "$ALWAYS_EXCLUDE"
for t in "${_excl[@]}"; do
    t="$(echo "$t" | tr -d '[:space:]')"
    [ -n "$t" ] && CMD+=(-x "*/$t")
done

# Count what will actually run: the include list minus anything the always-exclude
# list removes from it. Reporting the include count would overstate the evaluation
# by one on a full-set run, which is exactly the kind of small lie that later gets
# divided into a mean.
_n_run=0
for t in "${_tasks[@]}"; do
    t="$(echo "$t" | tr -d '[:space:]')"; [ -n "$t" ] || continue
    case ",$ALWAYS_EXCLUDE," in *",$t,"*) continue ;; esac
    _n_run=$((_n_run + 1))
done
echo "[eval] $_n_run tasks x $ATTEMPTS attempts, concurrency $CONCURRENCY"
echo "[eval] target=$TARGET"
echo "[eval] model=$MODEL temperature=$TEMPERATURE (fixed)"
echo "[eval] log -> $ARTIFACTS/harbor.log"

# --- Run ---------------------------------------------------------------------
RC=0
if [ -n "$TIMEOUT" ]; then
    PYTHONPATH="$TARGET_PARENT" timeout "${TIMEOUT}s" "${CMD[@]}" > "$ARTIFACTS/harbor.log" 2>&1 || RC=$?
else
    PYTHONPATH="$TARGET_PARENT" "${CMD[@]}" > "$ARTIFACTS/harbor.log" 2>&1 || RC=$?
fi
[ "$RC" -eq 0 ] || echo "[eval] harbor exited $RC — see $ARTIFACTS/harbor.log"

# Stable handle on the job dir, whatever it got named.
ln -sfn "$JOBS_DIR/$JOB_NAME" "$ARTIFACTS/job"

# --- Results -----------------------------------------------------------------
# harbor writes its own results; nothing is derived on top of them. What ran, and
# what it scored, is in $ARTIFACTS/job/result.json. See ENVIRONMENT.md.
#
# This used to write a summary.json with a metric of its own — the mean per-test
# fraction. Removed, for two reasons. It was a number this environment invented,
# so it could not be compared with anything published about this benchmark. And
# writing one file per evaluation made that file look like the record of what
# happened: a run that called harbor directly, which is allowed and sometimes the
# right thing to do, then left evaluations with no summary at all and became
# invisible to anyone reading summaries instead of job directories.
python3 - "$ARTIFACTS/job/result.json" <<'PY' || true
import json, sys
try:
    stats = json.load(open(sys.argv[1]))["stats"]
except Exception as exc:
    sys.exit(f"[eval] no readable result at {sys.argv[1]}: {exc}")
for name, ev in (stats.get("evals") or {}).items():
    mean = (ev.get("metrics") or [{}])[0].get("mean")
    print(f"[eval] resolved={mean} trials={ev.get('n_trials')} "
          f"errors={ev.get('n_errors')}")
    for exc_type, ids in sorted((ev.get("exception_stats") or {}).items(),
                                key=lambda kv: -len(kv[1])):
        print(f"[eval]   {exc_type}: {len(ids)}")
print(f"[eval] cost=${stats.get('cost_usd')}")
PY
echo "[eval] results -> $ARTIFACTS/job/result.json"
