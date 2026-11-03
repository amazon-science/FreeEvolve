#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ENV_NAME="${1:-}"
MODEL_PROVIDER="${2:-${FREEEVOLVE_MODEL_PROVIDER:-auto}}"
EXECUTION_BACKEND="${3:-local}"

case "$EXECUTION_BACKEND" in
    local|slurm) ;;
    *)
        echo "execution backend must be local or slurm" >&2
        exit 2
        ;;
esac

export FREEEVOLVE_MODEL_PROVIDER="$MODEL_PROVIDER"
# shellcheck source=../../../freeevolve/lib/model_provider.sh
source "$PLUGIN_ROOT/freeevolve/lib/model_provider.sh"
freeevolve_resolve_model

failures=0
warnings=0

pass() {
    printf 'PASS  %s\n' "$1"
}

warn() {
    printf 'WARN  %s\n' "$1"
    warnings=$((warnings + 1))
}

skip() {
    printf 'SKIP  %s\n' "$1"
}

fail() {
    printf 'MISS  %s\n' "$1"
    failures=$((failures + 1))
}

check_command() {
    local command_name="$1"
    local required="${2:-yes}"
    local explanation="${3:-required command}"
    if command -v "$command_name" >/dev/null 2>&1; then
        pass "$command_name: $(command -v "$command_name")"
    elif [ "$required" = "yes" ]; then
        fail "$command_name: $explanation"
    else
        skip "$command_name: $explanation"
    fi
}

needs_containers=yes
needs_uv=yes
needs_slurm=no
needs_hf=no

case "$ENV_NAME" in
    "")
        ;;
    dummy)
        needs_containers=no
        needs_uv=no
        ;;
    arc_agi_3)
        needs_containers=no
        ;;
    meta|meta_chain)
        needs_slurm=yes
        ;;
    hle|gaia2_cli)
        needs_hf=yes
        ;;
esac

printf 'FreeEvolve prerequisite check'
if [ -n "$ENV_NAME" ]; then
    printf ' for %s' "$ENV_NAME"
fi
printf '\nRepository: %s\n\n' "$PLUGIN_ROOT"
printf 'Evolver provider: %s\n' "$FREEEVOLVE_MODEL_PROVIDER"
printf 'Evolver model:    %s\n' "$EVOLVER_MODEL"
printf 'Execution backend: %s\n\n' "$EXECUTION_BACKEND"

if [ "$EXECUTION_BACKEND" = "slurm" ]; then
    pass "submission host: $(hostname)"
    check_command sbatch yes "required to submit the evolution campaign"
    check_command squeue yes "required to monitor the evolution campaign"
    check_command sinfo yes "required to inspect available partitions"
    skip "compute-node commands and services: checked by slurm-preflight.sbatch"
    skip "model access: checked from the selected compute partition"
    printf '\nSummary: %d missing, %d warnings\n' "$failures" "$warnings"
    exit "$failures"
fi

case "$(uname -s)" in
    Linux)
        pass "operating system: Linux"
        ;;
    Darwin)
        if [ "$needs_containers" = "yes" ]; then
            warn "operating system: macOS; benchmark environments target Linux containers"
        else
            pass "operating system: macOS (sufficient for the dummy smoke path)"
        fi
        ;;
    *)
        warn "operating system: $(uname -s); the published environments target Linux"
        ;;
esac

check_command bash yes "required to run FreeEvolve"
check_command python3 yes "required by environment setup and evaluation"
check_command claude yes "Claude Code is the evolver runtime"
check_command git yes "required to resolve benchmark checkouts"
check_command rsync yes "required by environment installers"
check_command curl yes "required by environment installers"

if [ "$needs_uv" = "yes" ]; then
    check_command uv yes "required to build isolated Python environments"
else
    check_command uv no "not needed by the dummy environment"
fi

if [ "$needs_containers" = "yes" ]; then
    if command -v docker >/dev/null 2>&1; then
        pass "docker: $(command -v docker)"
        if docker info >/dev/null 2>&1; then
            pass "Docker daemon is reachable"
        else
            fail "Docker daemon is not reachable by this user"
        fi
        if docker compose version >/dev/null 2>&1; then
            pass "docker compose v2 is available"
        else
            warn "docker compose v2 is unavailable; some setups install its user plugin"
        fi
    else
        fail "docker: required by this benchmark environment"
    fi
else
    check_command docker no "not needed by the dummy environment"
fi

if [ "$needs_slurm" = "yes" ]; then
    check_command sbatch yes "required by the cluster meta-environment"
else
    skip "sbatch: needed only by meta_chain"
fi

if [ "$needs_hf" = "yes" ]; then
    if [ -n "${HF_TOKEN:-}" ] || [ -f "${HF_TOKEN_FILE:-$HOME/.hf_token}" ]; then
        pass "Hugging Face credentials are present"
    else
        warn "Hugging Face credentials are not visible; gated data may require them"
    fi
fi

if [ "$FREEEVOLVE_MODEL_PROVIDER" = "bedrock" ]; then
    if [ "$(freeevolve_detect_claude_provider)" = "bedrock" ]; then
        pass "Claude Code is configured for Bedrock"
    elif [ -n "${AWS_ACCESS_KEY_ID:-}" ] ||
       [ -n "${AWS_PROFILE:-}" ] ||
       [ -n "${AWS_WEB_IDENTITY_TOKEN_FILE:-}" ] ||
       [ -n "${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI:-}" ] ||
       command -v aws >/dev/null 2>&1; then
        pass "an AWS credential route is available for Bedrock"
    else
        warn "AWS credentials were not detected; an instance or container role may still work"
    fi
else
    if [ "$(freeevolve_detect_claude_provider)" = "anthropic" ]; then
        pass "Claude Code is logged in to Anthropic"
    elif [ -n "${ANTHROPIC_API_KEY:-}" ] ||
       [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] ||
       [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        pass "direct Anthropic credentials are configured"
    else
        warn "no direct API token was detected; an existing Claude Code login may still work"
    fi
fi

printf '\nSummary: %d missing, %d warnings\n' "$failures" "$warnings"
exit "$failures"
