#!/usr/bin/env bash
# Make sure this node has the tau3 base image, building it if not.
#
#   bash ensure-base-image.sh
#
# WHY THIS EXISTS. Every tau3 task ships two Dockerfiles, both `FROM
# python:3.12-slim`, and each of them installs the same three packages: boto3 and a
# pinned litellm (so LiteLLM can reach Bedrock) and mcp (which the agent runner
# imports). harbor builds task images at the evaluation's concurrency, so a single
# evaluation asks PyPI for the same wheels dozens of times within a few seconds, from
# one address. PyPI answers the burst with 502s, pip exhausts its retries, and the
# build fails — which surfaces as a failed trial, scored 0, indistinguishable from a
# bad agent unless someone reads n_errors.
#
# Moving the install from trial time to build time does not fix that; it moves the
# same burst from one place to another. The wheel is fine — it downloads in under a
# second when nothing else is asking for it. What has to change is HOW OFTEN it is
# asked for.
#
# So the packages are installed once, into one image, per node. Task Dockerfiles then
# say `FROM` this image and their own pip lines become no-ops ("already satisfied"),
# which needs no network. PyPI sees three requests per node instead of thousands per
# evaluation.
#
# Idempotent and safe to call concurrently: the build is guarded by a lock, and a
# second caller that finds the image present returns immediately.
set -euo pipefail

BASE_IMAGE="${TAU3_BASE_IMAGE:-freeevolve/tau3-base:v1}"
LITELLM_PIN="${LITELLM_PIN:-litellm==1.94.0}"
MCP_PIN="${MCP_PIN:-mcp==1.25.0}"
AWS_REGION_BAKED="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-west-2}}"
LOCK="/tmp/.tau3_base_image.lock"

command -v docker >/dev/null || { echo "[base-image] docker not on PATH" >&2; exit 1; }

if docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
    echo "[base-image] $BASE_IMAGE already present on $(hostname)"
    exit 0
fi

# One builder per node. Others wait, then find the image and return.
exec 9>"$LOCK"
if ! flock -w 900 9; then
    echo "[base-image] timed out waiting for another builder" >&2
    exit 1
fi
if docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
    echo "[base-image] $BASE_IMAGE built by another process while waiting"
    exit 0
fi

CTX="$(mktemp -d)"
trap 'rm -rf "$CTX"' EXIT
cat > "$CTX/Dockerfile" <<EOF
FROM python:3.12-slim

# Everything every tau3 task image needs, installed once here instead of once per
# task image per evaluation. Retries are generous because this build is the ONLY
# place that touches PyPI now — it is worth waiting out a transient failure here to
# avoid one downstream.
RUN pip install --no-cache-dir --retries 20 --timeout 120 boto3
RUN pip install --no-cache-dir --retries 20 --timeout 120 --upgrade '$LITELLM_PIN'
RUN pip install --no-cache-dir --retries 20 --timeout 120 '$MCP_PIN'

# LiteLLM's Bedrock provider needs a region in-container; credentials come from the
# instance role over IMDS.
ENV AWS_REGION=$AWS_REGION_BAKED
ENV AWS_DEFAULT_REGION=$AWS_REGION_BAKED
EOF

echo "[base-image] building $BASE_IMAGE on $(hostname)"
# A few attempts with backoff: this is one build, so waiting is cheap, and a failure
# here would otherwise fail every task image on the node.
built=0
for attempt in 1 2 3; do
    if docker build --quiet -t "$BASE_IMAGE" "$CTX" >/dev/null; then
        built=1; break
    fi
    echo "[base-image] build attempt $attempt failed; retrying" >&2
    sleep $((attempt * 30))
done
[ "$built" = "1" ] || { echo "[base-image] could not build $BASE_IMAGE" >&2; exit 1; }

echo "[base-image] $BASE_IMAGE ready:"
docker run --rm "$BASE_IMAGE" python3 -c \
    "import importlib.metadata as m, mcp, boto3, litellm; \
     print('  litellm', m.version('litellm'), '| mcp', m.version('mcp'), '| boto3', m.version('boto3'))"
