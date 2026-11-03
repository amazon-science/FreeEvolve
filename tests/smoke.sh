#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ] &&
   [ -n "${MOCK_CLAUDE_PROVIDER:-}" ]; then
    printf '{"loggedIn":true,"apiProvider":"%s"}\n' "$MOCK_CLAUDE_PROVIDER"
fi
exit 0
EOF
chmod +x "$TMP/bin/claude"

for command_name in sbatch squeue; do
    cat > "$TMP/bin/$command_name" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$TMP/bin/$command_name"
done
cat > "$TMP/bin/sinfo" <<'EOF'
#!/usr/bin/env bash
printf 'test-partition*\n'
EOF
chmod +x "$TMP/bin/sinfo"
cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
# Model a scheduler login node with the Docker CLI present but no local daemon.
exit 1
EOF
chmod +x "$TMP/bin/docker"

export PATH="$TMP/bin:$PATH"

BEDROCK_MODEL="$(
    env -u EVOLVER_MODEL -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
        -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CODE_USE_BEDROCK \
        bash "$ROOT/skills/launch/scripts/resolve-model.sh" \
            --provider bedrock |
        awk -F= '$1 == "evolver_model" {print $2}'
)"
test "$BEDROCK_MODEL" = "global.anthropic.claude-opus-4-8[1m]"

ANTHROPIC_MODEL="$(
    env -u EVOLVER_MODEL \
        bash "$ROOT/skills/launch/scripts/resolve-model.sh" \
            --provider anthropic |
        awk -F= '$1 == "evolver_model" {print $2}'
)"
test "$ANTHROPIC_MODEL" = "claude-opus-4-8"

AUTO_PROVIDER="$(
    MOCK_CLAUDE_PROVIDER=anthropic \
        env -u EVOLVER_MODEL -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
            -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CODE_USE_BEDROCK \
            bash "$ROOT/skills/launch/scripts/resolve-model.sh" \
                --provider auto |
        awk -F= '$1 == "provider" {print $2}'
)"
test "$AUTO_PROVIDER" = "anthropic"

bash "$ROOT/skills/launch/scripts/list-environments.sh" --names |
    grep -qx "dummy"

EXECUTION_INSPECTION="$(
    bash "$ROOT/skills/launch/scripts/inspect-execution.sh" dummy
)"
printf '%s\n' "$EXECUTION_INSPECTION" | grep '^local_status=ready$' >/dev/null
printf '%s\n' "$EXECUTION_INSPECTION" | grep '^slurm_status=available$' >/dev/null
printf '%s\n' "$EXECUTION_INSPECTION" |
    grep '^slurm_default_partition=test-partition$' >/dev/null

TAU3_EXECUTION_INSPECTION="$(
    bash "$ROOT/skills/launch/scripts/inspect-execution.sh" tau3
)"
printf '%s\n' "$TAU3_EXECUTION_INSPECTION" |
    grep '^local_detail=docker-daemon$' >/dev/null
printf '%s\n' "$TAU3_EXECUTION_INSPECTION" |
    grep '^recommended_backend=slurm$' >/dev/null

bash "$ROOT/skills/launch/scripts/list-skills.sh" |
    grep '^strong' >/dev/null
test "$(bash "$ROOT/skills/launch/scripts/resolve-skill.sh" seed)" = \
    "$ROOT/freeevolve/SKILL.md"
test "$(bash "$ROOT/skills/launch/scripts/resolve-skill.sh" strong)" = \
    "$ROOT/artifacts/evolution-skills/strong/SKILL.md"

bash "$ROOT/skills/launch/scripts/doctor.sh" dummy
bash -n "$ROOT/skills/launch/scripts/slurm-preflight.sbatch"

bash "$ROOT/skills/launch/scripts/validate-environment.sh" \
    "$ROOT/freeevolve/envs/dummy"

bash "$ROOT/skills/launch/scripts/validate-environment.sh" \
    "$ROOT/freeevolve/envs/dummy" "$TMP/validated-run"

FREEEVOLVE_MODEL_PROVIDER=bedrock \
    bash "$ROOT/freeevolve/evolve.sh" dummy "$TMP/evolve-run"

for required in ENVIRONMENT.md run.sh .target .skill.md agent_trace.jsonl \
                .freeevolve-model.env .claude/settings.json; do
    test -e "$TMP/evolve-run/$required"
done
test -d "$TMP/evolve-run/target"
test -d "$TMP/evolve-run/workspace-dummy"
test "$(tr -d '[:space:]' < "$TMP/evolve-run/.target")" = "target"
grep -q '^FREEEVOLVE_MODEL_PROVIDER=bedrock$' \
    "$TMP/evolve-run/.freeevolve-model.env"
grep -q '"CLAUDE_CODE_USE_BEDROCK": "1"' \
    "$TMP/evolve-run/.claude/settings.json"

FREEEVOLVE_MODEL_PROVIDER=anthropic EVOLVER_MODEL=claude-opus-4-8 \
    bash "$ROOT/freeevolve/evolve.sh" dummy "$TMP/evolve-run-anthropic"
grep -q '^FREEEVOLVE_MODEL_PROVIDER=anthropic$' \
    "$TMP/evolve-run-anthropic/.freeevolve-model.env"
if grep -q 'CLAUDE_CODE_USE_BEDROCK\\|AWS_REGION' \
    "$TMP/evolve-run-anthropic/.claude/settings.json"; then
    echo "direct Anthropic settings unexpectedly contain Bedrock routing" >&2
    exit 1
fi

# The Slurm implementation is canonical. The local environment must delegate to
# its installer and differ only in the installed dispatch backend.
META_INNER_ENVS=dummy \
    bash "$ROOT/freeevolve/envs/meta_chain/setup.sh" "$TMP/meta-slurm"
META_INNER_ENVS=dummy \
    bash "$ROOT/freeevolve/envs/meta_chain_local/setup.sh" "$TMP/meta-local"

test -f "$TMP/meta-slurm/eval/inner_run.sbatch"
test -f "$TMP/meta-local/eval/inner_run.sbatch"
test -x "$TMP/meta-slurm/run.sh"
test -x "$TMP/meta-local/run.sh"
grep -q '^# Environment: meta_chain$' "$TMP/meta-slurm/ENVIRONMENT.md"
grep -q '^# Environment: meta_chain_local$' "$TMP/meta-local/ENVIRONMENT.md"
if grep -R -q '@@' "$TMP/meta-slurm/ENVIRONMENT.md" "$TMP/meta-local/ENVIRONMENT.md"; then
    echo "meta-chain environment placeholder was not resolved" >&2
    exit 1
fi
test "$(cat "$TMP/meta-slurm/.meta_chain_backend")" = "slurm"
test "$(cat "$TMP/meta-local/.meta_chain_backend")" = "local"
cmp "$TMP/meta-slurm/run.sh" "$TMP/meta-local/run.sh"
cmp "$TMP/meta-slurm/eval/inner_run.sbatch" \
    "$TMP/meta-local/eval/inner_run.sbatch"

# Provider selection must survive the outer-to-inner meta-evolution boundary.
FREEEVOLVE_MODEL_PROVIDER=anthropic EVOLVER_MODEL=claude-opus-4-8 \
    bash "$TMP/meta-local/run.sh" \
        --artifacts "$TMP/meta-local/workspace-meta_chain_local/provider-check" \
        --inner-env dummy
grep -q '^FREEEVOLVE_MODEL_PROVIDER=anthropic$' \
    "$TMP/meta-local/workspace-meta_chain_local/provider-check/run/.freeevolve-model.env"
if grep -q 'CLAUDE_CODE_USE_BEDROCK\\|AWS_REGION' \
    "$TMP/meta-local/workspace-meta_chain_local/provider-check/run/.claude/settings.json"; then
    echo "direct Anthropic meta run unexpectedly contains Bedrock routing" >&2
    exit 1
fi

echo "FreeEvolve smoke test passed"
