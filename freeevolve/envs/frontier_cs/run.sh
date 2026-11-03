#!/usr/bin/env bash
# Evaluate a terminus-2 agent on the Frontier-CS algorithmic track.
#
#   ./run.sh --artifacts <dir> [--tasks ids|all] [--attempts n]
#            [--concurrency n] [--timeout s]
#
# One task set, nothing held out: --tasks picks from it, --attempts repeats it.
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
# shellcheck source=eval/defaults.env
source "$EVAL/defaults.env"

HARBOR="$EVAL/.venv/bin/harbor"
[ -x "$HARBOR" ] || { echo "no harbor at $HARBOR — this run directory is not set up" >&2; exit 2; }

# The edit surface, as the environment declared it at setup.
TARGET="$RUN_DIR/$(tr -d '[:space:]' < "$RUN_DIR/.target")"
# harbor imports `terminus_2.terminus_2`, so PYTHONPATH must be the directory
# CONTAINING the package, and the package directory itself must keep its name.
TARGET_PARENT="$(dirname "$TARGET")"
DATASET_DIR="$EVAL/$DATASET_SUBDIR"
ALGO_DIR="$EVAL/$ALGORITHMIC_SUBDIR"

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
        -h|--help)     sed -n '2,19p' "$0"; exit 0 ;;
        --model|--temperature|--reasoning-effort|--max-thinking-tokens|--agent-timeout)
            echo "$1 is not a flag here: the model capability is fixed." >&2
            echo "It is set in eval/defaults.env, and holding it constant is what" >&2
            echo "makes a change in score mean the agent got better rather than" >&2
            echo "bigger. See ENVIRONMENT.md." >&2
            exit 2 ;;
        --split)
            echo "there is no split here: the 188 problems are one set, all of them" >&2
            echo "visible and all of them measured. Use --tasks. See ENVIRONMENT.md." >&2
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
[ -f "$TARGET/terminus_2.py" ] || {
    echo "no terminus_2.py in $TARGET — harbor imports the agent as" >&2
    echo "$AGENT_IMPORT_PATH, so that module must exist there." >&2
    exit 2
}
[ -d "$DATASET_DIR" ]        || { echo "no dataset at $DATASET_DIR" >&2; exit 2; }
[ -d "$ALGO_DIR/problems" ]  || { echo "no problem tree at $ALGO_DIR/problems" >&2; exit 2; }
mkdir -p "$ARTIFACTS"; ARTIFACTS="$(cd "$ARTIFACTS" && pwd)"

# --- What the edit is not allowed to change ----------------------------------
# Both checks work the same way, and for the same reason: the things being held
# fixed live in a constructor signature or in a path string, so they cannot be
# checked by looking for a particular value the way a module-level constant could
# be. What CAN be checked is that the edit did not touch them — compare the edit
# surface against the pristine copy setup.sh kept, and refuse if any changed line
# matches.
#
# CAPABILITY_KNOBS: the model, its sampling and thinking settings, and the
# per-attempt call budget. A run whose score came from buying more inference
# teaches nothing about how to build a better agent, and that is the improvement
# this environment is not asking for.
#
# INTEGRITY_REFS: the paths that hold the judge's test data. The agent's control
# loop is a host process in this run directory, so it can read them; a score that
# came from reading the expected output is not a score.
#
# Both mean an innocuous edit to a line that merely names one of these — a reflowed
# docstring, say — is refused too. That is the intended direction to err in: the
# message says which line, and moving the edit off it costs a minute.
PRISTINE="$RUN_DIR/.target_pristine"
_diff_lines() {
    # -N so a file the run added is compared against an empty one: without it a
    # whole new module shows up as "Only in ..." and its contents are never looked
    # at, which is the easiest place to put an override.
    diff -r -u -N -x '__pycache__' -x '*.pyc' "$PRISTINE" "$TARGET" 2>/dev/null \
        | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' || true
}
if [ -d "$PRISTINE" ]; then
    CHANGED="$(_diff_lines)"
    if [ -n "${CAPABILITY_KNOBS:-}" ]; then
        OFFENDING="$(printf '%s\n' "$CHANGED" | grep -E "$CAPABILITY_KNOBS" || true)"
        if [ -n "$OFFENDING" ]; then
            echo "refusing to evaluate: this edit changes a line that sets the model" >&2
            echo "capability, which this environment holds fixed. See ENVIRONMENT.md." >&2
            echo "" >&2
            echo "$OFFENDING" | head -20 >&2
            exit 2
        fi
    fi
    if [ -n "${INTEGRITY_REFS:-}" ]; then
        OFFENDING="$(printf '%s\n' "$CHANGED" | grep -E "$INTEGRITY_REFS" || true)"
        if [ -n "$OFFENDING" ]; then
            echo "refusing to evaluate: this edit references the judge's test data, which" >&2
            echo "the agent is not allowed to read. See ENVIRONMENT.md." >&2
            echo "" >&2
            echo "$OFFENDING" | head -20 >&2
            exit 2
        fi
    fi
fi

# --- Resolve the task list ---------------------------------------------------
if [ "$TASKS" = "all" ]; then
    TASKS="$TASK_SET"
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
    # The generated compose files read FRONTIER_CS_ALGORITHMIC_PATH from the host
    # environment, so harbor asks to confirm host-env access; -y auto-confirms so
    # the subprocess never blocks waiting on a prompt.
    -y
    # One aggregate progress bar instead of one redrawing line per trial. stdout here
    # is a file, not a terminal, and harbor renders the spinner anyway — which buries
    # the few hundred lines that say what actually went wrong under megabytes of
    # redraw. -q keeps the completion count, the metric display, and every error.
    -q
    # The fixed per-attempt wall clock. Not a flag: see defaults.env.
    --agent-timeout-multiplier "$AGENT_TIMEOUT_MULT"
    # Widen the container build/start window only. The agent's solve budget and the
    # verifier are untouched, and a start failure is still reported as one rather
    # than retried away.
    --environment-build-timeout-multiplier "$ENV_BUILD_TIMEOUT_MULT"
    --verifier-timeout-multiplier "$VERIFIER_TIMEOUT_MULT"
    # The fixed capability, passed by the harness rather than left to the agent.
    --agent-kwarg "temperature=$TEMPERATURE"
)
# Empty means "do not pass it" — terminus-2's own default, which is where these
# stay. Setting either one would turn extended thinking on.
[ -n "${DEFAULT_REASONING_EFFORT:-}" ] && \
    CMD+=(--agent-kwarg "reasoning_effort=$DEFAULT_REASONING_EFFORT")
[ -n "${DEFAULT_MAX_THINKING_TOKENS:-}" ] && \
    CMD+=(--agent-kwarg "max_thinking_tokens=$DEFAULT_MAX_THINKING_TOKENS")

# harbor matches -i/-x against the task DIRECTORY name for a local dataset, which
# for this dataset is exactly the id in TASK_SET. No glob is needed, and none is
# added: `frontier-cs-algorithm-1*` would quietly pull in 1, 10..17 and 101..192.
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

# Count what will actually run: the include list minus anything the always-exclude
# list removes from it. Reporting the include count would overstate the evaluation,
# which is exactly the kind of small lie that later gets divided into a mean.
_n_run=0
for t in "${_tasks[@]}"; do
    t="$(echo "$t" | tr -d '[:space:]')"; [ -n "$t" ] || continue
    case ",$ALWAYS_EXCLUDE," in *",$t,"*) continue ;; esac
    _n_run=$((_n_run + 1))
done
echo "[eval] $_n_run tasks x $ATTEMPTS attempts, concurrency $CONCURRENCY"
echo "[eval] target=$TARGET"
echo "[eval] model=$MODEL temperature=$TEMPERATURE agent_timeout_mult=$AGENT_TIMEOUT_MULT (fixed)"
echo "[eval] log -> $ARTIFACTS/harbor.log"

# --- Environment -------------------------------------------------------------
# PYTHONPATH: the directory containing the terminus_2 package, so harbor can import
# it by name.
#
# FRONTIER_CS_ALGORITHMIC_PATH: every generated docker-compose.yaml interpolates it
# to bind-mount the one problem being graded into the judge container. Unset, compose
# resolves it to the empty string and the judge starts with no problem at all — every
# trial then scores 0 for a reason that has nothing to do with the agent.
export PYTHONPATH="$TARGET_PARENT${PYTHONPATH:+:$PYTHONPATH}"
export FRONTIER_CS_ALGORITHMIC_PATH="$ALGO_DIR"
export AWS_REGION="${AWS_REGION:-us-west-2}"
export AWS_DEFAULT_REGION="$AWS_REGION"
# The task image ships the Claude Code and Codex CLIs. No credentials are put in the
# container, so they cannot run; emptied here rather than left to inheritance, so an
# evaluation cannot pick up a key from whatever shell launched it.
export ANTHROPIC_API_KEY=""
export OPENAI_API_KEY=""

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
    for exc_type, ids in sorted((ev.get("exception_stats") or {}).items(),
                                key=lambda kv: -len(kv[1])):
        print(f"[eval]   {exc_type}: {len(ids)}")
print(f"[eval] cost=${stats.get('cost_usd')}")
PY
echo "[eval] results -> $ARTIFACTS/job/result.json"
