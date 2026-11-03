#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ENVS_DIR="$PLUGIN_ROOT/freeevolve/envs"

if [ "${1:-}" = "--names" ]; then
    find "$ENVS_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort
    exit 0
fi

printf '%-24s %-11s %s\n' "ENVIRONMENT" "TYPE" "PURPOSE / REQUIREMENTS"
printf '%-24s %-11s %s\n' "-----------" "----" "----------------------"

while IFS= read -r env_dir; do
    name="$(basename "$env_dir")"
    case "$name" in
        meta|meta_local)
            continue
            ;;
    esac
    type="evolution"
    description=""
    case "$name" in
        arc_agi_2)
            description="ARC-AGI-2 puzzle agent; Docker, uv, Bedrock/model access"
            ;;
        arc_agi_3)
            description="ARC-AGI-3 interactive-game agent; uv and Bedrock/model access"
            ;;
        dummy)
            description="cheap end-to-end smoke environment; Python and Claude Code"
            ;;
        frontier_cs)
            description="algorithmic terminal agent; Docker and a large benchmark checkout"
            ;;
        gaia2_cli)
            type="evaluation"
            description="GAIA2 evaluator only; no declared edit surface yet"
            ;;
        hle)
            description="Humanity's Last Exam agent; Docker and gated Hugging Face data"
            ;;
        meta_chain)
            type="meta"
            description="meta-evolution with inheritable inner agents; Slurm"
            ;;
        meta_chain_local)
            type="meta"
            description="meta_chain with inner runs on the local machine"
            ;;
        tau3)
            description="tau3-bench customer-service agent; Docker and Bedrock/model access"
            ;;
        tb2_1)
            description="Terminal-Bench 2.1 terminus agent; Docker and Bedrock/model access"
            ;;
        tb2_da)
            description="Terminal-Bench 2.1 deepagents harness; Docker and Bedrock/model access"
            ;;
        *)
            description="custom environment"
            ;;
    esac
    printf '%-24s %-11s %s\n' "$name" "$type" "$description"
done < <(find "$ENVS_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

printf '\nUse an environment name with freeevolve/evolve.sh. '
printf 'Entries marked evaluation need an edit surface before evolution.\n'
