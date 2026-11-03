#!/usr/bin/env bash
# Report which execution backends can plausibly run one FreeEvolve environment.
# This script does not submit work. A selected Slurm partition must still pass
# slurm-preflight.sbatch before a paid campaign is launched.
set -uo pipefail

ENV_ARG="${1:-}"
[ -n "$ENV_ARG" ] || {
    echo "usage: inspect-execution.sh <environment-name-or-path>" >&2
    exit 2
}

needs_containers=yes
needs_uv=yes
case "$(basename "$ENV_ARG")" in
    dummy)
        needs_containers=no
        needs_uv=no
        ;;
    arc_agi_3)
        needs_containers=no
        ;;
esac

local_missing=()
for command_name in bash python3 claude git rsync curl; do
    command -v "$command_name" >/dev/null 2>&1 ||
        local_missing+=("$command_name")
done

if [ "$needs_uv" = "yes" ] && ! command -v uv >/dev/null 2>&1; then
    local_missing+=("uv")
fi

if [ "$needs_containers" = "yes" ]; then
    if ! command -v docker >/dev/null 2>&1; then
        local_missing+=("docker")
    elif ! docker info >/dev/null 2>&1; then
        local_missing+=("docker-daemon")
    fi
fi

if [ "${#local_missing[@]}" -eq 0 ]; then
    local_status="ready"
    local_detail="all required local commands and services are reachable"
else
    local_status="blocked"
    local_detail="$(IFS=,; echo "${local_missing[*]}")"
fi

slurm_missing=()
for command_name in sbatch squeue sinfo; do
    command -v "$command_name" >/dev/null 2>&1 ||
        slurm_missing+=("$command_name")
done

slurm_partitions=""
slurm_default=""
if [ "${#slurm_missing[@]}" -eq 0 ]; then
    slurm_partitions="$(
        sinfo -h -o '%P' 2>/dev/null |
            sed 's/\*$//' |
            awk 'NF && !seen[$0]++' |
            paste -sd, -
    )"
    slurm_default="$(
        sinfo -h -o '%P' 2>/dev/null |
            awk '/\*$/ {sub(/\*$/, ""); print; exit}'
    )"
    if [ -n "$slurm_partitions" ]; then
        slurm_status="available"
        slurm_detail="scheduler commands are available; compute-node preflight required"
    else
        slurm_status="blocked"
        slurm_detail="sinfo returned no partitions"
    fi
else
    slurm_status="unavailable"
    slurm_detail="$(IFS=,; echo "${slurm_missing[*]}")"
fi

if [ "$local_status" = "ready" ] && [ "$slurm_status" = "available" ]; then
    recommendation="choose"
elif [ "$local_status" = "ready" ]; then
    recommendation="local"
elif [ "$slurm_status" = "available" ]; then
    recommendation="slurm"
else
    recommendation="none"
fi

printf 'environment=%s\n' "$ENV_ARG"
printf 'local_status=%s\n' "$local_status"
printf 'local_detail=%s\n' "$local_detail"
printf 'slurm_status=%s\n' "$slurm_status"
printf 'slurm_detail=%s\n' "$slurm_detail"
printf 'slurm_default_partition=%s\n' "$slurm_default"
printf 'slurm_partitions=%s\n' "$slurm_partitions"
printf 'recommended_backend=%s\n' "$recommendation"
