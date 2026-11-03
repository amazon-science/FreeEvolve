#!/usr/bin/env bash
# Install the meta_local environment into a run directory.
#
#   setup.sh <run_dir>
#
# Creates, inside the run directory:
#   ENVIRONMENT.md   the goal and how to evaluate
#   run.sh           the evaluation — runs inner evolve loops
#   eval/freeevolve/  a full copy of the evolver repo, which is what the
#                      evaluation actually runs (evolve.sh + the inner envs)
#   target/SKILL.md  the evolver's instructions (the edit surface)
#   .target          declares that edit surface: `target/SKILL.md`
#
# The run directory is standalone afterwards: nothing in it refers back to this
# directory, so inner runs launched from here use its own copy and a concurrent
# edit to the source repo cannot change a running evaluation.
#
# Idempotent, and never clobbers an existing target.
set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_SRC="$(cd "$ENV_DIR/../.." && pwd)"   # the freeevolve repo
WS="${1:?usage: setup.sh <run_dir>}"
mkdir -p "$WS"
WS="$(cd "$WS" && pwd)"
EVAL="$WS/eval"

[ -f "$SKILL_SRC/SKILL.md" ] || { echo "no SKILL.md at $SKILL_SRC" >&2; exit 1; }

# --- The evaluation ----------------------------------------------------------
# The meta evaluation IS the evolver, so the whole repo is this environment's
# eval asset. Copied rather than referenced, so inner runs stay inside this run
# directory.
mkdir -p "$EVAL"
# SKILL.md and README.md are excluded for the same reason, and it is a sharper one.
# The repo's SKILL.md is whatever version is currently promoted — frequently a much
# evolved one — while the edit surface installed below may be an early seed. Copying
# it in puts a finished answer inside the run: improving the skill would collapse to
# copying a file. README.md is worse: it is the experiment's own design document, and
# it names the specific things the seed deliberately omits "that we hope the agent
# discovers". Neither file is read by anything here — inner runs are always given
# their skill explicitly — so the copy loses nothing by dropping them. skills/ is
# excluded on the same grounds, in case a tree has one: a kept skill version inside the
# run is a candidate answer the run did not have to find.
# past_sks.md and any generations/ archive are OPERATOR bookkeeping: they record
# which skill versions preceded this one, and their names carry the run directories
# that produced them. A run that reads them can find its predecessor's results and
# borrow numbers measured under a different experiment's conditions — which is not
# this run's evidence, since the promoted skill also changes how the OUTER agent
# structures the experiment. Kept out of the copy so a run measures what it runs.
rsync -a --delete \
    --exclude='.git/' \
    --exclude='__pycache__/' \
    --exclude='*.pyc' \
    --exclude='past_sks.md' \
    --exclude='generations/' \
    --exclude='SKILL.md' \
    --exclude='README.md' \
    --exclude='skills/' \
    "$SKILL_SRC/" "$EVAL/freeevolve/"

# The meta environments are not themselves candidates: an inner run against one
# would be a second level of recursion nobody asked for. Matched by pattern rather
# than named one by one, so a meta environment added later is covered too — naming
# them was how meta_chain and meta_chain_local came to be left in this copy.
# rm -rf, not a loop with a test: an unmatched glob would be passed through as a
# literal path, which rm ignores and a test would fail on — killing setup under set -e.
rm -rf "$EVAL/freeevolve/envs"/meta "$EVAL/freeevolve/envs"/meta_*

# Which inner environments this run may evolve against; empty means all of them.
META_INNER_ENVS="${META_INNER_ENVS:-}"
if [ -n "$META_INNER_ENVS" ]; then
    keep=" $(echo "$META_INNER_ENVS" | tr ',' ' ') "
    for d in "$EVAL/freeevolve/envs"/*/; do
        name="$(basename "$d")"
        case "$keep" in
            *" $name "*) ;;
            *) rm -rf "$d" ;;
        esac
    done
    echo "[setup] inner environments available:$(cd "$EVAL/freeevolve/envs" && echo " "$(echo */ | tr -d '/'))"
fi

# ENVIRONMENT.md states the machine every inner run shares. Read off this machine at
# install time rather than hard-coded, so the text is true wherever this runs.
CPUS="$(nproc 2>/dev/null || echo '?')"
MEMGB="$(awk '/MemTotal/ {printf "%.0f", $2/1048576}' /proc/meminfo 2>/dev/null || echo '?')"
sed -e "s/@@CPUS@@/$CPUS/g" -e "s/@@MEMGB@@/$MEMGB/g" \
    "$ENV_DIR/ENVIRONMENT.md" > "$WS/ENVIRONMENT.md"
if grep -q '@@' "$WS/ENVIRONMENT.md"; then
    echo "[setup] unsubstituted placeholder left in ENVIRONMENT.md:" >&2
    grep -n '@@' "$WS/ENVIRONMENT.md" >&2
    exit 1
fi
echo "[setup] machine stated to the agent: $CPUS cores, ${MEMGB} GB"
cp "$ENV_DIR/run.sh" "$WS/run.sh"
chmod +x "$WS/run.sh"

# Where the edit surface lives, relative to the run directory. Here it is a single
# FILE, not a directory — the declaration accommodates either.
echo "target/SKILL.md" > "$WS/.target"

# --- The edit surface --------------------------------------------------------
# The skill under evaluation and the skill the outer agent RUNS are the same kind of
# file. They default TOGETHER, to the skill driving this run; META_TARGET_SKILL
# overrides the edit surface alone. Defaulting to the repo's SKILL.md — as this did —
# meant a launch that named a skill set only the driver, and the edit surface
# silently became whatever version was promoted in the repo.
TARGET_SKILL_SRC="${META_TARGET_SKILL:-${EVOLVE_SKILL_FILE:-$SKILL_SRC/SKILL.md}}"
[ -f "$TARGET_SKILL_SRC" ] || { echo "[setup] no skill file at $TARGET_SKILL_SRC" >&2; exit 1; }
_fp() { printf '%s  %s lines' "$(md5sum "$1" | cut -c1-8)" "$(wc -l < "$1")"; }
DRIVER_SKILL="${EVOLVE_SKILL_FILE:-$SKILL_SRC/SKILL.md}"
echo "[setup] driving skill: $(_fp "$DRIVER_SKILL")  $DRIVER_SKILL"
echo "[setup] edit surface : $(_fp "$TARGET_SKILL_SRC")  $TARGET_SKILL_SRC"
cmp -s "$DRIVER_SKILL" "$TARGET_SKILL_SRC" || \
    echo "[setup] NOTE: DIFFERENT files — this run improves one skill while driven by another."
if [ -d "$WS/target" ]; then
    echo "[setup] $WS/target already exists — leaving it alone"
else
    mkdir -p "$WS/target"
    cp "$TARGET_SKILL_SRC" "$WS/target/SKILL.md"
    echo "[setup] pristine target at $WS/target/SKILL.md (from $TARGET_SKILL_SRC)"
fi

rm -rf "$WS/.target_pristine"
mkdir -p "$WS/.target_pristine"
cp "$TARGET_SKILL_SRC" "$WS/.target_pristine/SKILL.md"

echo "[setup] meta_local environment installed in $WS"
