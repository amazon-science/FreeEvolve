#!/usr/bin/env bash
#
# configure-docker-pool.sh — tune this node's Docker daemon for high-concurrency
# benchmark runs. Sets two daemon.json keys:
#
#   1. default-address-pools: base 172.20.0.0/14, size 24 -> 1024 networks x
#      254 IPs. Fixes the ~16-network wall (Docker's built-in default carves
#      only ~16 /16 blocks from 172.16.0.0/12). Stays inside Docker's private
#      range and avoids both docker0 (172.17/16) and this cluster's VPC
#      (10.3.x/20), so it cannot collide with host networking.
#   2. max-concurrent-downloads: 64. Docker's default of 3 serializes cold
#      multi-GB image pulls and can blow past the per-container start timeout
#      (EnvironmentStartTimeoutError) at high concurrency. Matches env_setup.sh.
#
# This is the ONLY place daemon.json is edited for the cluster. env_setup.sh's
# daemon steps are NOT used (they set a VPC-colliding 10.0.0.0/8 base).
#
# DEFENSIVE / SELF-HEALING:
#   * Refuses to touch a node with running containers.
#   * Idempotent: exits 0 if the pool is already configured.
#   * Backs up any existing daemon.json and merges (preserves other keys).
#   * Clears systemd's start rate-limit before every (re)start, so repeated
#     runs can't trip StartLimitBurst and strand the daemon.
#   * Restarts Docker AT MOST ONCE on the happy path.
#   * POLLS for health (daemon active + pool reported + real network
#     allocation) instead of a fixed sleep.
#   * On ANY failure, rolls back to the prior config and brings Docker back
#     up. The node is never left down or on a bad config.
#
set -uo pipefail   # no -e: we handle every error explicitly to roll back.

DAEMON_JSON="/etc/docker/daemon.json"
POOL_BASE="172.20.0.0/14"
POOL_SIZE="24"
MAX_CONCURRENT_DOWNLOADS="64"
READY_TIMEOUT=30        # seconds to wait for docker to report the pool
BACKUP=""

log()  { printf '\n\033[1;34m==>\033[0m [%s] %s\n' "$(hostname)" "$*"; }
warn() { printf '\n\033[1;33m[warn]\033[0m [%s] %s\n' "$(hostname)" "$*"; }
die()  { printf '\n\033[1;31m[FAIL]\033[0m [%s] %s\n' "$(hostname)" "$*"; exit 1; }

# Restart Docker safely: clear any prior rate-limit lockout first, then
# restart, then wait for the daemon socket to answer. Returns non-zero if
# the daemon does not become responsive within the timeout.
docker_restart() {
    sudo systemctl reset-failed docker.service docker.socket 2>/dev/null || true
    sudo systemctl restart docker || return 1
    for _ in $(seq 1 "$READY_TIMEOUT"); do
        if systemctl is-active --quiet docker && docker info >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

rollback() {
    warn "Rolling back daemon.json and restarting Docker."
    if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
        sudo cp "$BACKUP" "$DAEMON_JSON"
    else
        sudo rm -f "$DAEMON_JSON"   # no daemon.json existed before us
    fi
    if docker_restart; then
        warn "Rollback complete — Docker active on prior config."
    else
        die "ROLLBACK FAILED — Docker not responding. MANUAL INTERVENTION NEEDED."
    fi
}

# --- 0. Preconditions --------------------------------------------------------
command -v docker >/dev/null 2>&1 || die "docker not on PATH"
sudo -n true 2>/dev/null           || die "no passwordless sudo"

RUNNING="$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')"
[ "$RUNNING" = "0" ] || die "ABORT: $RUNNING container(s) running — refusing to restart Docker."

# Idempotency: read the on-disk config (deterministic) rather than parsing
# `docker info` text, which is populated a beat after the daemon comes up
# and so intermittently misses the pool right after a restart. Requires BOTH
# keys, so a node with the pool but not the download limit still re-applies.
if [ -f "$DAEMON_JSON" ] && \
   BASE="$POOL_BASE" MAXDL="$MAX_CONCURRENT_DOWNLOADS" python3 - "$DAEMON_JSON" <<'PY' 2>/dev/null
import json, os, sys
cfg = json.load(open(sys.argv[1]))
pools = cfg.get("default-address-pools", [])
has_pool = any(p.get("base") == os.environ["BASE"] for p in pools)
has_dl = cfg.get("max-concurrent-downloads") == int(os.environ["MAXDL"])
sys.exit(0 if (has_pool and has_dl) else 1)
PY
then
    log "daemon.json already configured (pool ${POOL_BASE} + downloads=${MAX_CONCURRENT_DOWNLOADS}) — nothing to do."
    exit 0
fi

# --- 1. Back up existing config ---------------------------------------------
if [ -f "$DAEMON_JSON" ]; then
    BACKUP="${DAEMON_JSON}.bak.$(hostname)"
    sudo cp "$DAEMON_JSON" "$BACKUP"
    log "Backed up existing daemon.json -> $BACKUP"
else
    log "No existing daemon.json (fresh)."
fi

# --- 2. Merge our keys, preserving anything already present ------------------
EXISTING="{}"
[ -f "$DAEMON_JSON" ] && EXISTING="$(sudo cat "$DAEMON_JSON")"

MERGED="$(EXISTING="$EXISTING" BASE="$POOL_BASE" SIZE="$POOL_SIZE" MAXDL="$MAX_CONCURRENT_DOWNLOADS" python3 - <<'PY'
import json, os
try:
    cfg = json.loads(os.environ["EXISTING"] or "{}")
except json.JSONDecodeError:
    cfg = {}
cfg["default-address-pools"] = [{"base": os.environ["BASE"], "size": int(os.environ["SIZE"])}]
cfg["max-concurrent-downloads"] = int(os.environ["MAXDL"])
print(json.dumps(cfg, indent=4))
PY
)" || die "failed to build merged config (python3 error)"

echo "$MERGED" | python3 -c "import json,sys; json.load(sys.stdin)" \
    || die "merged daemon.json is invalid JSON — not writing."

printf '%s\n' "$MERGED" | sudo tee "$DAEMON_JSON" >/dev/null
log "Wrote $DAEMON_JSON:"; printf '%s\n' "$MERGED"

# --- 3. Restart Docker once (rate-limit-safe, polled) ------------------------
log "Restarting Docker daemon (waiting up to ${READY_TIMEOUT}s for readiness)..."
if ! docker_restart; then
    warn "Docker did not become responsive after restart."
    rollback; die "Restart failed; rolled back."
fi

# --- 4. Health check: functional network allocation (source of truth) -------
# `docker info` populates its pool section a beat after the daemon answers,
# so parsing that text is racy. Instead we actually allocate a network and
# check its subnet falls inside our pool — that is definitive proof the pool
# loaded. Retried, because the very first post-restart allocation can race
# the daemon finishing its network-controller init.
TESTSUBNET=""
for _ in $(seq 1 "$READY_TIMEOUT"); do
    TESTNET="pool-check-$$-$_"
    if docker network create "$TESTNET" >/dev/null 2>&1; then
        SUB="$(docker network inspect "$TESTNET" 2>/dev/null | grep -i '"Subnet"' | head -1 | tr -d ' ,"')"
        docker network rm "$TESTNET" >/dev/null 2>&1 || true
        # SUB looks like: Subnet:172.20.1.0/24 — verify it's inside POOL_BASE.
        CIDR="${SUB#*:}"
        if [ -n "$CIDR" ] && BASE="$POOL_BASE" CIDR="$CIDR" python3 - <<'PY' 2>/dev/null
import ipaddress, os, sys
net  = ipaddress.ip_network(os.environ["CIDR"], strict=False)
pool = ipaddress.ip_network(os.environ["BASE"])
sys.exit(0 if net.subnet_of(pool) else 1)
PY
        then
            TESTSUBNET="$CIDR"; break
        fi
    fi
    sleep 1
done

if [ -z "$TESTSUBNET" ]; then
    warn "no network allocated from pool ${POOL_BASE} within ${READY_TIMEOUT}s."
    rollback; die "Pool not applied; rolled back."
fi

# --- 5. Success --------------------------------------------------------------
log "SUCCESS. Allocated ${TESTSUBNET} (inside ${POOL_BASE}). Node configured cleanly."
