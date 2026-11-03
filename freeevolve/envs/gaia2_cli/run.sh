#!/usr/bin/env bash
# Evaluate an agent on GAIA2 (CLI mode, ARE exposed as MCP tools).
#
#   ./run.sh --artifacts <dir> [--tasks ids|all] [--attempts n]
#            [--concurrency n] [--agent name] [--model id] [--timeout s]
#
# One task is two containers: the agent's, and an ARE sidecar holding the
# simulated world and serving its apps as MCP tools. The verifier's judge runs on
# Bedrock (see eval/adapter patching at setup) rather than on an OpenAI endpoint.
#
# See README.md for what the configs are and how each is scored.
set -euo pipefail

RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL="$RUN_DIR/eval"
source "$EVAL/defaults.env"

HARBOR="$EVAL/.venv/bin/harbor"
[ -x "$HARBOR" ] || { echo "no harbor at $HARBOR — this run directory is not set up" >&2; exit 2; }
DATASET_DIR="$EVAL/$DATASET_SUBDIR"
[ -d "$DATASET_DIR" ] || { echo "no tasks at $DATASET_DIR" >&2; exit 2; }

ARTIFACTS=""
TASKS="all" ATTEMPTS=1 CONCURRENCY=8 TIMEOUT=""
AGENT="$DEFAULT_AGENT" MODEL="$DEFAULT_MODEL" JUDGE_MODEL="$DEFAULT_JUDGE_MODEL"

while [ $# -gt 0 ]; do
    case "$1" in
        --artifacts)   ARTIFACTS="$2"; shift 2 ;;
        --tasks)       TASKS="$2"; shift 2 ;;
        --attempts)    ATTEMPTS="$2"; shift 2 ;;
        --concurrency) CONCURRENCY="$2"; shift 2 ;;
        --agent)       AGENT="$2"; shift 2 ;;
        --model)       MODEL="$2"; shift 2 ;;
        --judge-model) JUDGE_MODEL="$2"; shift 2 ;;
        --timeout)     TIMEOUT="$2"; shift 2 ;;
        -h|--help)     sed -n '2,12p' "$0"; exit 0 ;;
        *)             echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done
[ -n "$ARTIFACTS" ] || { echo "--artifacts is required" >&2; exit 2; }
mkdir -p "$ARTIFACTS"; ARTIFACTS="$(cd "$ARTIFACTS" && pwd)"

JOB_NAME="eval_$(basename "$ARTIFACTS")_$$"
JOBS_DIR="$ARTIFACTS/jobs"
mkdir -p "$JOBS_DIR"

CMD=(
    "$HARBOR" run
    -p "$DATASET_DIR"
    -a "$AGENT"
    -m "$MODEL"
    --jobs-dir "$JOBS_DIR"
    --job-name "$JOB_NAME"
    -k "$ATTEMPTS"
    -n "$CONCURRENCY"
    # The task tables reference host environment variables; -y auto-confirms so
    # the run never blocks on a prompt.
    -y
    # One aggregate progress bar rather than a redrawing line per trial: stdout
    # here is a file, and the per-trial redraw buries the errors.
    -q
    --environment-build-timeout-multiplier "$ENV_BUILD_TIMEOUT_MULT"
    # The judge runs inside the verifier container, so its model and region have
    # to be injected there rather than merely exported here.
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
echo "[eval] agent=$AGENT model=$MODEL"
echo "[eval] judge=$JUDGE_MODEL"
echo "[eval] log -> $ARTIFACTS/harbor.log"

# --- Model routing ------------------------------------------------------------
# claude-code reads CLAUDE_CODE_USE_BEDROCK from the harness process and then
# passes the Bedrock wiring into its container itself; without it set here the
# agent would look for an Anthropic API key that does not exist on this cluster.
# Credentials come from the instance role, so nothing secret is passed anywhere.
export CLAUDE_CODE_USE_BEDROCK=1
export AWS_REGION="${AWS_REGION:-us-west-2}"
export AWS_DEFAULT_REGION="$AWS_REGION"
export JUDGE_MODEL
# Present but empty: the upstream task table has been patched off the OpenAI path,
# but harbor still resolves any leftover host-env reference at load time, and an
# unset variable aborts the run instead of resolving to nothing.
export OPENAI_API_KEY=""
export OPENAI_BASE_URL=""
# Do not let the submitting shell's Claude Code settings decide which model the
# agent under evaluation uses.
unset ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL || true

RC=0
if [ -n "$TIMEOUT" ]; then
    timeout "${TIMEOUT}s" "${CMD[@]}" > "$ARTIFACTS/harbor.log" 2>&1 || RC=$?
else
    "${CMD[@]}" > "$ARTIFACTS/harbor.log" 2>&1 || RC=$?
fi
[ "$RC" -eq 0 ] || echo "[eval] harbor exited $RC — see $ARTIFACTS/harbor.log"

ln -sfn "$JOBS_DIR/$JOB_NAME" "$ARTIFACTS/job"

# --- Results ------------------------------------------------------------------
# harbor writes its own results and nothing is derived on top of them. Per-config
# breakdown is left to whoever reads it: the config is in each task's directory
# name and in its task.toml metadata.
python3 - "$ARTIFACTS/job/result.json" <<'PY' || true
import json, sys
try:
    stats = json.load(open(sys.argv[1]))["stats"]
except Exception as exc:
    sys.exit(f"[eval] no readable result at {sys.argv[1]}: {exc}")
for name, ev in (stats.get("evals") or {}).items():
    mean = (ev.get("metrics") or [{}])[0].get("mean")
    print(f"[eval] mean={mean} trials={ev.get('n_trials')} errors={ev.get('n_errors')}")
    for exc_type, ids in sorted((ev.get("exception_stats") or {}).items(),
                                key=lambda kv: -len(kv[1])):
        print(f"[eval]   {exc_type}: {len(ids)}")
print(f"[eval] cost=${stats.get('cost_usd')}")
PY
echo "[eval] results -> $ARTIFACTS/job/result.json"
