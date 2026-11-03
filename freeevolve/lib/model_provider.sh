#!/usr/bin/env bash
# Shared Claude Code provider/model resolution.
#
# Public inputs:
#   FREEEVOLVE_MODEL_PROVIDER  auto (default), bedrock, or anthropic
#   CLAUDE_CODE_USE_BEDROCK    backward-compatible provider hint
#   EVOLVER_MODEL              explicit Claude Code model id or alias
#   AWS_REGION                 Bedrock region
#
# After freeevolve_resolve_model:
#   FREEEVOLVE_MODEL_PROVIDER is bedrock or anthropic
#   EVOLVER_MODEL is always set
#   CLAUDE_CODE_USE_BEDROCK is 1 for Bedrock and unset for direct Anthropic

freeevolve_detect_claude_provider() {
    command -v claude >/dev/null 2>&1 || return 0
    command -v python3 >/dev/null 2>&1 || return 0

    local status provider
    status="$(claude auth status --json 2>/dev/null || true)"
    [ -n "$status" ] || return 0
    provider="$(
        printf '%s' "$status" |
            python3 -c 'import json, sys
try:
    value = str(json.load(sys.stdin).get("apiProvider", "")).lower()
except Exception:
    value = ""
print(value)'
    )"
    case "$provider" in
        bedrock)
            printf 'bedrock\n'
            ;;
        anthropic|first_party|first-party)
            printf 'anthropic\n'
            ;;
    esac
}

freeevolve_resolve_model() {
    local requested="${FREEEVOLVE_MODEL_PROVIDER:-auto}"
    requested="$(printf '%s' "$requested" | tr '[:upper:]' '[:lower:]')"

    if [ "$requested" = "auto" ]; then
        case "$(printf '%s' "${CLAUDE_CODE_USE_BEDROCK:-}" | tr '[:upper:]' '[:lower:]')" in
            1|true|yes)
                requested="bedrock"
                ;;
            0|false|no)
                requested="anthropic"
                ;;
            "")
                if [ -n "${ANTHROPIC_API_KEY:-}" ] ||
                   [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] ||
                   [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
                    requested="anthropic"
                else
                    requested="$(freeevolve_detect_claude_provider)"
                    if [ -z "$requested" ]; then
                        # Bedrock is the historical and reproducibility default
                        # for the published FreeEvolve configurations.
                        requested="bedrock"
                    fi
                fi
                ;;
            *)
                echo "invalid CLAUDE_CODE_USE_BEDROCK=${CLAUDE_CODE_USE_BEDROCK}" >&2
                return 2
                ;;
        esac
    fi

    case "$requested" in
        bedrock)
            export FREEEVOLVE_MODEL_PROVIDER="bedrock"
            export CLAUDE_CODE_USE_BEDROCK=1
            export AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-west-2}}"
            export EVOLVER_MODEL="${EVOLVER_MODEL:-global.anthropic.claude-opus-4-8[1m]}"
            ;;
        anthropic|direct)
            export FREEEVOLVE_MODEL_PROVIDER="anthropic"
            unset CLAUDE_CODE_USE_BEDROCK || true
            export EVOLVER_MODEL="${EVOLVER_MODEL:-claude-opus-4-8}"
            ;;
        *)
            echo "FREEEVOLVE_MODEL_PROVIDER must be auto, bedrock, or anthropic" >&2
            return 2
            ;;
    esac
}
