#!/usr/bin/env bash
# Evaluate the ARC-AGI-3 game agent.
#
#   ./run.sh --artifacts <dir> [--tasks ids|all] [--attempts n]
#            [--concurrency n] [--timeout s]
#
# Always evaluates the agent where it lives, at the path declared in .target. The
# harness imports it from there directly — no staging copy stands between what is
# edited and what is measured.
#
# The model, and everything that decides how much inference it buys per call, are fixed
# in eval/defaults.env and the agent source. They are not flags here, and this script
# refuses to run if the edit surface has changed a line that sets one.
#
# See ENVIRONMENT.md for what the flags mean and where the results land.
# Safe to run many times concurrently, as long as --artifacts differs.
set -euo pipefail

RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL="$RUN_DIR/eval"
source "$EVAL/defaults.env"

# --- The declared budget must still be the declared budget --------------------
# defaults.env sets the action budget, the attempt clock, the model and the per-call
# inference, and the line above sources it. It is a plain file in the run directory, so
# editing it would move every one of those ceilings at once -- and the CAPABILITY_KNOBS
# check further down would not notice, because that diffs the agent directory only.
if [ -f "$EVAL/.defaults_pristine.env" ] \
   && ! cmp -s "$EVAL/.defaults_pristine.env" "$EVAL/defaults.env"; then
    echo "refusing to evaluate: eval/defaults.env has changed since setup." >&2
    echo "It declares the action budget, the attempt clock and the model capability," >&2
    echo "and this environment holds all of them fixed. See ENVIRONMENT.md." >&2
    echo "" >&2
    diff "$EVAL/.defaults_pristine.env" "$EVAL/defaults.env" | head -20 >&2
    exit 2
fi

VENV_PY="$EVAL/.venv/bin/python"
[ -x "$VENV_PY" ] || { echo "no venv at $VENV_PY — this run directory is not set up" >&2; exit 2; }

TARGET="$RUN_DIR/$(tr -d '[:space:]' < "$RUN_DIR/.target")"
GAMES_DIR="$EVAL/$GAMES_SUBDIR"

ARTIFACTS=""
TASKS="all" ATTEMPTS=1 CONCURRENCY=8 TIMEOUT=0
MAX_ACTIONS="$DEFAULT_MAX_ACTIONS"
ATTEMPT_TIMEOUT="$DEFAULT_ATTEMPT_TIMEOUT_SEC"
MODEL="$DEFAULT_MODEL"

while [ $# -gt 0 ]; do
    case "$1" in
        --artifacts)       ARTIFACTS="$2"; shift 2 ;;
        --tasks)           TASKS="$2"; shift 2 ;;
        --attempts)        ATTEMPTS="$2"; shift 2 ;;
        --concurrency)     CONCURRENCY="$2"; shift 2 ;;
        --timeout)         TIMEOUT="$2"; shift 2 ;;
        --max-actions|--attempt-timeout)
            echo "$1 is not a flag here: the per-attempt budget is fixed." >&2
            echo "Every attempt gets $DEFAULT_MAX_ACTIONS actions and" >&2
            echo "${DEFAULT_ATTEMPT_TIMEOUT_SEC}s, set in eval/defaults.env. They are held" >&2
            echo "constant for the same reason the model is: an attempt that ran longer" >&2
            echo "or took more actions bought more inference, so a change in score would" >&2
            echo "no longer mean the agent got better. See ENVIRONMENT.md." >&2
            exit 2 ;;
        -h|--help)         sed -n '2,17p' "$0"; exit 0 ;;
        --model|--reasoning-effort|--max-tokens)
            echo "$1 is not a flag here: the model capability is fixed." >&2
            echo "It is set in eval/defaults.env and in the agent source, and holding" >&2
            echo "it constant is what makes a change in score mean the agent got" >&2
            echo "better rather than bigger. See ENVIRONMENT.md." >&2
            exit 2 ;;
        *)                 echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

[ -n "$ARTIFACTS" ] || { echo "--artifacts is required" >&2; exit 2; }
[ -d "$TARGET" ]    || { echo "no agent at $TARGET — this run directory is not set up" >&2; exit 2; }
[ -f "$TARGET/arc3_agent.py" ] || {
    echo "no arc3_agent.py in $TARGET — the harness imports the agent as" >&2
    echo "$AGENT_IMPORT_PATH, so that module must exist there." >&2
    exit 2
}
[ -d "$GAMES_DIR" ] || { echo "no games at $GAMES_DIR" >&2; exit 2; }
mkdir -p "$ARTIFACTS"; ARTIFACTS="$(cd "$ARTIFACTS" && pwd)"

PRISTINE="$RUN_DIR/.target_pristine"
# -N so a file the run added is compared against an empty one: without it a whole new
# module shows up only as "Only in ..." and its contents are never read, which is the
# easiest place to hide something.
CHANGED=""
if [ -d "$PRISTINE" ]; then
    CHANGED="$(diff -r -u -N -x '__pycache__' -x '*.pyc' "$PRISTINE" "$TARGET" 2>/dev/null \
        | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' || true)"
fi

# --- The fixed capability must still be fixed --------------------------------
# The knobs are module constants passed into call arguments, so they cannot be checked
# by looking for a particular value. What can be checked is that the edit did not touch
# them. A score that came from buying more inference per call teaches nothing about how
# to build a better agent.
#
# This does mean an innocuous edit to a line that merely names one of them — a reflowed
# comment, say — is refused too. That is the intended direction to err in: the message
# says which line, and moving the edit off it costs a minute.
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

# --- The game is not the agent's to read -------------------------------------
# The engine and the score live in the harness, in a different process, and the games
# are on this disk because the engine has to load them. An agent that loaded a game
# itself could read its rules out of the source instead of learning them from play, or
# practise on a private copy and then walk the scored session straight to the answer.
# Either one would leave a number that measures nothing.
if [ -n "$CHANGED" ] && [ -n "${ENGINE_PATTERNS:-}" ]; then
    OFFENDING="$(printf '%s\n' "$CHANGED" | grep -E "$ENGINE_PATTERNS" || true)"
    if [ -n "$OFFENDING" ]; then
        echo "refusing to evaluate: this edit reaches for the game engine or the game" >&2
        echo "files. Those belong to the harness, not to the agent. The agent plays" >&2
        echo "through the session it is handed. See ENVIRONMENT.md." >&2
        echo "" >&2
        printf '%s\n' "$OFFENDING" | head -10 >&2
        exit 2
    fi
fi

N_GAMES="$(ls -A "$GAMES_DIR" | wc -l)"
echo "[eval] $( [ "$TASKS" = all ] && echo "$N_GAMES" || echo "$TASKS" ) games x $ATTEMPTS attempts, concurrency $CONCURRENCY"
echo "[eval] target=$TARGET"
echo "[eval] model=$MODEL (fixed)"
echo "[eval] budget=$MAX_ACTIONS actions, ${ATTEMPT_TIMEOUT}s per attempt"
echo "[eval] log -> $ARTIFACTS/eval.log"

export AWS_REGION="${AWS_REGION:-us-west-2}"
export AWS_DEFAULT_REGION="$AWS_REGION"
# Do not let the submitting shell's Claude Code settings decide which model the agent
# under evaluation uses.
unset ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL || true
# The toolkit reads .env from the working directory if one is there, and would take an
# operation mode or a key out of it. Everything here is passed explicitly instead.
unset OPERATION_MODE ENVIRONMENTS_DIR ARC_API_KEY ARC_BASE_URL || true

RC=0
"$VENV_PY" "$EVAL/harness/evaluate.py" \
    --games-dir "$GAMES_DIR" \
    --target "$TARGET" \
    --artifacts "$ARTIFACTS" \
    --model "$MODEL" \
    --tasks "$TASKS" \
    --exclude "${ALWAYS_EXCLUDE:-}" \
    --attempts "$ATTEMPTS" \
    --concurrency "$CONCURRENCY" \
    --max-actions "$MAX_ACTIONS" \
    --attempt-timeout "$ATTEMPT_TIMEOUT" \
    --timeout "$TIMEOUT" \
    --kill-grace "$KILL_GRACE_SEC" \
    --price-in "$PRICE_PER_MTOK_IN" \
    --price-out "$PRICE_PER_MTOK_OUT" \
    > "$ARTIFACTS/eval.log" 2>&1 || RC=$?
[ "$RC" -eq 0 ] || echo "[eval] the evaluation exited $RC — see $ARTIFACTS/eval.log"

# --- Results ------------------------------------------------------------------
# The harness writes its own results; nothing is derived on top of them. What ran and
# what it scored is in $ARTIFACTS/job/result.json. See ENVIRONMENT.md.
python3 - "$ARTIFACTS/job/result.json" <<'PY' || true
import json, sys
try:
    stats = json.load(open(sys.argv[1]))["stats"]
except Exception as exc:
    sys.exit(f"[eval] no readable result at {sys.argv[1]}: {exc}")
for name, ev in (stats.get("evals") or {}).items():
    metrics = {m["name"]: m.get("mean") for m in ev.get("metrics") or []}
    print(f"[eval] rhae={metrics.get('rhae')} official={ev.get('official_score')} "
          f"levels={metrics.get('levels_completed')} actions={metrics.get('actions')}")
    print(f"[eval] trials={ev.get('n_trials')} errors={ev.get('n_errors')} "
          f"not_run={ev.get('n_not_run')}")
    for exc_type, ids in sorted((ev.get("exception_stats") or {}).items(),
                                key=lambda kv: -len(kv[1])):
        print(f"[eval]   {exc_type}: {len(ids)}")
print(f"[eval] cost=${stats.get('cost_usd')}")
PY
echo "[eval] results -> $ARTIFACTS/job/result.json"
