#!/usr/bin/env bash
# Install the GAIA2 CLI-mode evaluation into a run directory.
#
#   setup.sh <run_dir>
#
# Creates, inside the run directory:
#   run.sh                  the evaluation
#   eval/defaults.env       models and generation settings
#   eval/.venv              harbor, plus what task generation needs
#   eval/adapter/           the GAIA2 adapter, copied and patched for Bedrock
#   eval/datasets/gaia2-cli one directory per generated scenario
#
# Environment variables it reads:
#   HARBOR_ROOT       a harbor checkout holding adapters/gaia2. Unset: one is cloned
#                     at a pinned commit and cached (lib/ensure_harbor.sh)
#   GAIA2_CONFIGS     which configs to materialize (default: all five)
#   GAIA2_IDS_FILE    restrict generation to these source ids; "parity" resolves to
#                     the adapter's own 100-task stratified subset
#   GAIA2_LIMIT       stop after this many tasks (for smoke tests)
#   GAIA2_DATASET_SRC reuse an already-generated task directory instead of
#                     downloading and regenerating (~2 GB per config from HF)
#
# The run directory is standalone afterwards: nothing in it refers back here.
set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${1:?usage: setup.sh <run_dir>}"
mkdir -p "$WS"
WS="$(cd "$WS" && pwd)"
EVAL="$WS/eval"
# The harbor checkout this environment reads its adapter from. When HARBOR_ROOT is
# already set it is used as-is; otherwise a clone is made at a pinned commit and
# cached, so setup needs nothing prepared by hand. See lib/ensure_harbor.sh.
# shellcheck source=../../lib/ensure_harbor.sh
source "$(cd "$ENV_DIR/../.." && pwd)/lib/ensure_harbor.sh"
ensure_harbor

for c in uv docker curl rsync; do
    command -v "$c" >/dev/null || { echo "$c not found on PATH" >&2; exit 1; }
done

# --- Docker Compose v2 (CLI mode is a two-container task) ---------------------
# Unlike the single-container environments, this one cannot run at all without
# compose: the ARE sidecar is a second service the task brings up.
if ! docker compose version >/dev/null 2>&1; then
    echo "[setup] installing Docker Compose v2 plugin under ~/.docker/cli-plugins/"
    mkdir -p "$HOME/.docker/cli-plugins"
    curl -fSL \
        "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" \
        -o "$HOME/.docker/cli-plugins/docker-compose"
    chmod +x "$HOME/.docker/cli-plugins/docker-compose"
    docker compose version >/dev/null 2>&1 || {
        echo "[setup] docker compose still not working after install" >&2; exit 1; }
fi
echo "[setup] docker compose: $(docker compose version --short 2>/dev/null || echo present)"

source "$ENV_DIR/defaults.env"

# --- The evaluation venv ------------------------------------------------------
# uv's cache defaults to $HOME, which is shared NFS here; concurrent installs then
# race on the same archive entries and the losers die mid-install. A node-local
# cache removes the race and is still reused across runs on that node.
export UV_CACHE_DIR="${UV_CACHE_DIR:-/tmp/uv-cache-$(id -u)}"
mkdir -p "$UV_CACHE_DIR"
echo "[setup] uv cache: $UV_CACHE_DIR"

mkdir -p "$EVAL"
VENV_PY="$EVAL/.venv/bin/python"
if [ ! -x "$VENV_PY" ]; then
    uv venv --python 3.12 "$EVAL/.venv"
fi
# --python pins the install to THIS venv, so an ambient VIRTUAL_ENV cannot send
# harbor somewhere else.
uv pip install --quiet --python "$VENV_PY" harbor
# boto3 for litellm's Bedrock provider; datasets/huggingface_hub for generation.
uv pip install --quiet --python "$VENV_PY" boto3 datasets huggingface_hub
echo "[setup] harbor: $("$EVAL/.venv/bin/harbor" --version 2>/dev/null || echo installed)"

cp "$ENV_DIR/defaults.env" "$EVAL/"
cp "$ENV_DIR/run.sh" "$WS/run.sh"
chmod +x "$WS/run.sh"

# --- The adapter, copied out of the harbor checkout and patched ---------------
# Copied rather than used in place: the checkout is shared and must not be edited,
# and a run that carries its own adapter can still be read afterwards even if the
# checkout has moved on.
ADAPTER_SRC="$HARBOR_ROOT/adapters/gaia2"
[ -d "$ADAPTER_SRC" ] || { echo "[setup] no gaia2 adapter at $ADAPTER_SRC" >&2; exit 1; }
rm -rf "$EVAL/adapter"
rsync -a --exclude='__pycache__/' "$ADAPTER_SRC/" "$EVAL/adapter/"
"$VENV_PY" "$ENV_DIR/patch_adapter.py" "$EVAL/adapter" "$DEFAULT_JUDGE_MODEL"
printf '%s\n' "$ADAPTER_SRC" > "$EVAL/.adapter_source"

# --- The tasks ----------------------------------------------------------------
DATASET_DIR="$EVAL/$DATASET_SUBDIR"
if [ -n "${GAIA2_DATASET_SRC:-}" ]; then
    [ -d "$GAIA2_DATASET_SRC" ] || {
        echo "[setup] GAIA2_DATASET_SRC is not a directory: $GAIA2_DATASET_SRC" >&2; exit 1; }
    echo "[setup] copying prebuilt tasks from $GAIA2_DATASET_SRC"
    mkdir -p "$(dirname "$DATASET_DIR")"
    rsync -a "$GAIA2_DATASET_SRC/" "$DATASET_DIR/"
elif [ -d "$DATASET_DIR" ] && [ -n "$(ls -A "$DATASET_DIR" 2>/dev/null)" ]; then
    echo "[setup] tasks already present at $DATASET_DIR — leaving them alone"
else
    GEN_ARGS=(--cli --output-dir "$DATASET_DIR" --overwrite)
    # shellcheck disable=SC2206
    GEN_ARGS+=(--configs ${GAIA2_CONFIGS:-execution search adaptability time ambiguity})
    IDS_FILE="${GAIA2_IDS_FILE:-}"
    if [ "$IDS_FILE" = "parity" ]; then
        IDS_FILE="$EVAL/adapter/parity_sample_source_ids.txt"
    fi
    if [ -n "$IDS_FILE" ]; then
        [ -f "$IDS_FILE" ] || { echo "[setup] no ids file at $IDS_FILE" >&2; exit 1; }
        GEN_ARGS+=(--ids-file "$IDS_FILE")
        echo "[setup] restricting generation to ids in $IDS_FILE"
    fi
    [ -n "${GAIA2_LIMIT:-}" ] && GEN_ARGS+=(--limit "$GAIA2_LIMIT")

    # Each config's parquet is ~400 MB and every scenario is a ~2.5 MB JSON, so
    # this step downloads and writes real volume. Run from the adapter directory:
    # run_adapter.py falls back to a bare `from adapter import ...` when it is not
    # imported as part of the harbor package.
    echo "[setup] generating tasks (this downloads the official dataset from HF)"
    ( cd "$EVAL/adapter" && "$VENV_PY" run_adapter.py "${GEN_ARGS[@]}" )
fi
echo "[setup] tasks: $(ls -A "$DATASET_DIR" 2>/dev/null | wc -l) at $DATASET_DIR"

echo "[setup] gaia2 CLI evaluation installed in $WS"
