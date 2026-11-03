#!/usr/bin/env bash
# One invocation of the evolver against one environment.
#
#   ./evolve.sh <env> <run_dir> [skill_file]
#
#     <env>         environment name (a directory under envs/) or a path to one
#     <run_dir>     where the run lives, and the agent's cwd. Created if absent.
#     <skill_file>  the SKILL.md to run. Default: this repo's.
#
# The environment's setup.sh INSTALLS the environment into the run directory:
#
#   <run_dir>/ENVIRONMENT.md   the goal, how to evaluate, where results land
#   <run_dir>/run.sh           the evaluation
#   <run_dir>/eval/            whatever run.sh needs to work
#   <run_dir>/.target          one line: where the edit surface lives, relative
#                              to the run directory. Usually `target`, but an
#                              environment whose agent must sit at a particular
#                              path (inside a package tree, a checkout, a venv)
#                              declares that path instead and is edited in place.
#   <run_dir>/workspace-<env>/ EMPTY. everything the agent writes goes here.
#
# evolve.sh then writes <run_dir>/.claude/settings.json, pinning the model the
# EVOLVER itself runs on (override with EVOLVER_MODEL). Without it the run would
# pick up ambient settings from above the run directory and from the submitting
# shell. Note this is a different model from the one the agent under evolution
# uses — that one belongs to the environment.
#
# The run directory is the agent's cwd, so ENVIRONMENT.md, run.sh and the edit
# surface are all right there. Everything it produces — versions, artifacts,
# notes, checkpoints — goes in its workspace, so a finished run reads as what was
# given (the root) vs. what was made (the workspace).
#
# The workspace is named for the environment — workspace-tau3, workspace-meta —
# rather than plain `workspace`. That matters when runs nest: a meta run holds
# inner runs inside its own workspace, and if both levels used the same name, an
# agent resolving a relative path could land in the wrong one. Distinct names per
# level make that impossible.
#
# After setup the run directory is STANDALONE: nothing in it points back at this
# repo, so editing this repo cannot change a running evaluation and two runs
# never share state.
#
# There is no loop here on purpose. If splitting work across fresh contexts is a
# good idea, the agent can spawn them itself (subagents, `claude -p`) and pick
# its own boundaries.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_ARG="${1:?usage: evolve.sh <env> <run_dir> [skill_file]}"
RUN_DIR="${2:?run_dir required}"
SKILL_FILE="${3:-$SKILL_DIR/SKILL.md}"

# Resolve the Claude Code provider and the model that executes the evolution
# skill. This is independent of the worker model configured by the environment.
# shellcheck source=lib/model_provider.sh
source "$SKILL_DIR/lib/model_provider.sh"
freeevolve_resolve_model

# --- Resolve the environment asset: a name under envs/, or a path ------------
if [ -d "$SKILL_DIR/envs/$ENV_ARG" ]; then
    ENV_SRC="$SKILL_DIR/envs/$ENV_ARG"
elif [ -d "$ENV_ARG" ]; then
    ENV_SRC="$(cd "$ENV_ARG" && pwd)"
else
    echo "[evolve] no such environment: $ENV_ARG" >&2
    echo "[evolve] available: $(cd "$SKILL_DIR/envs" && echo */ | tr -d '/')" >&2
    exit 1
fi
[ -f "$ENV_SRC/setup.sh" ] || { echo "[evolve] no setup.sh in $ENV_SRC" >&2; exit 1; }
[ -f "$SKILL_FILE" ] || { echo "[evolve] no skill file at $SKILL_FILE" >&2; exit 1; }
SKILL_FILE="$(cd "$(dirname "$SKILL_FILE")" && pwd)/$(basename "$SKILL_FILE")"

mkdir -p "$RUN_DIR"
RUN_DIR="$(cd "$RUN_DIR" && pwd)"
case "$RUN_DIR" in
    "$SKILL_DIR"|"$SKILL_DIR"/*)
        echo "[evolve] run_dir must live outside the repo ($SKILL_DIR)" >&2
        exit 1 ;;
esac

# --- Install the environment into the run directory --------------------------
# The skill this run is DRIVEN by, exported so a setup.sh can see it. Only the meta
# environments care: there the edit surface is also a skill file, and defaulting it
# to the repo's SKILL.md while the driver came in as argument 3 made the two roles
# diverge silently. Every other environment ignores this.
export EVOLVE_SKILL_FILE="$SKILL_FILE"
echo "[evolve] installing $(basename "$ENV_SRC") into $RUN_DIR"
bash "$ENV_SRC/setup.sh" "$RUN_DIR" 2>&1 | tee "$RUN_DIR/setup.log"

for required in ENVIRONMENT.md run.sh .target; do
    [ -e "$RUN_DIR/$required" ] || {
        echo "[evolve] setup.sh did not create $RUN_DIR/$required" >&2
        exit 1
    }
done

# --- The wall-clock budget ----------------------------------------------------
# Appended by whoever launched this run, not by the environment's setup.sh -- setup.sh is
# shared with the meta environment, which copies the inner environments and launches its
# own inner runs, and an inner run's clock is the outer evolver's to decide.
#
# submit_evolve.sbatch (a standalone launch) sets this, so standalone runs of different
# environments are given the same budget and can be compared. inner_run.sbatch (a meta
# run's launch) unsets it, so an inner run is told nothing about time.
#
# Empty means say nothing at all.
if [ -n "${EVOLVE_BUDGET_HOURS:-}" ]; then
    {
        printf '\n### Duration\n\n'
        printf '**You have %s hours of wall clock from the moment this run starts.**' \
            "$EVOLVE_BUDGET_HOURS"
        printf ' Nothing stops\nthe job before then, and nothing continues it afterwards.\n'
    } >> "$RUN_DIR/ENVIRONMENT.md"
fi

# Where this environment's edit surface lives, relative to the run directory.
TARGET_REL="$(tr -d '[:space:]' < "$RUN_DIR/.target")"
[ -n "$TARGET_REL" ] || { echo "[evolve] $RUN_DIR/.target is empty" >&2; exit 1; }
[ -e "$RUN_DIR/$TARGET_REL" ] || {
    echo "[evolve] .target names $TARGET_REL, which setup.sh did not create" >&2
    exit 1
}

# The agent's own space. Empty; everything it makes goes here. Named for the
# environment so that nested runs never share a workspace name.
WORKSPACE_NAME="workspace-$(basename "$ENV_SRC")"
mkdir -p "$RUN_DIR/$WORKSPACE_NAME"

# Record which skill ran this, so a finished run says what produced it.
cp "$SKILL_FILE" "$RUN_DIR/.skill.md"

# --- Pin the agent's harness config into the run directory -------------------
# Claude Code resolves settings by walking up from its cwd, so without a
# .claude/ here the run would inherit whatever settings happen to sit above the
# run directory, plus whatever the submitting shell exported. That makes the
# evolver's own model ambient — the same experiment would run on a different
# model from a different shell, which is a confound sitting directly on any
# comparison between skills. Write it explicitly instead, so the run records
# which model read the skill.
#
# Bedrock is the reproducibility default, while FREEEVOLVE_MODEL_PROVIDER=anthropic
# uses a regular Claude Code login or ANTHROPIC_API_KEY. Provider-specific routing
# belongs in this run-local settings file; credentials do not.
mkdir -p "$RUN_DIR/.claude"
FREEEVOLVE_SETTINGS="$RUN_DIR/.claude/settings.json" \
FREEEVOLVE_MODEL_PROVIDER="$FREEEVOLVE_MODEL_PROVIDER" \
EVOLVER_MODEL="$EVOLVER_MODEL" \
AWS_REGION="${AWS_REGION:-}" \
python3 - <<'PY'
import json
import os
from pathlib import Path

provider = os.environ["FREEEVOLVE_MODEL_PROVIDER"]
model = os.environ["EVOLVER_MODEL"]
settings_env = {"ANTHROPIC_MODEL": model}
if provider == "bedrock":
    settings_env.update(
        {
            "CLAUDE_CODE_USE_BEDROCK": "1",
            "AWS_REGION": os.environ["AWS_REGION"],
        }
    )

path = Path(os.environ["FREEEVOLVE_SETTINGS"])
path.write_text(json.dumps({"env": settings_env}, indent=2) + "\n")
PY

{
    printf 'FREEEVOLVE_MODEL_PROVIDER=%q\n' "$FREEEVOLVE_MODEL_PROVIDER"
    printf 'EVOLVER_MODEL=%q\n' "$EVOLVER_MODEL"
    if [ "$FREEEVOLVE_MODEL_PROVIDER" = "bedrock" ]; then
        printf 'AWS_REGION=%q\n' "$AWS_REGION"
    fi
} > "$RUN_DIR/.freeevolve-model.env"

# --- Run ---------------------------------------------------------------------
# Strip YAML frontmatter from the skill, if it has any.
PROMPT="$(sed '1{/^---$/!q;};1,/^---$/d' "$SKILL_FILE")

---

Everything is in your cwd. Paths here are relative to it:

    ./ENVIRONMENT.md   the goal, how to evaluate, where results land
    ./run.sh           the evaluation
    ./${TARGET_REL}    the agent you are improving — what run.sh evaluates
    ./${WORKSPACE_NAME}/   empty; everything you make goes here

Read ./ENVIRONMENT.md first.

Keep using paths relative to your cwd. Nothing above it is yours, and an absolute
path assembled by hand is how work ends up outside your own directory."

echo "[evolve] launching agent (skill $SKILL_FILE) in $RUN_DIR"
echo "[evolve] provider $FREEEVOLVE_MODEL_PROVIDER; evolver model $EVOLVER_MODEL"
cd "$RUN_DIR"
RC=0
# PYTHONDONTWRITEBYTECODE keeps __pycache__ out of the installed environment.
PYTHONDONTWRITEBYTECODE=1 ANTHROPIC_MODEL="$EVOLVER_MODEL" \
    claude -p "$PROMPT" \
        --permission-mode bypassPermissions \
        --verbose --output-format stream-json \
        > "$RUN_DIR/agent_trace.jsonl" 2>"$RUN_DIR/agent_stderr.log" || RC=$?

echo "[evolve] agent exited rc=${RC}"
if [ -f "$RUN_DIR/$WORKSPACE_NAME/RESULT.md" ]; then
    echo "[evolve] --- RESULT.md ---"
    cat "$RUN_DIR/$WORKSPACE_NAME/RESULT.md"
fi
exit 0
