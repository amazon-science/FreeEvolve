#!/bin/bash
#SBATCH --job-name=eval_only
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --exclusive
# No --partition, --nodelist or --time: see the note at the top of
# submit_evolve.sbatch. Choose the partition when submitting, and give the job a node
# whose Docker address pool is wide enough for the concurrency you ask for.
#
# ONE evaluation on a dedicated node. NO evolver, no agent, no claude — this installs
# an environment into a run directory and calls its run.sh once. Use it to measure a
# fixed agent at a fixed n: a baseline, a confirmation at higher attempts, a candidate
# on a task set it was not built against.
#
#   sbatch submit_eval.sbatch <env> <run_dir> [run.sh args...]
#
#     <env>         environment name under envs/, e.g. arc_agi_2
#     <run_dir>     where the run lives. Created if absent.
#     run.sh args   passed through verbatim, e.g. --attempts 2 --concurrency 40
#
# Everything the environment's setup.sh reads is passed through the submitting
# environment — sbatch exports it by default, so no code here needs to name it:
# ARC_AGENT_SRC, ARC_TASK_COUNT, ARC_SPLIT, TAU3_DATASET_SRC, TB2_AGENT_SRC,
# FRONTIER_AGENT_SRC, FRONTIER_PROBLEMS_SRC, HARBOR_ROOT, ... See the env's
# setup.sh for what it honours.
#
# SKILL_ROOT is baked in by the submitting shell, because Slurm copies this script
# into its spool directory before running it — $0 points at that copy, not the repo.

set -euo pipefail

ENV_NAME="${1:?usage: sbatch submit_eval.sbatch <env> <run_dir> [run.sh args...]}"
RUN_DIR="${2:?run_dir required}"
shift 2
RUN_ARGS=("$@")

SKILL_ROOT="${FREEEVOLVE_ROOT:-}"
if [ -z "$SKILL_ROOT" ]; then
    _here="$(cd "$(dirname "$0")" && pwd)"
    [ -d "$_here/envs" ] && SKILL_ROOT="$_here"
fi
[ -n "$SKILL_ROOT" ] || {
    echo "submit with: FREEEVOLVE_ROOT=/path/to/freeevolve sbatch $(basename "$0") ..." >&2
    exit 1
}
ENV_SRC="$SKILL_ROOT/envs/$ENV_NAME"
[ -f "$ENV_SRC/setup.sh" ] || { echo "no setup.sh in $ENV_SRC" >&2; exit 1; }

export AWS_REGION="${AWS_REGION:-us-west-2}"
export AWS_DEFAULT_REGION="$AWS_REGION"
export PATH="$HOME/.local/bin:$PATH"     # uv lives here
# Only when the submitter has a checkout; otherwise the environment clones one.
if [ -n "${HARBOR_ROOT:-}" ]; then export HARBOR_ROOT; else unset HARBOR_ROOT || true; fi
# No evolver runs here, but the environment's run.sh unsets these anyway so the
# agent under evaluation cannot pick up the submitting shell's model.
unset ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL || true

mkdir -p "$RUN_DIR"
RUN_DIR="$(cd "$RUN_DIR" && pwd)"

echo "=================================================================="
echo "job id     : ${SLURM_JOB_ID:-<none>}"
echo "node       : $(hostname) ($(nproc) cpus)"
echo "env        : ${ENV_NAME}"
echo "run dir    : ${RUN_DIR}"
echo "run.sh args: ${RUN_ARGS[*]:-<none>}"
echo "started    : $(date -Iseconds)"
echo "=================================================================="

# Some environments widen the node's Docker address pool themselves; run it if present.
if [ -x "$ENV_SRC/configure-docker-pool.sh" ]; then
    bash "$ENV_SRC/configure-docker-pool.sh" || echo "[eval] docker pool config failed, continuing"
fi

bash "$ENV_SRC/setup.sh" "$RUN_DIR" 2>&1 | tee "$RUN_DIR/setup.log"

for required in ENVIRONMENT.md run.sh .target; do
    [ -e "$RUN_DIR/$required" ] || { echo "setup.sh did not create $required" >&2; exit 1; }
done

ARTIFACTS="$RUN_DIR/artifacts"
cd "$RUN_DIR"
RC=0
./run.sh --artifacts "$ARTIFACTS" "${RUN_ARGS[@]}" || RC=$?

echo "=================================================================="
echo "run.sh exited rc=$RC"
echo "finished   : $(date -Iseconds)"
echo "results    : $ARTIFACTS/job/result.json"
echo "=================================================================="
exit 0
