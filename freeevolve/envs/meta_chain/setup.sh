#!/usr/bin/env bash
# Install the canonical meta_chain environment into a run directory.
#
# This Slurm implementation is the source of truth for meta-chain semantics.
# meta_chain_local calls this installer with META_CHAIN_BACKEND=local and supplies
# only its backend-facing ENVIRONMENT.md. Both installed environments receive the
# exact run.sh and inner_run.sbatch from this directory.
#
#   setup.sh <run_dir>
#
# Creates, inside the run directory:
#   ENVIRONMENT.md   the goal and how to evaluate
#   run.sh           the evaluation — runs inner evolve loops
#   eval/freeevolve/  a full copy of the evolver repo, which is what the
#                      evaluation actually runs (evolve.sh + the inner envs)
#   eval/inner_run.sbatch  canonical inner runner (submitted or run directly)
#   target/SKILL.md  the evolver's instructions (the edit surface)
#   .target          declares that edit surface: `target/SKILL.md`
#
# Environment variables it reads:
#   META_INNER_ENVS     which inner environments this run may evolve against
#   META_TARGET_SKILL   the edit surface, when it must differ from the skill driving
#                       the run. Defaults to the driver — see "The edit surface".
#   META_BUDGET_HOURS   wall clock stated to the outer evolver. Default: 24.
#   EVOLVE_SKILL_FILE   set by evolve.sh: the skill driving this run. Not for hand use.
#
# The run directory is standalone afterwards: nothing in it refers back to this
# directory, so inner runs launched from here use its own copy and a concurrent
# edit to the source repo cannot change a running evaluation.
#
# Idempotent, and never clobbers an existing target.
set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_SRC="$(cd "$ENV_DIR/../.." && pwd)"   # the freeevolve repo
META_CHAIN_BACKEND="${META_CHAIN_BACKEND:-slurm}"
BACKEND_DIR="${META_CHAIN_BACKEND_DIR:-$ENV_DIR}"
case "$META_CHAIN_BACKEND" in
    slurm|local) ;;
    *) echo "unsupported meta-chain backend: $META_CHAIN_BACKEND" >&2; exit 2 ;;
esac
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
# envs/ is excluded here and populated below, one named environment at a time.
rsync -a --delete \
    --exclude='.git/' \
    --exclude='__pycache__/' \
    --exclude='*.pyc' \
    --exclude='past_sks.md' \
    --exclude='generations/' \
    --exclude='SKILL.md' \
    --exclude='README.md' \
    --exclude='skills/' \
    --exclude='envs/' \
    "$SKILL_SRC/" "$EVAL/freeevolve/"

# This environment's own machinery goes in eval/, like every other environment's.
# It must NOT live under eval/freeevolve/envs/, which is the catalogue of inner
# environments the outer evolver may choose from — anything there is offered as a
# candidate.
cp "$ENV_DIR/inner_run.sbatch" "$EVAL/"

# --- The catalogue of inner environments -------------------------------------
# Only the named environments are copied. This used to copy all of them and delete the
# rest, which failed OPEN: an unset META_INNER_ENVS left every environment in the
# catalogue, and a misspelled one ("arc_agi2") silently deleted the environment that was
# meant to be kept and said nothing. Copying by name fails closed instead — an
# environment that was not asked for is not there, and a name that does not exist stops
# setup.
#
# It is also most of setup's wall clock: the catalogue holds vendored game files and ten
# tau3 subsets, none of which a two-environment run can use.
#
# Space- or comma-separated. The meta environments are never candidates — an inner run
# against one would be a second level of recursion nobody asked for.
META_INNER_ENVS="${META_INNER_ENVS:-}"
mkdir -p "$EVAL/freeevolve/envs"
if [ -n "$META_INNER_ENVS" ]; then
    WANTED="$(echo "$META_INNER_ENVS" | tr ',' ' ')"
else
    # Empty means every non-meta environment, which is the historical behaviour.
    WANTED="$(cd "$SKILL_SRC/envs" && ls -d */ | tr -d '/' | grep -vE '^meta(_|$)' | tr '\n' ' ')"
    echo "[setup] META_INNER_ENVS is unset — copying every non-meta environment"
fi
for name in $WANTED; do
    case "$name" in
        meta|meta_*)
            echo "[setup] refusing to offer $name as an inner environment: a meta run" >&2
            echo "[setup] against a meta environment is a recursion nobody asked for." >&2
            exit 1 ;;
    esac
    [ -d "$SKILL_SRC/envs/$name" ] || {
        echo "[setup] no such inner environment: $name" >&2
        echo "[setup] available: $(cd "$SKILL_SRC/envs" && echo */ | tr -d '/')" >&2
        exit 1
    }
    rsync -a --exclude='__pycache__/' --exclude='*.pyc' \
        "$SKILL_SRC/envs/$name/" "$EVAL/freeevolve/envs/$name/"

    # --- The held-out split, at THIS level ------------------------------------
    # An inner environment's own setup.sh strips VAL_* and narrows the installed data --
    # but it does that when an INNER RUN installs, on that run's private copy. The
    # catalogue copy made just above is the OUTER evolver's, and left alone it keeps both
    # the VAL list and, for any environment vendoring its data inside its own directory,
    # the held-out data itself. An outer evolver can then read the VAL list, assemble a
    # rig from the game or task directories it names, and measure the held-out set --
    # while every inner run correctly sees only TRAIN. The skill it writes has by then
    # been authored beside held-out numbers.
    #
    # So make the same two moves the inner setups make: delete the VAL list, and delete
    # any vendored data that list names. Physical absence rather than a rule to follow --
    # an environment cannot be measured on data that is not in the run.
    _cat="$EVAL/freeevolve/envs/$name"
    # `|| true` inside the substitution, not after it: sed exits non-zero when the file
    # is not there (dummy has no defaults.env), and pipefail would make that the status
    # of the assignment and kill setup under set -e.
    _val="$( { sed -nE 's/^VAL_(TASKS|PUZZLES|GAMES)="([^"]*)".*/\2/p' "$_cat/defaults.env" 2>/dev/null || true; } | tr ',' ' ')"
    sed -i -E '/^VAL_(TASKS|PUZZLES|GAMES)=/d' "$_cat/defaults.env" 2>/dev/null || true
    # Data vendored inside the environment directory. arc_agi_3's games/ is the only such
    # case today; written over the declaration rather than that one name, so an
    # environment that starts vendoring its data is covered without being remembered.
    for _sub in games datasets tasks problems; do
        [ -d "$_cat/$_sub" ] || continue
        for _item in $_val; do
            [ -n "$_item" ] || continue
            if [ -e "$_cat/$_sub/$_item" ]; then
                rm -rf "$_cat/$_sub/$_item"
                echo "[setup]   removed held-out $_sub/$_item from the $name catalogue"
            fi
        done
    done
done
echo "[setup] inner environments available:$(cd "$EVAL/freeevolve/envs" && echo " "$(echo */ | tr -d '/'))"
echo "[setup] VAL_* stripped from every catalogue defaults.env, with any vendored held-out data"

BUDGET_HOURS="${META_BUDGET_HOURS:-24}"
if [ "$META_CHAIN_BACKEND" = "local" ]; then
    if command -v nproc >/dev/null 2>&1; then
        CPUS="$(nproc)"
    else
        CPUS="$(sysctl -n hw.ncpu 2>/dev/null || echo '?')"
    fi
    if [ -r /proc/meminfo ]; then
        MEMGB="$(awk '/MemTotal/ {printf "%.0f", $2/1048576}' /proc/meminfo)"
    else
        MEM_BYTES="$(sysctl -n hw.memsize 2>/dev/null || true)"
        if [ -n "$MEM_BYTES" ]; then
            MEMGB="$((MEM_BYTES / 1073741824))"
        else
            MEMGB="?"
        fi
    fi
    sed -e "s/@@CPUS@@/$CPUS/g" \
        -e "s/@@MEMGB@@/$MEMGB/g" \
        -e "s/@@BUDGET_HOURS@@/$BUDGET_HOURS/g" \
        "$BACKEND_DIR/ENVIRONMENT.md" > "$WS/ENVIRONMENT.md"
    echo "[setup] local backend: $CPUS cores, ${MEMGB} GB, ${BUDGET_HOURS}h"
else
    sed -e "s/@@BUDGET_HOURS@@/$BUDGET_HOURS/g" \
        "$BACKEND_DIR/ENVIRONMENT.md" > "$WS/ENVIRONMENT.md"
    echo "[setup] Slurm backend: ${BUDGET_HOURS}h outer budget"
fi
if grep -q '@@' "$WS/ENVIRONMENT.md"; then
    echo "[setup] unsubstituted placeholder left in ENVIRONMENT.md:" >&2
    grep -n '@@' "$WS/ENVIRONMENT.md" >&2
    exit 1
fi
cp "$ENV_DIR/run.sh" "$WS/run.sh"
chmod +x "$WS/run.sh"
printf '%s\n' "$META_CHAIN_BACKEND" > "$WS/.meta_chain_backend"

# Where the edit surface lives, relative to the run directory. Here it is a single
# FILE, not a directory — the declaration accommodates either.
echo "target/SKILL.md" > "$WS/.target"

# --- The edit surface --------------------------------------------------------
# This environment is unusual: the skill under evaluation and the skill the outer
# agent RUNS are the same kind of file, and they need not be the same file. The
# outer agent's own prompt is chosen by evolve.sh (its third argument); the edit
# surface is what gets installed here.
#
# They default TOGETHER, to the skill that is driving this run — so `evolve.sh
# meta_chain <dir> <skill>` improves the skill it is running, which is what a meta
# run means unless someone says otherwise. META_TARGET_SKILL overrides the edit
# surface alone, for the deliberate case of one skill improving another.
#
# It used to default to the repo's SKILL.md instead, and that was a real trap: a
# launch that named a skill on the command line set only the DRIVER, while the edit
# surface silently became whatever version happened to be promoted in the repo —
# often stale and from another lineage. The run then reads as if it were evaluating the
# skill that drove it, and a whole run is wasted. Both roles are printed below, with
# fingerprints, and a mismatch is called out.
TARGET_SKILL_SRC="${META_TARGET_SKILL:-${EVOLVE_SKILL_FILE:-$SKILL_SRC/SKILL.md}}"
[ -f "$TARGET_SKILL_SRC" ] || {
    echo "[setup] no skill file at $TARGET_SKILL_SRC" >&2
    exit 1
}
_fp() { printf '%s  %s lines' "$(md5sum "$1" | cut -c1-8)" "$(wc -l < "$1")"; }
DRIVER_SKILL="${EVOLVE_SKILL_FILE:-$SKILL_SRC/SKILL.md}"
echo "[setup] driving skill: $(_fp "$DRIVER_SKILL")  $DRIVER_SKILL"
echo "[setup] edit surface : $(_fp "$TARGET_SKILL_SRC")  $TARGET_SKILL_SRC"
if ! cmp -s "$DRIVER_SKILL" "$TARGET_SKILL_SRC"; then
    echo "[setup] NOTE: these are DIFFERENT files. This run improves one skill while"
    echo "[setup]       being driven by another. Intended only when META_TARGET_SKILL"
    echo "[setup]       says so; its results are not evidence about the driver."
fi
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

echo "[setup] meta_chain ($META_CHAIN_BACKEND backend) installed in $WS"
