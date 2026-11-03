#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

printf '%-12s %-18s %s\n' "NAME" "TYPE" "DESCRIPTION"
printf '%-12s %-18s %s\n' "seed" "minimal" \
    "The deliberately minimal starting skill used to study meta-evolution."
printf '%-12s %-18s %s\n' "strong" "meta-evolved" \
    "The strongest bundled general evolution skill."
printf '%-12s %-18s %s\n' "arc-agi-3" "evolved artifact" \
    "An ARC-AGI-3 evolution artifact retained for research comparison."

for path in \
    "$ROOT/freeevolve/SKILL.md" \
    "$ROOT/artifacts/evolution-skills/strong/SKILL.md" \
    "$ROOT/artifacts/evolution-skills/arc-agi-3/SKILL.md"; do
    [ -f "$path" ] || {
        echo "missing bundled skill: $path" >&2
        exit 1
    }
done
