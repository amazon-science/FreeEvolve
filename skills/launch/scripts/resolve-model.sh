#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PROVIDER="${FREEEVOLVE_MODEL_PROVIDER:-auto}"
MODEL="${EVOLVER_MODEL:-}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-west-2}}"

usage() {
    cat <<'EOF'
usage: resolve-model.sh [--provider auto|bedrock|anthropic] [--model ID] [--region REGION]

Resolves the Claude Code provider and evolver model without printing secrets.
The output is suitable for displaying to a user before a FreeEvolve launch.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --provider)
            PROVIDER="${2:?--provider requires a value}"
            shift 2
            ;;
        --model)
            MODEL="${2:?--model requires a value}"
            shift 2
            ;;
        --region)
            REGION="${2:?--region requires a value}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

export FREEEVOLVE_MODEL_PROVIDER="$PROVIDER"
export AWS_REGION="$REGION"
if [ -n "$MODEL" ]; then
    export EVOLVER_MODEL="$MODEL"
else
    unset EVOLVER_MODEL || true
fi

# shellcheck source=../../../freeevolve/lib/model_provider.sh
source "$ROOT/freeevolve/lib/model_provider.sh"
freeevolve_resolve_model

printf 'provider=%s\n' "$FREEEVOLVE_MODEL_PROVIDER"
printf 'evolver_model=%s\n' "$EVOLVER_MODEL"
if [ "$FREEEVOLVE_MODEL_PROVIDER" = "bedrock" ]; then
    printf 'aws_region=%s\n' "$AWS_REGION"
    printf 'authentication=AWS credential chain\n'
else
    printf 'authentication=Claude Code login or ANTHROPIC_API_KEY\n'
fi
