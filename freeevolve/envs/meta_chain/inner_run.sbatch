#!/bin/bash
#SBATCH --job-name=inner_evolve
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --exclusive
# No --partition and no --nodelist: both are properties of one cluster. Set them
# when submitting, or add the directives here for yours.
#
# What the node has to provide: an inner run is what actually launches containers,
# so its Docker address pool must be wide enough for the concurrency the inner
# environment uses. The preflight below runs configure-docker-pool.sh when the
# environment provides one.
#
# No --time: nothing bounds an inner run's wall clock -- the agent decides when it
# is done.
#
# ONE inner evolve run, in a fully isolated run directory. This is the canonical
# implementation for both backends. Slurm executes it as a batch script;
# meta_chain_local executes the same file with Bash.
#
#   inner_run.sbatch <skill_file> <inner_env> <artifacts_dir>
# Requires FREEEVOLVE_ROOT in the environment.
set -euo pipefail

SKILL="${1:?usage: inner_run.sbatch <skill_file> <inner_env> <artifacts_dir>}"
INNER_ENV="${2:?inner_env required}"
ARTIFACTS="${3:?artifacts_dir required}"
BACKEND="${FREEEVOLVE_META_BACKEND:-slurm}"
case "$BACKEND" in
    slurm|local) ;;
    *) echo "unknown meta-chain backend: $BACKEND" >&2; exit 2 ;;
esac

# This points at the run directory's own copied FreeEvolve tree. Under Slurm it
# cannot be derived from $0 because the script is copied into a spool directory.
SKILL_ROOT="${FREEEVOLVE_ROOT:?FREEEVOLVE_ROOT must be exported by the caller}"
[ -x "$SKILL_ROOT/evolve.sh" ] || {
    echo "no evolve.sh under FREEEVOLVE_ROOT=$SKILL_ROOT" >&2
    exit 1
}

# Batch jobs do not reliably inherit interactive-shell paths. Provider selection
# itself is shared with local runs and may be Bedrock or direct Anthropic.
if [ "$BACKEND" = "slurm" ]; then
    export PATH="$HOME/.local/bin:$PATH"
fi

# Resolve the provider first. The inner evolver uses the outer evolver model by
# default; INNER_EVOLVER_MODEL or INNER_EVOLVER_MODEL_<ENV> pins a different one.
# shellcheck source=../../lib/model_provider.sh
source "$SKILL_ROOT/lib/model_provider.sh"
freeevolve_resolve_model
OUTER_EVOLVER_MODEL="$EVOLVER_MODEL"
#
# INNER_EVOLVER_MODEL selects it globally. INNER_EVOLVER_MODEL_<ENV>, with the
# environment name uppercased, overrides it for one inner environment. This
# supports multi-environment meta-evolution whose environments use different
# model generations.
_PER_ENV_VAR="INNER_EVOLVER_MODEL_$(echo "$INNER_ENV" | tr '[:lower:]-' '[:upper:]_')"
export EVOLVER_MODEL="${!_PER_ENV_VAR:-${INNER_EVOLVER_MODEL:-$OUTER_EVOLVER_MODEL}}"
echo "inner evolv: $EVOLVER_MODEL  (inner env $INNER_ENV)"

# Passed through to the inner environment's setup.sh. tau3 can reuse a prebuilt
# dataset and an existing Harbor checkout.
export TAU3_DATASET_SRC="${TAU3_DATASET_SRC:-}"
if [ -n "${HARBOR_ROOT:-}" ]; then
    export HARBOR_ROOT
else
    unset HARBOR_ROOT || true
fi

# ARC equivalents of TAU3_DATASET_SRC. ARC3_GAMES defines the evolution split,
# so it is forwarded deliberately rather than left to incidental inheritance.
for v in ARC_DATASET_SRC ARC_TASK_COUNT ARC_SPLIT ARC3_GAMES ARC3_GAME_COUNT ARC3_GAMES_SRC; do
    if [ -n "${!v:-}" ]; then
        export "$v"
    else
        unset "$v" || true
    fi
done

# EVOLVE_AGENT_SRC is the generic form of "start from this agent." Translate it
# to every adapter-specific name so an environment cannot silently turn a stacked
# run into a cold run. dummy and gaia2_cli do not support inheritance.
if [ -n "${EVOLVE_AGENT_SRC:-}" ]; then
    export TAU3_AGENT_SRC="$EVOLVE_AGENT_SRC"
    export TB2_AGENT_SRC="$EVOLVE_AGENT_SRC"
    export TB2DA_AGENT_SRC="$EVOLVE_AGENT_SRC"
    export ARC_AGENT_SRC="$EVOLVE_AGENT_SRC"
    export ARC3_AGENT_SRC="$EVOLVE_AGENT_SRC"
    export FRONTIER_AGENT_SRC="$EVOLVE_AGENT_SRC"
    export HLE_AGENT_SRC="$EVOLVE_AGENT_SRC"
    echo "inherit    : $EVOLVE_AGENT_SRC"
else
    unset EVOLVE_AGENT_SRC TAU3_AGENT_SRC TB2_AGENT_SRC TB2DA_AGENT_SRC \
          ARC_AGENT_SRC ARC3_AGENT_SRC FRONTIER_AGENT_SRC HLE_AGENT_SRC || true
fi

# The inner run is told nothing about time: how long it gets is the outer
# evolver's decision. Also drop the outer process's Claude model so the pinned
# inner settings decide.
unset EVOLVE_BUDGET_HOURS || true
unset ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL || true

INNER_DIR="$SKILL_ROOT/envs/$INNER_ENV"
[ -d "$INNER_DIR" ] || {
    echo "no inner environment $INNER_ENV under $SKILL_ROOT/envs" >&2
    exit 1
}

mkdir -p "$ARTIFACTS"
INNER="$ARTIFACTS/run"

echo "=================================================================="
echo "backend    : $BACKEND"
echo "job id     : ${SLURM_JOB_ID:-<none>}"
echo "node       : $(hostname)"
echo "skill      : $SKILL"
echo "inner env  : $INNER_ENV"
echo "provider   : $FREEEVOLVE_MODEL_PROVIDER"
echo "inner model: $EVOLVER_MODEL"
echo "run        : $INNER"
echo "started    : $(date '+%Y-%m-%dT%H:%M:%S%z')"
echo "=================================================================="

# A Slurm node gets an explicit provider preflight because scheduler jobs may not
# inherit the interactive shell's authentication environment. Local execution
# relies on the same Claude configuration already checked by the launcher.
if [ "$BACKEND" = "slurm" ]; then
    if ! timeout 180 claude -p 'reply with OK' >/dev/null 2>&1; then
        echo "[preflight] FAILED -- claude/$FREEEVOLVE_MODEL_PROVIDER not working on $(hostname)." >&2
        exit 1
    fi
    echo "[preflight] claude -> $FREEEVOLVE_MODEL_PROVIDER OK"
fi

# Docker pool preflight belongs to the execution machine in either backend.
POOL_SCRIPT="$INNER_DIR/configure-docker-pool.sh"
if [ -f "$POOL_SCRIPT" ]; then
    bash "$POOL_SCRIPT" ||
        echo "[preflight] WARNING: pool configuration failed or was skipped."
fi

# The run directory is standalone once set up. Whatever the inner evolver leaves
# is the result; nothing is installed or re-measured on top of it.
bash "$SKILL_ROOT/evolve.sh" "$INNER_ENV" "$INNER" "$SKILL" \
    > "$ARTIFACTS/run.log" 2>&1 || true

echo "=================================================================="
echo "finished   : $(date '+%Y-%m-%dT%H:%M:%S%z')"
echo "run dir    : $INNER"
echo "=================================================================="
