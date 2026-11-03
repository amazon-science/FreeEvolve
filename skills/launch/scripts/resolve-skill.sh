#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
NAME="${1:-}"

case "$NAME" in
    seed)
        SKILL="$ROOT/freeevolve/SKILL.md"
        ;;
    strong|meta-evolved)
        SKILL="$ROOT/artifacts/evolution-skills/strong/SKILL.md"
        ;;
    arc-agi-3)
        SKILL="$ROOT/artifacts/evolution-skills/arc-agi-3/SKILL.md"
        ;;
    "")
        echo "usage: resolve-skill.sh <seed|strong|arc-agi-3|path>" >&2
        exit 2
        ;;
    *)
        [ -f "$NAME" ] || {
            echo "no skill named '$NAME' and no file at that path" >&2
            exit 2
        }
        SKILL="$(cd "$(dirname "$NAME")" && pwd)/$(basename "$NAME")"
        ;;
esac

[ -f "$SKILL" ] || {
    echo "skill file is missing: $SKILL" >&2
    exit 1
}
printf '%s\n' "$SKILL"
