#!/bin/bash
#SBATCH --job-name=evolve
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --exclusive
# No --partition and no --nodelist here: both are properties of one cluster. Choose
# them at submit time — `sbatch -p <partition> ...`, or the SBATCH_PARTITION and
# SBATCH_NODELIST environment variables, which sbatch reads by itself.
#
# One node property does matter. A container-based evaluation at high concurrency
# exhausts Docker's default address pool, and the environments that run containers
# each ship a configure-docker-pool.sh that widens it; the pre-flight below runs it
# if the environment has one. Where widening the pool needs privileges the job does
# not have, widen it on the nodes beforehand and restrict the job to those nodes.
#
# No --time: nothing bounds the run's wall clock from outside. The agent decides
# when it is done, and EVOLVE_BUDGET_HOURS below is what tells it how long it has.
# Cancel with scancel.
#
# ONE evolve run on a dedicated node.
#
#   sbatch submit_evolve.sbatch <env> <run_dir> [skill_file]
#
#     <env>         environment name under envs/, e.g. tb2_1
#     <run_dir>     where the run lives. Created if absent.
#     <skill_file>  the SKILL.md to run. Defaults to this repo's.
#
# SKILL_ROOT is baked in by the submitting shell (see below), because Slurm copies
# this script into its spool directory before running it — $0 points at that copy,
# not at the repo. Override with FREEEVOLVE_ROOT if submitting by hand.

set -euo pipefail

ENV_NAME="${1:?usage: sbatch submit_evolve.sbatch <env> <run_dir> [skill_file]}"
RUN_DIR="${2:?run_dir required}"
SKILL_FILE="${3:-}"

# Slurm copies this script into its spool directory before running it, so $0 points
# at that copy and the repo cannot be found from it. Export FREEEVOLVE_ROOT when
# submitting:  FREEEVOLVE_ROOT="$PWD" sbatch submit_evolve.sbatch ...
# The fallback below covers running this script directly, outside Slurm.
SKILL_ROOT="${FREEEVOLVE_ROOT:-}"
if [ -z "$SKILL_ROOT" ]; then
    _here="$(cd "$(dirname "$0")" && pwd)"
    [ -x "$_here/evolve.sh" ] && SKILL_ROOT="$_here"
fi
[ -n "$SKILL_ROOT" ] && [ -x "$SKILL_ROOT/evolve.sh" ] || {
    echo "no evolve.sh under FREEEVOLVE_ROOT=${SKILL_ROOT:-<unset>}" >&2
    echo "submit with: FREEEVOLVE_ROOT=/path/to/freeevolve sbatch $(basename "$0") ..." >&2
    exit 1
}

export PATH="$HOME/.local/bin:$PATH"   # uv and claude live here

# Resolve the provider and model before the batch run. Bedrock is the historical
# default; FREEEVOLVE_MODEL_PROVIDER=anthropic selects a regular Claude Code login
# or ANTHROPIC_API_KEY. The worker model remains environment-defined.
# shellcheck source=lib/model_provider.sh
source "$SKILL_ROOT/lib/model_provider.sh"
freeevolve_resolve_model

# The wall clock a STANDALONE run is given, in hours. Fixed here so that standalone runs
# of different environments are given the same budget and can be compared; override per
# launch with EVOLVE_BUDGET_HOURS, or set it to empty to state no duration.
#
# The meta environments are skipped: they state their own duration, and an inner run
# launched by one is told nothing (inner_run.sbatch unsets this).
case "$ENV_NAME" in
    meta|meta_*) ;;
    *) export EVOLVE_BUDGET_HOURS="${EVOLVE_BUDGET_HOURS-12}" ;;
esac

# Passed through to the environment's setup.sh, which reads them if it cares:
#   META_INNER_ENVS    restrict which inner envs a meta run may use
#   TAU3_DATASET_SRC   reuse a prebuilt tau3 dataset instead of regenerating
#                      (empty: the environment generates it, which takes minutes)
export META_INNER_ENVS="${META_INNER_ENVS:-}"
export TAU3_DATASET_SRC="${TAU3_DATASET_SRC:-}"
# HARBOR_ROOT is an existing harbor checkout to read benchmark adapters from. Left
# unset on purpose: the environments that need one clone it themselves at a pinned
# commit and cache it (lib/ensure_harbor.sh). Set it only to point at a checkout you
# already have, and it is then used verbatim.
if [ -n "${HARBOR_ROOT:-}" ]; then export HARBOR_ROOT; else unset HARBOR_ROOT || true; fi
# arc_agi_2's equivalents of TAU3_DATASET_SRC, and the same pair for tb2_1 and
# frontier_cs. Only exported when set, so the environment falls back to its own
# default rather than to an empty string.
#   *_AGENT_SRC        start from an agent a previous run left behind
#   FRONTIER_PROBLEMS_SRC  install frontier_cs's problem tree from here instead of
#                          the copy vendored beside its setup.sh
#   INNER_EVOLVER_MODEL    the model every inner evolver runs on
#   INNER_EVOLVER_MODEL_<ENV>  the same, for one inner environment only. A
#                          multi-environment meta run needs it: each environment's
#                          earlier results were produced at a particular model
#                          generation, and one global value cannot match both.
for _v in ARC_DATASET_SRC ARC_TASK_COUNT ARC_SPLIT ARC_AGENT_SRC \
          ARC3_GAMES ARC3_GAME_COUNT ARC3_GAME_SEED ARC3_GAMES_SRC ARC3_AGENT_SRC \
          TB2_AGENT_SRC TAU3_AGENT_SRC \
          FRONTIER_AGENT_SRC FRONTIER_PROBLEMS_SRC \
          INNER_EVOLVER_MODEL \
          INNER_EVOLVER_MODEL_ARC_AGI_2 INNER_EVOLVER_MODEL_ARC_AGI_3 \
          INNER_EVOLVER_MODEL_TAU3 \
          INNER_EVOLVER_MODEL_TB2_1 INNER_EVOLVER_MODEL_TB2_DA \
          INNER_EVOLVER_MODEL_FRONTIER_CS \
          INNER_EVOLVER_MODEL_HLE INNER_EVOLVER_MODEL_GAIA2_CLI; do
    if [ -n "${!_v:-}" ]; then export "$_v"; else unset "$_v" || true; fi
done
# Do not let an ambient ANTHROPIC_MODEL from the submitting shell win over the
# run's own pinned settings.
unset ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL

mkdir -p "$RUN_DIR"

echo "=================================================================="
echo "job id     : ${SLURM_JOB_ID:-<none>}"
echo "node       : $(hostname)"
echo "env        : ${ENV_NAME}"
echo "run dir    : ${RUN_DIR}"
echo "skill      : ${SKILL_FILE:-<repo default>}"
echo "provider   : ${FREEEVOLVE_MODEL_PROVIDER}"
echo "evolver    : ${EVOLVER_MODEL}"
[ -n "${META_INNER_ENVS}" ] && echo "inner envs : ${META_INNER_ENVS}"
echo "started    : $(date -Is)"
echo "=================================================================="

# --- Pre-flight: can this node reach the selected Claude provider? -----------
echo "[preflight] verifying claude -> ${FREEEVOLVE_MODEL_PROVIDER} ..."
if ! timeout 300 claude -p 'reply with OK' >/dev/null 2>&1; then
    echo "[preflight] FAILED — claude/${FREEEVOLVE_MODEL_PROVIDER} not working on $(hostname). Aborting." >&2
    exit 1
fi
echo "[preflight] OK"

# --- Pre-flight: Docker pool (container-based environments need it) ----------
POOL_SCRIPT="$SKILL_ROOT/envs/$ENV_NAME/configure-docker-pool.sh"
if [ -f "$POOL_SCRIPT" ]; then
    echo "[preflight] configuring Docker pool ..."
    bash "$POOL_SCRIPT" || echo "[preflight] WARNING: pool configuration failed or was skipped."
fi

# --- Run ---------------------------------------------------------------------
# evolve.sh installs the environment into RUN_DIR, then hands it to one agent.
if [ -n "$SKILL_FILE" ]; then
    bash "$SKILL_ROOT/evolve.sh" "$ENV_NAME" "$RUN_DIR" "$SKILL_FILE"
else
    bash "$SKILL_ROOT/evolve.sh" "$ENV_NAME" "$RUN_DIR"
fi

echo "=================================================================="
echo "finished   : $(date -Is)"
echo "run dir    : ${RUN_DIR}"
RESULT_MD="$(ls "$RUN_DIR"/workspace-*/best/RESULT.md 2>/dev/null | head -1)"
if [ -n "$RESULT_MD" ]; then
    echo "--- ${RESULT_MD#$RUN_DIR/} ---"
    cat "$RESULT_MD"
else
    echo "(no best/RESULT.md in the workspace)"
fi
echo "=================================================================="
