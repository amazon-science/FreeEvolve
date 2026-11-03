#!/bin/bash
# One short compute-node validation for a selected Slurm partition.
#
# Submit with FREEEVOLVE_ROOT pointing at the repository's freeevolve/ directory:
#
#   FREEEVOLVE_ROOT=/shared/FreeEvolve/freeevolve \
#     sbatch --wait -p <partition> slurm-preflight.sbatch <env> <run-parent>
#SBATCH --job-name=freeevolve-check
#SBATCH --nodes=1
#SBATCH --ntasks=1

set -euo pipefail

ENV_ARG="${1:?environment name or path required}"
RUN_PARENT="${2:?shared run parent required}"
FREEEVOLVE_ROOT="${FREEEVOLVE_ROOT:?FREEEVOLVE_ROOT must name the shared freeevolve directory}"

export PATH="$HOME/.local/bin:$PATH"

if [ -d "$FREEEVOLVE_ROOT/envs/$ENV_ARG" ]; then
    ENV_SRC="$FREEEVOLVE_ROOT/envs/$ENV_ARG"
elif [ -d "$ENV_ARG" ]; then
    ENV_SRC="$(cd "$ENV_ARG" && pwd)"
else
    echo "environment is not visible on $(hostname): $ENV_ARG" >&2
    exit 1
fi

[ -x "$FREEEVOLVE_ROOT/evolve.sh" ] || {
    echo "FREEEVOLVE_ROOT is not visible on $(hostname): $FREEEVOLVE_ROOT" >&2
    exit 1
}
[ -f "$ENV_SRC/setup.sh" ] || {
    echo "environment has no setup.sh: $ENV_SRC" >&2
    exit 1
}

needs_containers=yes
needs_uv=yes
case "$(basename "$ENV_SRC")" in
    dummy)
        needs_containers=no
        needs_uv=no
        ;;
    arc_agi_3)
        needs_containers=no
        ;;
esac

for command_name in bash python3 claude git rsync curl timeout; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "missing on compute node: $command_name" >&2
        exit 1
    }
done

if [ "$needs_uv" = "yes" ]; then
    command -v uv >/dev/null 2>&1 || {
        echo "missing on compute node: uv" >&2
        exit 1
    }
fi

if [ "$needs_containers" = "yes" ]; then
    command -v docker >/dev/null 2>&1 || {
        echo "missing on compute node: docker" >&2
        exit 1
    }
    docker info >/dev/null 2>&1 || {
        echo "Docker daemon is not reachable on compute node $(hostname)" >&2
        exit 1
    }
    if ! docker compose version >/dev/null 2>&1; then
        echo "WARN: docker compose v2 is absent; environment setup may install its user plugin" >&2
    fi
fi

mkdir -p "$RUN_PARENT"
probe="$RUN_PARENT/.freeevolve-preflight-${SLURM_JOB_ID:-$$}"
printf '%s\n' "$(hostname)" > "$probe"
rm -f "$probe"

# Resolve exactly the provider and model that the campaign will use, then make
# one minimal request from the compute node. This catches missing instance-role
# access and model routing before the long job is submitted.
# shellcheck source=../../../freeevolve/lib/model_provider.sh
source "$FREEEVOLVE_ROOT/lib/model_provider.sh"
freeevolve_resolve_model

echo "node=$(hostname)"
echo "environment=$ENV_ARG"
echo "provider=$FREEEVOLVE_MODEL_PROVIDER"
echo "model=$EVOLVER_MODEL"
echo "run_parent=$RUN_PARENT"

if ! ANTHROPIC_MODEL="$EVOLVER_MODEL" timeout 300 \
    claude -p 'Reply with exactly OK.' >/dev/null 2>&1; then
    echo "Claude Code could not reach $FREEEVOLVE_MODEL_PROVIDER with $EVOLVER_MODEL" >&2
    exit 1
fi

echo "FreeEvolve Slurm preflight passed"
