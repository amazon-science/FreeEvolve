#!/usr/bin/env bash
# Resolve a third-party checkout an environment needs, cloning it if there isn't one.
#
# Two environments' assets are large public repositories rather than something that
# can be pip-installed: harbor (benchmark adapters that live in the repo but are not
# published as modules) and Frontier-CS (a problem tree whose generated test data is
# 2.6 GB). Neither is vendored here. They are cloned at a pinned commit into a cache
# that every later run and every other run directory reuses, so setup needs nothing
# prepared by hand and the package stays small.
#
# Environments source this file and call one of:
#
#     ensure_harbor            # sets and exports HARBOR_ROOT
#     ensure_frontier_cs       # sets and exports FRONTIER_CS_ROOT
#
# Reads:
#   HARBOR_ROOT / FRONTIER_CS_ROOT   an existing checkout to use as-is. When set,
#                         nothing is cloned and nothing is checked out — it is used
#                         verbatim, and no commit is enforced.
#   HARBOR_COMMIT / FRONTIER_CS_COMMIT   the commit a fresh clone is pinned to.
#                         Defaults are the commits every result in this package was
#                         produced against.
#   FREEEVOLVE_CACHE_DIR where clones are kept. Default ~/.cache/freeevolve. Worth
#                         pointing at the same filesystem as your run directories:
#                         the Frontier-CS tree is hardlinked into a run when it can
#                         be, and copied when it cannot.
#
# A clone is shared between concurrent setups, so it is made under a lock and moved
# into place atomically: a setup either sees no checkout or a complete one, never a
# half-cloned tree.
#
# Nothing here writes into a checkout after it is made. Environments that patch what
# they read copy it into their own run directory first, so the shared tree stays
# pristine and two runs can never affect each other through it.

HARBOR_REPO="${HARBOR_REPO:-https://github.com/harbor-framework/harbor.git}"
FRONTIER_CS_REPO="${FRONTIER_CS_REPO:-https://github.com/FrontierCS/Frontier-CS.git}"
# Full 40-character shas: a fetch by abbreviated sha is not served.
HARBOR_COMMIT="${HARBOR_COMMIT:-e76f7e32f5644fb9f648cd23151aac5c67492ea0}"
FRONTIER_CS_COMMIT="${FRONTIER_CS_COMMIT:-1bccbadc6bead714d25c546cf954a37bb0791fd6}"

_freeevolve_cache() {
    echo "${FREEEVOLVE_CACHE_DIR:-$HOME/.cache/freeevolve}"
}

# _ensure_checkout <dir name> <repo url> <commit> <path that must exist in it>
#
# Prints the checkout path on stdout; everything else goes to stderr, so a caller can
# capture the path.
_ensure_checkout() {
    local name="$1" repo="$2" commit="$3" marker="$4"
    local cache dest lock tmp
    cache="$(_freeevolve_cache)"
    dest="$cache/$name"
    mkdir -p "$cache"

    if [ -e "$dest/$marker" ]; then
        echo "[$name] using cached checkout $dest ($(git -C "$dest" rev-parse --short HEAD 2>/dev/null || echo '?'))" >&2
        echo "$dest"
        return 0
    fi

    command -v git >/dev/null || { echo "[$name] git not found on PATH" >&2; return 1; }

    # One clone at a time, whichever setup gets here first. The others wait and then
    # find the finished tree above.
    lock="$cache/.$name.lock"
    (
        flock 9 || exit 1
        [ -e "$dest/$marker" ] && exit 0
        tmp="$cache/.$name.$$"
        rm -rf "$tmp"
        echo "[$name] cloning $repo at $commit into $dest" >&2
        # --filter=blob:none keeps the fetch to what the checkout below actually needs.
        git clone --quiet --filter=blob:none --no-checkout "$repo" "$tmp" >&2 || exit 1
        if ! git -C "$tmp" fetch --quiet --depth 1 origin "$commit" >&2; then
            echo "[$name] commit $commit not fetchable; falling back to the default branch" >&2
            git -C "$tmp" fetch --quiet --depth 1 origin HEAD >&2 || exit 1
        fi
        git -C "$tmp" checkout --quiet FETCH_HEAD >&2 || exit 1
        mv "$tmp" "$dest" || exit 1
    ) 9>"$lock" || { echo "[$name] clone failed" >&2; return 1; }

    [ -e "$dest/$marker" ] || {
        echo "[$name] $marker missing after cloning into $dest" >&2
        return 1
    }
    echo "[$name] cloned $dest ($(git -C "$dest" rev-parse --short HEAD 2>/dev/null || echo '?'))" >&2
    echo "$dest"
}

ensure_harbor() {
    if [ -n "${HARBOR_ROOT:-}" ]; then
        [ -d "$HARBOR_ROOT/adapters" ] || {
            echo "[harbor] HARBOR_ROOT=$HARBOR_ROOT has no adapters/ — not a harbor checkout" >&2
            return 1
        }
        export HARBOR_ROOT
        echo "[harbor] using $HARBOR_ROOT (HARBOR_ROOT was set)"
        return 0
    fi
    local root
    root="$(_ensure_checkout harbor "$HARBOR_REPO" "$HARBOR_COMMIT" adapters)" || return 1
    export HARBOR_ROOT="$root"
}

ensure_frontier_cs() {
    if [ -n "${FRONTIER_CS_ROOT:-}" ]; then
        [ -d "$FRONTIER_CS_ROOT/algorithmic/problems" ] || {
            echo "[frontier-cs] FRONTIER_CS_ROOT=$FRONTIER_CS_ROOT has no" >&2
            echo "[frontier-cs] algorithmic/problems — not a Frontier-CS checkout" >&2
            return 1
        }
        export FRONTIER_CS_ROOT
        echo "[frontier-cs] using $FRONTIER_CS_ROOT (FRONTIER_CS_ROOT was set)"
        return 0
    fi
    local root
    root="$(_ensure_checkout frontier-cs "$FRONTIER_CS_REPO" "$FRONTIER_CS_COMMIT" \
            algorithmic/problems)" || return 1
    # Upstream ships a reference solution per problem under examples/. They are
    # removed from the checkout rather than merely not copied: an agent that found
    # them would be reading the answer, and the environment's own evaluation never
    # needs them. The consequence is deliberate — upstream's `oracle` agent cannot be
    # run against this tree.
    if find "$root/algorithmic/problems" -mindepth 2 -maxdepth 2 -type d -name examples \
            -print -quit 2>/dev/null | grep -q .; then
        find "$root/algorithmic/problems" -mindepth 2 -maxdepth 2 -type d -name examples \
            -exec rm -rf {} + 2>/dev/null || true
        echo "[frontier-cs] removed the per-problem examples/ (reference solutions)"
    fi
    export FRONTIER_CS_ROOT="$root"
}
