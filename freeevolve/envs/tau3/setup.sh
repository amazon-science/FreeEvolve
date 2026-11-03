#!/usr/bin/env bash
# Install the tau3-bench environment into a run directory.
#
#   setup.sh <run_dir>
#
# Creates, inside the run directory:
#   ENVIRONMENT.md     the goal and how to evaluate
#   run.sh             the evaluation
#   eval/              harbor's venv, the generated dataset, tau2-bench, the
#                      patched adapter, the split definitions
#   agent/tau3_agent/  the starting agent (the edit surface), copied from this
#                      directory's agent/ — vendored and fixed, not taken from
#                      the harbor checkout
#   .target            declares that edit surface: `agent/tau3_agent`
#
# The run directory is standalone afterwards: nothing in it refers back to this
# directory. Idempotent, and never clobbers an existing agent.
#
# tau3 runs THREE model roles inside containers, all routed to Bedrock:
#   the agent (harbor -m), the simulated user (TAU2_USER_MODEL), and the
#   NL-assertion judge (TAU2_NL_ASSERTIONS_MODEL). LiteLLM's Bedrock provider
#   needs boto3 and a region in-container, so both generated Dockerfiles are
#   patched to install boto3 + a recent litellm and pin AWS_REGION.
#
# Dataset generation needs the tau3-bench adapter, which lives in a harbor checkout
# rather than in the published harbor package. One is cloned at a pinned commit and
# cached unless HARBOR_ROOT already names a checkout. Only the dataset and the
# container Dockerfiles come from there; the agent does not. Generation takes many
# minutes, so a prebuilt dataset is reused when TAU3_DATASET_SRC points at one.
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
ADAPTER_SRC_DIR="$HARBOR_ROOT/adapters/tau3-bench"
TAU2_BENCH_REPO="https://github.com/sierra-research/tau2-bench.git"

# Region baked into the container images so LiteLLM's Bedrock provider has one.
AWS_REGION_BAKED="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-west-2}}"
# litellm must be recent enough to know the newer Bedrock models, so that
# drop_params=True strips params they no longer accept (e.g. temperature).
# mcp is pinned here too because it is baked into the image rather than fetched at
# trial time — see patch_mcp_preinstall below for why that matters.
LITELLM_PIN="${LITELLM_PIN:-litellm==1.94.0}"
MCP_PIN="${MCP_PIN:-mcp==1.25.0}"
# One image per node carrying boto3 + litellm + mcp, which every task image would
# otherwise install for itself. See ensure-base-image.sh.
#
# The tag is derived from the pins rather than hand-written. A hand-written tag is a
# trap: the build is guarded by `docker image inspect`, so changing LITELLM_PIN and
# leaving the tag alone means every node that already holds the old image keeps using
# it, silently, and two nodes disagree about what the image contains. Deriving the tag
# means a changed pin is a different image everywhere at once.
TAU3_PIN_TAG="$(printf '%s|%s' "$LITELLM_PIN" "$MCP_PIN" | md5sum | cut -c1-8)"
TAU3_BASE_IMAGE="${TAU3_BASE_IMAGE:-freeevolve/tau3-base:$TAU3_PIN_TAG}"

# An already-generated dataset to copy instead of regenerating. Generation is
# the slowest part of setup by far.
TAU3_DATASET_SRC="${TAU3_DATASET_SRC:-}"

for c in uv docker git curl; do
    command -v "$c" >/dev/null || { echo "$c not found on PATH" >&2; exit 1; }
done

# --- Docker Compose v2 (harbor needs the `docker compose` subcommand) --------
if ! docker compose version >/dev/null 2>&1; then
    echo "[setup] installing Docker Compose v2 plugin under ~/.docker/cli-plugins/"
    mkdir -p "$HOME/.docker/cli-plugins"
    curl -fSL \
        "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" \
        -o "$HOME/.docker/cli-plugins/docker-compose"
    chmod +x "$HOME/.docker/cli-plugins/docker-compose"
    docker compose version >/dev/null 2>&1 || {
        echo "[setup] docker compose still not working after install" >&2
        exit 1
    }
fi
echo "[setup] docker compose: $(docker compose version --short 2>/dev/null || echo present)"

# --- harbor venv -------------------------------------------------------------
mkdir -p "$EVAL"
VENV_PY="$EVAL/.venv/bin/python"
if [ ! -x "$VENV_PY" ]; then
# uv's cache defaults to $HOME, which is shared NFS on this cluster. Several run
# directories being installed at the same time then hardlink out of the same archive
# entry, and every loser of that race dies with "failed to hardlink ... No such file
# or directory" partway through the install. Each job owns its node, so a node-local
# cache removes the race and is still reused across runs on that node.
export UV_CACHE_DIR="${UV_CACHE_DIR:-/tmp/uv-cache-$(id -u)}"
mkdir -p "$UV_CACHE_DIR"

    uv venv --python 3.12 "$EVAL/.venv"
fi
# --python pins the install to THIS venv, so an ambient VIRTUAL_ENV cannot
# redirect it.
uv pip install --quiet --python "$VENV_PY" harbor
# litellm's Bedrock provider needs boto3 host-side too, for harbor's own model
# resolution and cost accounting.
uv pip install --quiet --python "$VENV_PY" boto3
echo "[setup] harbor: $("$EVAL/.venv/bin/harbor" --version 2>/dev/null || echo installed)"

# --- tau2-bench checkout (task data, policies, and the in-image runtime) -----
TAU2_BENCH_ROOT="$EVAL/tau2-bench"
if [ ! -d "$TAU2_BENCH_ROOT/.git" ]; then
    echo "[setup] cloning tau2-bench"
    git clone --quiet --depth 1 "$TAU2_BENCH_REPO" "$TAU2_BENCH_ROOT"
fi

# --- adapter copy, patched for Bedrock --------------------------------------
# Copied rather than used in place, so the shared harbor tree is never mutated.
# Generation reads the task templates relative to the adapter source, so
# patching this copy is sufficient.
ADAPTER_DIR="$EVAL/adapter"
if [ ! -d "$ADAPTER_DIR" ]; then
    [ -d "$ADAPTER_SRC_DIR" ] || {
        echo "[setup] tau3-bench adapter not found at $ADAPTER_SRC_DIR" >&2
        echo "[setup] set HARBOR_ROOT to a harbor checkout containing adapters/tau3-bench" >&2
        exit 1
    }
    cp -r "$ADAPTER_SRC_DIR" "$ADAPTER_DIR"
fi

# Pre-install mcp into the image.
#
# The agent's install() runs `pip install litellm mcp` inside the container at the
# start of EVERY trial. litellm is already baked in by the patch above, so only mcp
# was fetched — once per trial, from files.pythonhosted.org. With several
# evaluations in flight that is hundreds of concurrent requests, PyPI answers 502,
# pip exhausts its default five retries, and agent setup raises
# NonZeroAgentExitCodeError. The trial is then scored 0.
#
# That is much worse than a slow trial, because nothing downstream can tell it from a
# bad agent: an untouched agent whose trials mostly failed this way scores near zero and
# reads as a terrible agent. Baking mcp into the image removes the per-trial network
# call.
#
# Separately marked from the bedrock patch so that a dataset carrying only the older
# patch is upgraded rather than skipped.
patch_mcp_preinstall() {
    local dockerfile="$1"
    [ -f "$dockerfile" ] || { echo "[setup] missing Dockerfile: $dockerfile" >&2; exit 1; }
    grep -q "# >>> mcp-preinstall patch" "$dockerfile" && return 0
    cat >>"$dockerfile" <<EOF

# >>> mcp-preinstall patch (added by freeevolve tau3 setup.sh)
RUN pip install --no-cache-dir --retries 10 --timeout 60 '$MCP_PIN'
# <<< mcp-preinstall patch
EOF
}

patch_dockerfile_for_bedrock() {
    local dockerfile="$1"
    [ -f "$dockerfile" ] || { echo "[setup] missing Dockerfile: $dockerfile" >&2; exit 1; }
    grep -q "# >>> bedrock-litellm patch" "$dockerfile" && return 0
    cat >>"$dockerfile" <<EOF

# >>> bedrock-litellm patch (added by freeevolve tau3 setup.sh)
# LiteLLM's Bedrock provider needs boto3 in-container; AWS creds come from the
# instance role over IMDS, so only a region needs pinning here.
RUN pip install --no-cache-dir boto3
# tau2-bench's base pins litellm<1.82.7, which predates the newer Bedrock models
# and so does NOT drop their unsupported \`temperature\` param under
# drop_params=True — InvokeModel then fails. Installed last so it wins.
RUN pip install --no-cache-dir --upgrade '$LITELLM_PIN'
ENV AWS_REGION=$AWS_REGION_BAKED
ENV AWS_DEFAULT_REGION=$AWS_REGION_BAKED
# <<< bedrock-litellm patch
EOF
    echo "[setup] patched for Bedrock: $(basename "$(dirname "$dockerfile")")/Dockerfile"
}

TEMPLATE_DIR="$ADAPTER_DIR/src/tau3_bench/task-template"
patch_dockerfile_for_bedrock "$TEMPLATE_DIR/environment/Dockerfile"
patch_dockerfile_for_bedrock "$TEMPLATE_DIR/environment/runtime-server/Dockerfile"
patch_mcp_preinstall "$TEMPLATE_DIR/environment/Dockerfile"
patch_mcp_preinstall "$TEMPLATE_DIR/environment/runtime-server/Dockerfile"

# --- the dataset -------------------------------------------------------------
DATASET_DIR="$EVAL/datasets/tau3-bench"
if [ ! -d "$DATASET_DIR" ] || [ -z "$(ls -A "$DATASET_DIR" 2>/dev/null)" ]; then
    if [ -n "$TAU3_DATASET_SRC" ] && [ -d "$TAU3_DATASET_SRC" ]; then
        echo "[setup] copying prebuilt dataset from $TAU3_DATASET_SRC"
        mkdir -p "$(dirname "$DATASET_DIR")"
        cp -r "$TAU3_DATASET_SRC" "$DATASET_DIR"
        # A prebuilt dataset was generated at some point in the past, so it carries
        # whatever patches existed then. Re-apply here rather than trusting it:
        # the check is a grep per Dockerfile and it removes a silent dependence on
        # which vintage of dataset happens to be on disk. Idempotent.
        _n=0
        while IFS= read -r _df; do
            grep -q "# >>> mcp-preinstall patch" "$_df" || { patch_mcp_preinstall "$_df"; _n=$((_n+1)); }
        done < <(find "$DATASET_DIR" -name Dockerfile)
        [ "$_n" != "0" ] && echo "[setup] mcp pre-install added to $_n Dockerfile(s) in the copied dataset"
    else
        echo "[setup] generating dataset (this takes several minutes)"
        PYTHONPATH="$ADAPTER_DIR/src" TAU2_BENCH_ROOT="$TAU2_BENCH_ROOT" \
            "$VENV_PY" -m tau3_bench.main --output-dir "$DATASET_DIR" --overwrite
    fi

    # The run's dataset is the TRAIN split. VAL is not in it, so a run cannot evaluate
    # on the reported half -- the same way arc_agi_2 materializes only its TRAIN puzzles
    # and arc_agi_3 installs only its TRAIN games. Whatever is here is the whole set as
    # far as this run is concerned.
    #
    # TAU3_FULL_SET=1 keeps everything, and is for measuring a finished nomination on VAL.
    if [ "${TAU3_FULL_SET:-0}" != "1" ]; then
        # Read from the env's own defaults.env. This script does not source it, so naming
        # $TRAIN_TASKS directly was an unbound variable under `set -u` and killed every
        # tau3 inner run at setup. Taking it from the file also means the caller's
        # environment cannot decide which tasks a run gets.
        _keep=" $( . "$ENV_DIR/defaults.env"; echo "$TRAIN_TASKS" | tr ',' ' ' ) "
        _dropped=0
        for _d in "$DATASET_DIR"/*/; do
            [ -d "$_d" ] || continue
            _t="$(basename "$_d")"
            case "$_keep" in
                *" $_t "*) ;;
                *) rm -rf "$_d"; _dropped=$((_dropped+1)) ;;
            esac
        done
        echo "[setup] dataset narrowed to the frozen TRAIN split: $(ls -A "$DATASET_DIR" | wc -l) tasks ($_dropped removed)"
    fi
fi

# --- put the pip layers where they can actually be cached ------------------------
# Both patch blocks are APPENDED to a Dockerfile, which puts them at the end. In the
# runtime-server Dockerfile the end is below `COPY server.py` and `COPY
# task_config.json`, and task_config.json differs per task — so the layer above the
# pip lines is unique to each of the 68 tasks, every pip line below it is a cache
# miss, and each task image fetches the same wheels again. At concurrency 32 that is
# dozens of simultaneous requests for a 34MB litellm wheel, which is what PyPI
# answers with 502s.
#
# The base image did not fix this, and the reason is worth writing down: the task
# Dockerfile installs tau2-bench, tau2-bench pins litellm<1.82.7, and that DOWNGRADES
# the litellm the base image had already installed. So the `--upgrade` line below it
# genuinely has to reach the network — "already satisfied" was never going to happen.
# (boto3 and mcp are untouched by tau2-bench and do come back satisfied, which is why
# only litellm showed up in the failures.)
#
# So the pip lines have to stay AFTER the tau2-bench install, or tau2 clobbers them
# again, and move ABOVE the first COPY, where the layer is identical for every task
# and is built once per node. Order within the blocks is preserved.
reorder_pip_before_copy() {
    local dockerfile="$1"
    [ -f "$dockerfile" ] || return 0
    "$VENV_PY" - "$dockerfile" <<'PY'
import re, sys

path = sys.argv[1]
lines = open(path).read().split("\n")

# The marker-delimited blocks, in the order they appear.
blocks, keep, i = [], [], 0
while i < len(lines):
    m = re.match(r'^# >>> (\S+) patch', lines[i])
    if m:
        end = m.group(1)
        j = i
        while j < len(lines) and not re.match(rf'^# <<< {re.escape(end)} patch', lines[j]):
            j += 1
        blocks.append(lines[i:j + 1])
        i = j + 1
        # swallow one blank line that belonged to the appended block
        if i < len(lines) and lines[i].strip() == "":
            i += 1
        continue
    keep.append(lines[i])
    i += 1

if not blocks:
    sys.exit(0)

first_copy = next((k for k, l in enumerate(keep)
                   if re.match(r'^\s*COPY\s', l)), None)
if first_copy is None:
    # No COPY at all (the main image): appending was already cacheable, so leave
    # the file exactly as it was rather than churning it for nothing.
    sys.exit(0)

insert = first_copy
while insert > 0 and keep[insert - 1].strip() == "":
    insert -= 1

flat = []
for b in blocks:
    flat.extend(b + [""])

out = keep[:insert] + [""] + flat + keep[insert:]
text = "\n".join(out)
# collapse any run of blank lines the surgery produced
text = re.sub(r'\n{3,}', '\n\n', text)
open(path, "w").write(text)
print(f"[setup] moved {len(blocks)} pip block(s) above the first COPY in {path}")
PY
}

_r=0
while IFS= read -r _df; do
    # Only the files that actually have a COPY below their pip lines change.
    if awk '/^# >>> .* patch/{p=NR} /^[[:space:]]*COPY[[:space:]]/{if(!c)c=NR} END{exit !(p && c && c < p)}' "$_df"; then
        reorder_pip_before_copy "$_df" >/dev/null && _r=$((_r+1))
    fi
done < <(find "$DATASET_DIR" -name Dockerfile)
[ "$_r" != "0" ] && echo "[setup] pip layers moved above the per-task COPY in $_r Dockerfile(s) — those layers now cache once per node"

# --- point the task images at a base image built once on this node ---------------
# Each task ships two Dockerfiles and each installs boto3, litellm and mcp for
# itself. harbor builds those images at the evaluation's concurrency, so one
# evaluation asks PyPI for the same wheels dozens of times within seconds from a
# single address; PyPI answers the burst with 502s and the build fails. A failed
# build is a failed trial, scored 0, and a score of 0 is indistinguishable from a bad
# agent unless someone reads n_errors. So the packages are installed once per node
# and the task images inherit them, after which their own pip lines are no-ops.
#
# Rewritten in THIS run's copy of the dataset rather than in the shared source, so a
# run directory stays self-contained: a run set up before this existed keeps building
# the way it always did, and nothing outside this directory changes meaning.
#
# The rewrite is conditional on the image existing. Pointing a Dockerfile at an image
# that is not there would fail every build on the node, which is worse than the
# problem being fixed.
export TAU3_BASE_IMAGE LITELLM_PIN MCP_PIN
if bash "$ENV_DIR/ensure-base-image.sh"; then
    _dfs="$(grep -rl '^FROM python:3.12-slim$' "$DATASET_DIR" --include=Dockerfile || true)"
    if [ -n "$_dfs" ]; then
        printf '%s\n' "$_dfs" | xargs sed -i "s|^FROM python:3.12-slim\$|FROM $TAU3_BASE_IMAGE|"
        echo "[setup] $(printf '%s\n' "$_dfs" | wc -l) task Dockerfile(s) now build FROM $TAU3_BASE_IMAGE"
    fi
else
    echo "[setup] WARNING: no base image; task images will install their own packages" >&2
fi
echo "[setup] dataset: $(ls -A "$DATASET_DIR" | wc -l) tasks"

# --- the evaluation ----------------------------------------------------------
cp "$ENV_DIR/defaults.env" "$EVAL/"

# The VAL half is not this run's business. It is declared in the repo's defaults.env, which
# is what tooling reads; the copy installed here has it removed so a run cannot read the
# held-out ids out of its own configuration.
sed -i -E '/^VAL_(TASKS|PUZZLES|GAMES)=/d' "$EVAL/defaults.env"
[ -f "$ENV_DIR/configure-docker-pool.sh" ] && cp "$ENV_DIR/configure-docker-pool.sh" "$EVAL/"

cp "$ENV_DIR/ENVIRONMENT.md" "$WS/ENVIRONMENT.md"
cp "$ENV_DIR/run.sh" "$WS/run.sh"
chmod +x "$WS/run.sh"

# Where the edit surface lives, relative to the run directory. harbor imports the
# agent as `tau3_llm_agent:Tau3LLMAgent`, so the directory holding the module must
# be on PYTHONPATH — agent/tau3_agent is that directory. Declaring the real path
# means the agent is edited where it runs; no staging copy stands between what is
# edited and what is measured.
echo "agent/tau3_agent" > "$WS/.target"

# --- the edit surface --------------------------------------------------------
# Both files must sit side by side: tau3_llm_agent.py uploads
# run_tau3_llm_agent.py into the container at agent-install time, resolving it
# with Path(__file__).with_name(...).
# The agent is vendored in this environment (agent/), not copied from harbor. It
# began as harbor's tau3-bench adapter agent and has been fixed since — the
# litellm pin, and the extended-thinking path, where upstream drops the thinking
# blocks a resent tool-use turn needs, aborts the conversation on a
# reasoning-only turn, and does not force the temperature the API requires. Fix
# anything else found here too, so a run directory always installs a known-good
# starting agent rather than whatever the harbor checkout happens to be at.
#
# TAU3_AGENT_SRC starts this run from an agent someone else left behind, instead
# of the vendored one — so a run can continue from a previous run's best rather
# than from scratch. It names a directory holding both modules. The files are
# COPIED, so the run stays standalone and editing them cannot reach back into
# whatever produced them.
#
# Note what this changes about the numbers: the inherited agent becomes this run's
# `.target_pristine` (below), so "unchanged" here means what this run was handed,
# not what the environment ships. A baseline measured in this run is a baseline of
# the inherited agent, and is NOT comparable to a cold run's baseline.
AGENT_DIR="$WS/agent/tau3_agent"
AGENT_SRC_DIR="${TAU3_AGENT_SRC:-$ENV_DIR/agent}"
if [ -d "$AGENT_DIR" ]; then
    echo "[setup] $AGENT_DIR already exists — leaving it alone"
else
    for f in tau3_llm_agent.py run_tau3_llm_agent.py; do
        [ -f "$AGENT_SRC_DIR/$f" ] || {
            echo "[setup] agent source $AGENT_SRC_DIR is missing $f" >&2
            echo "[setup] it must hold both agent modules" >&2
            exit 1
        }
    done
    mkdir -p "$AGENT_DIR"
    # Everything the source holds, not just the two required modules. An agent may
    # have been split into more files than it started with, and copying only the
    # names known here would drop them silently — the run would then fail on import,
    # far from the cause. Compiled bytecode is excluded: it is stale by construction.
    rsync -a --exclude='__pycache__/' --exclude='*.pyc' \
        "$AGENT_SRC_DIR/" "$AGENT_DIR/"
    if [ -n "${TAU3_AGENT_SRC:-}" ]; then
        echo "[setup] agent at $AGENT_DIR (inherited from $AGENT_SRC_DIR)"
        # Recorded so a finished run says what it started from. Without it, a
        # warm-started run is indistinguishable from a cold one afterwards, and
        # its baseline would be silently misread as the environment's own.
        printf '%s\n' "$AGENT_SRC_DIR" > "$WS/.agent_source"
    else
        echo "[setup] agent at $AGENT_DIR (vendored)"
    fi
fi

# The fixed model capability must survive an inheritance. An ancestor that lost it
# would change what every later number in the chain means, silently.
for f in tau3_llm_agent.py run_tau3_llm_agent.py; do
    grep -q 'DEFAULT_REASONING_EFFORT = "medium"' "$AGENT_DIR/$f" || {
        echo "[setup] $f does not set DEFAULT_REASONING_EFFORT = \"medium\"." >&2
        echo "[setup] The model capability is fixed; see ENVIRONMENT.md." >&2
        exit 1
    }
done
grep -q 'DEFAULT_MAX_TOKENS = 16384' "$AGENT_DIR/run_tau3_llm_agent.py" || {
    echo "[setup] run_tau3_llm_agent.py does not set DEFAULT_MAX_TOKENS = 16384." >&2
    echo "[setup] The output budget is part of that fixed capability; see" >&2
    echo "[setup] ENVIRONMENT.md." >&2
    exit 1
}

# Everything the edit surface holds, so run.sh's capability check has the whole of
# what this run was handed to compare against. Copying only the modules named above
# would leave a file the run adds later looking like it was always there.
rm -rf "$WS/.target_pristine"
mkdir -p "$WS/.target_pristine"
rsync -a --exclude='__pycache__/' --exclude='*.pyc' \
    "$AGENT_DIR/" "$WS/.target_pristine/"

echo "[setup] tau3-bench environment installed in $WS"
