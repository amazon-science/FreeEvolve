#!/usr/bin/env bash
set -euo pipefail

ENV_DIR="${1:-}"
INSTALL_DIR="${2:-}"

if [ -z "$ENV_DIR" ]; then
    echo "usage: validate-environment.sh <environment-directory> [fresh-install-directory]" >&2
    exit 2
fi

if [ ! -d "$ENV_DIR" ]; then
    echo "environment directory not found: $ENV_DIR" >&2
    exit 1
fi

ENV_DIR="$(cd "$ENV_DIR" && pwd)"
SETUP="$ENV_DIR/setup.sh"

if [ ! -f "$SETUP" ]; then
    echo "missing required setup.sh: $SETUP" >&2
    exit 1
fi

bash -n "$SETUP"
echo "PASS  setup.sh exists and parses"

if [ -f "$ENV_DIR/run.sh" ]; then
    bash -n "$ENV_DIR/run.sh"
    echo "PASS  source run.sh parses"
fi

if [ -z "$INSTALL_DIR" ]; then
    echo "PASS  static environment validation complete"
    exit 0
fi

if [ -e "$INSTALL_DIR" ] && [ -n "$(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    echo "install directory must be absent or empty: $INSTALL_DIR" >&2
    exit 1
fi

mkdir -p "$INSTALL_DIR"
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)"
bash "$SETUP" "$INSTALL_DIR"

for required in ENVIRONMENT.md run.sh .target; do
    if [ ! -e "$INSTALL_DIR/$required" ]; then
        echo "installed environment is missing $required" >&2
        exit 1
    fi
done

bash -n "$INSTALL_DIR/run.sh"
if [ ! -x "$INSTALL_DIR/run.sh" ]; then
    echo "installed run.sh is not executable" >&2
    exit 1
fi

target_rel="$(tr -d '[:space:]' < "$INSTALL_DIR/.target")"
if [ -z "$target_rel" ]; then
    echo "installed .target is empty" >&2
    exit 1
fi
if [[ "$target_rel" = /* ]] || [[ "/$target_rel/" = *"/../"* ]]; then
    echo ".target must name a relative path inside the run directory: $target_rel" >&2
    exit 1
fi
if [ ! -e "$INSTALL_DIR/$target_rel" ]; then
    echo ".target names a missing edit surface: $target_rel" >&2
    exit 1
fi

echo "PASS  installed environment contract is complete"
echo "      run directory: $INSTALL_DIR"
echo "      edit surface:  $target_rel"
