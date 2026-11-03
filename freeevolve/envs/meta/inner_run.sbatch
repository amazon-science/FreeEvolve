#!/bin/bash
#SBATCH --job-name=inner_evolve
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --exclusive
# No --partition and no --nodelist: both are properties of one cluster. Set them
# when submitting (SBATCH_PARTITION / SBATCH_NODELIST are read by sbatch itself), or
# add the directives here for yours.
#
# What the node has to provide: an inner run is what actually launches containers, so
# its Docker address pool must be wide enough for the concurrency the inner
# environment uses. The pre-flight below runs the environment's
# configure-docker-pool.sh when it has one; where that needs privileges the job lacks,
# widen the pool on the nodes beforehand and restrict jobs to them.
#
# No --time: nothing bounds an inner run's wall clock — the agent decides when it is
# done.
#
# ONE inner evolve run, in a fully isolated run directory.
#
# This launches the inner environment exactly as it would be launched from the
# source repo — the only difference is where the run is saved. It adds nothing
# afterwards: the run's own artifacts are the data point.
#
#   sbatch inner_run.sbatch <skill_file> <inner_env> <artifacts_dir>
#
#     <skill_file>  the SKILL.md under evaluation
#     <inner_env>   inner environment name, e.g. dummy or tb2_1
#     <artifacts_dir>  where the run tree and its measurement are written
#
# Requires FREEEVOLVE_ROOT in the environment (the submitter exports it).

set -euo pipefail

SKILL="${1:?usage: inner_run.sbatch <skill_file> <inner_env> <artifacts_dir>}"
INNER_ENV="${2:?inner_env required}"
ARTIFACTS="${3:?artifacts_dir required}"

# Bedrock routing: set explicitly rather than relying on env inheritance, which does
# not survive sbatch. Set CLAUDE_CODE_USE_BEDROCK=0 to leave claude to its own
# configuration instead; the inner model pinned below then has to be a model id that
# configuration accepts.
export CLAUDE_CODE_USE_BEDROCK="${CLAUDE_CODE_USE_BEDROCK:-1}"
export AWS_REGION="${AWS_REGION:-us-west-2}"
export PATH="$HOME/.local/bin:$PATH"   # uv and claude live here

# The model the INNER evolver runs on. PINNED HERE, deliberately independent of
# whatever the outer evolver runs on: the meta metric compares SKILL.md against a
# constant inner model, so a change in outer model can never be mistaken for a
# change in skill quality. Change the inner model by editing this line.
#
# This is a Claude Code model alias (the `[1m]` suffix is valid there), not a
# Bedrock InvokeModel id — the agent under evolution has its own model, set by
# the inner environment.
export EVOLVER_MODEL="global.anthropic.claude-opus-4-8[1m]"

# Passed through to the inner environment's setup.sh. tau3 needs both: its
# adapter lives in a harbor checkout, and regenerating its dataset takes many
# minutes, so a prebuilt one is reused when available.
export TAU3_DATASET_SRC="${TAU3_DATASET_SRC:-}"
# An existing harbor checkout, when the submitter has one. Unset by default: the
# inner environments that need one clone it themselves and cache it.
if [ -n "${HARBOR_ROOT:-}" ]; then export HARBOR_ROOT; else unset HARBOR_ROOT || true; fi
# sbatch inherits the submitting environment, and the outer evolver's process has
# ANTHROPIC_MODEL set. Drop it, so the inner run's own pinned settings decide.
unset ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL

# SKILL_ROOT is passed in by the submitting run.sh, which points it at that run
# directory's OWN copy of the repo — so the job uses the same freeevolve tree the
# meta run was set up with. It cannot be derived from $0: Slurm copies this script
# into its spool directory before running it, so $0 is /var/spool/slurmd/jobNNN/...
SKILL_ROOT="${FREEEVOLVE_ROOT:?FREEEVOLVE_ROOT must be exported by the submitter}"
[ -x "$SKILL_ROOT/evolve.sh" ] || {
    echo "no evolve.sh under FREEEVOLVE_ROOT=$SKILL_ROOT" >&2
    exit 1
}
INNER_DIR="$SKILL_ROOT/envs/$INNER_ENV"

mkdir -p "$ARTIFACTS"
# evolve.sh installs the environment here and creates INNER/workspace/ for the
# agent. Nested one level down so this job's bookkeeping (run.log, measure/)
# stays outside the inner run directory.
INNER="$ARTIFACTS/run"

echo "=================================================================="
echo "job id     : ${SLURM_JOB_ID:-<none>}"
echo "node       : $(hostname)"
echo "skill      : ${SKILL}"
echo "inner env  : ${INNER_ENV}"
echo "inner model: ${EVOLVER_MODEL}"
echo "run        : ${INNER}"
echo "started    : $(date -Is)"
echo "=================================================================="

# --- Pre-flight: can this node reach Bedrock? --------------------------------
if ! timeout 180 claude -p 'reply with OK' >/dev/null 2>&1; then
    echo "[preflight] FAILED — claude/Bedrock not working on $(hostname). Aborting." >&2
    exit 1
fi
echo "[preflight] claude -> Bedrock OK"

# --- Pre-flight: Docker pool (only matters for container-based inner envs) ----
POOL_SCRIPT="$INNER_DIR/configure-docker-pool.sh"
if [ -f "$POOL_SCRIPT" ]; then
    bash "$POOL_SCRIPT" || echo "[preflight] WARNING: pool configuration failed or was skipped."
fi

# --- Run the inner environment -----------------------------------------------
# The run directory is standalone once set up, so many jobs can share this
# filesystem without interfering. Whatever the inner evolver leaves is the
# result; nothing is installed or re-measured on top of it.
bash "$SKILL_ROOT/evolve.sh" "$INNER_ENV" "$INNER" "$SKILL" \
    > "$ARTIFACTS/run.log" 2>&1 || true

echo "=================================================================="
echo "finished   : $(date -Is)"
echo "run dir    : ${INNER}"
echo "=================================================================="
