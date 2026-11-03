#!/usr/bin/env bash
# Evaluate a deepagents harness on terminal-bench 2.1.
#
#   ./run.sh --artifacts <dir> [--tasks ids|all] [--attempts n]
#            [--concurrency n] [--timeout s]
#
# Always evaluates the harness where it lives, at the path declared in .target.
# harbor's adapter loads that file directly — no staging copy stands between what is
# edited and what is measured.
#
# The model, and everything that decides how much inference it buys per attempt, are
# fixed in eval/defaults.env and are not flags here. This script passes them to harbor
# itself and refuses to run if the edit surface has changed a line that sets one.
#
# See ENVIRONMENT.md for what the flags mean and where the results land.
# Safe to run many times concurrently, as long as --artifacts differs.
set -euo pipefail

# This script lives at the run-directory root; the evaluation lives in eval/.
RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL="$RUN_DIR/eval"
source "$EVAL/defaults.env"

# --- eval/defaults.env must still be what setup installed --------------------
# It declares the model, the output cap and the task set. Editing it would move the
# fixed capability without touching the harness, and the CAPABILITY_KNOBS check below
# would not notice, because that diffs the edit surface only.
if [ -f "$EVAL/.defaults_pristine.env" ] \
   && ! cmp -s "$EVAL/.defaults_pristine.env" "$EVAL/defaults.env"; then
    echo "refusing to evaluate: eval/defaults.env has changed since setup." >&2
    echo "It declares the model and the per-call output cap, and this environment" >&2
    echo "holds both fixed. See ENVIRONMENT.md." >&2
    echo "" >&2
    # `|| true`: diff exits 1 when the files differ, which under `set -e -o pipefail`
    # would kill the script with status 1 before it reaches the `exit 2` below.
    diff "$EVAL/.defaults_pristine.env" "$EVAL/defaults.env" | head -20 >&2 || true
    exit 2
fi

HARBOR="$EVAL/.venv/bin/harbor"
[ -x "$HARBOR" ] || { echo "no harbor at $HARBOR — this run directory is not set up" >&2; exit 2; }
ADAPTER="$EVAL/adapter"
[ -f "$ADAPTER/harbor_agent.py" ] || {
    echo "no adapter at $ADAPTER — this run directory is not set up" >&2; exit 2; }

# The edit surface, as the environment declared it at setup: a single file.
TARGET="$RUN_DIR/$(tr -d '[:space:]' < "$RUN_DIR/.target")"

ARTIFACTS=""
TASKS="all" ATTEMPTS=1 CONCURRENCY=8
MODEL="$DEFAULT_MODEL" TIMEOUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --artifacts)   ARTIFACTS="$2"; shift 2 ;;
        --tasks)       TASKS="$2"; shift 2 ;;
        --attempts)    ATTEMPTS="$2"; shift 2 ;;
        --concurrency) CONCURRENCY="$2"; shift 2 ;;
        --timeout)     TIMEOUT="$2"; shift 2 ;;
        -h|--help)     sed -n '2,16p' "$0"; exit 0 ;;
        --model|--temperature|--max-tokens|--max-output-tokens|--reasoning-effort|--max-thinking-tokens)
            echo "$1 is not a flag here: the model capability is fixed." >&2
            echo "It is set in eval/defaults.env, and holding it constant is what" >&2
            echo "makes a change in score mean the agent got better rather than" >&2
            echo "bigger. See ENVIRONMENT.md." >&2
            exit 2 ;;
        *)             echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

[ -n "$ARTIFACTS" ] || { echo "--artifacts is required" >&2; exit 2; }
[ -f "$TARGET" ]    || { echo "no harness at $TARGET — this run directory is not set up" >&2; exit 2; }
mkdir -p "$ARTIFACTS"; ARTIFACTS="$(cd "$ARTIFACTS" && pwd)"

if [ -n "${MAX_CONCURRENCY:-}" ] && [ "$CONCURRENCY" -gt "$MAX_CONCURRENCY" ]; then
    echo "--concurrency $CONCURRENCY is above this environment's ceiling of" >&2
    echo "$MAX_CONCURRENCY. Above it the Bedrock account throttles and trials fail" >&2
    echo "for reasons that are not about the agent. See ENVIRONMENT.md." >&2
    exit 2
fi

# --- The fixed capability must still be fixed --------------------------------
# The knobs are arguments to the model the harness is handed, so they cannot be checked
# by looking for a particular value the way a module-level constant could be. What can
# be checked is that the edit did not touch them: compare the edit surface against the
# pristine copy setup.sh kept, and refuse if any changed line mentions one. A score that
# came from buying more inference per call teaches nothing about how to build a better
# agent, and that is the improvement this environment is not asking for.
#
# -r -N because the edit surface is one file today but a harness may split itself into
# more: -N compares a file the run added against an empty one, so a whole new module is
# read rather than reported only as "Only in ...".
#
# This does mean an innocuous edit to a line that merely names one of these — a reflowed
# docstring, say — is refused too. That is the intended direction to err in: the message
# says which line, and moving the edit off it costs a minute.
PRISTINE="$RUN_DIR/.target_pristine"
CHANGED=""
if [ -d "$PRISTINE" ]; then
    CHANGED="$(diff -r -u -N -x '__pycache__' -x '*.pyc' \
        "$PRISTINE" "$(dirname "$TARGET")" 2>/dev/null \
        | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' || true)"
fi
if [ -n "$CHANGED" ] && [ -n "${CAPABILITY_KNOBS:-}" ]; then
    # -i as well as -E: a harness that names its own constant MAX_TOKENS_OVERRIDE and
    # only later spells the kwarg lowercase would otherwise show the definition line as
    # clean. The use site is always caught either way; matching case-insensitively catches
    # the declaration too.
    OFFENDING="$(printf '%s\n' "$CHANGED" | grep -Ei "$CAPABILITY_KNOBS" || true)"
    if [ -n "$OFFENDING" ]; then
        echo "refusing to evaluate: this edit changes a line that sets the model" >&2
        echo "capability, which this environment holds fixed. See ENVIRONMENT.md." >&2
        echo "" >&2
        printf '%s\n' "$OFFENDING" | head -20 >&2
        exit 2
    fi
fi
echo "[eval] capability check: pass"

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
    # The adapter, not the harness: it loads the harness file named by --ak harness=.
    --agent-import-path harbor_agent:DeepAgentsHarbor
    --agent-kwarg "harness=$TARGET"
    -m "$MODEL"
    --env docker
    --jobs-dir "$JOBS_DIR"
    --job-name "$JOB_NAME"
    -k "$ATTEMPTS"
    -n "$CONCURRENCY"
    # Some task.toml files reference host env; -y auto-confirms so the subprocess never
    # blocks waiting on a prompt.
    -y
    # One aggregate progress bar instead of one redrawing line per trial. stdout here is
    # a file, not a terminal, and harbor renders the spinner anyway. -q keeps the
    # completion count, the metric display, and every error; it drops only the per-trial
    # redraw.
    -q
    # Widen the container build/start window. TB2.1 images are cold on a fresh machine,
    # and a cold-start burst under concurrency otherwise trips the default and produces
    # phantom zeros that look like agent failures but are not. This only changes how long
    # a container is given to come up; the agent's solve budget and the verifier are
    # untouched, and a start failure is still reported as one rather than retried away.
    --environment-build-timeout-multiplier "$ENV_BUILD_TIMEOUT_MULT"
)
# TB2.1 namespaces task names ("terminal-bench/fix-git"); harbor's -i/-x accept globs,
# so a bare id is matched with */<id>.
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

# Count what will actually run: the include list minus anything the always-exclude list
# removes from it. Reporting the include count would overstate the evaluation.
_n_run=0
for t in "${_tasks[@]}"; do
    t="$(echo "$t" | tr -d '[:space:]')"; [ -n "$t" ] || continue
    case ",$ALWAYS_EXCLUDE," in *",$t,"*) continue ;; esac
    _n_run=$((_n_run + 1))
done
echo "[eval] $_n_run tasks x $ATTEMPTS attempts, concurrency $CONCURRENCY"
echo "[eval] target=$TARGET"
echo "[eval] model=$MODEL output cap=$DEFAULT_MAX_OUTPUT_TOKENS (fixed)"
echo "[eval] log -> $ARTIFACTS/harbor.log"

# --- Run ---------------------------------------------------------------------
# The adapter runs in this process, not in the container: deepagents drives the model
# from here and reaches the container through harbor's environment. So its imports come
# off PYTHONPATH here, and the fixed output cap is passed to it as an environment
# variable.
#
# AWS_PROFILE: a workstation may set one; cluster nodes typically have none and reach
# Bedrock through the instance role (boto3's default chain). An EMPTY
# AWS_PROFILE makes boto3 fail rather than fall back, so unset it when it is empty.
export PYTHONPATH="$ADAPTER${PYTHONPATH:+:$PYTHONPATH}"
export DEEPAGENTS_MAX_TOKENS="$DEFAULT_MAX_OUTPUT_TOKENS"
export AWS_REGION="${AWS_REGION:-$AWS_REGION_DEFAULT}"
if [ -z "${AWS_PROFILE:-}" ]; then unset AWS_PROFILE; fi
# langchain/litellm aiohttp sessions are bound to one event loop; harbor runs each trial
# in its own loop in its own thread, and the httpx transport is the one that survives it.
export DISABLE_AIOHTTP_TRANSPORT=True

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
# harbor writes its own results; nothing is derived on top of them. What ran, and what
# it scored, is in $ARTIFACTS/job/result.json, with one directory per trial beside it.
# See ENVIRONMENT.md.
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

# A crashed evaluation must not look like a finished one. Printing a non-zero harbor exit
# and still returning 0 means a harness that raises on every trial produces a result.json
# and a clean exit, which whatever called it will report as a real measurement. Exit
# non-zero so the caller has to look. The artifacts are already written either way, so
# nothing is lost by failing here.
if [ "$RC" -ne 0 ]; then
    echo "[eval] FAILED: harbor exited $RC. The results above, if any, are partial." >&2
    exit 3
fi
