#!/usr/bin/env bash
# Kept as the name the harbor-backed environments source. The implementation, and the
# same treatment for the other large third-party checkout, is in ensure_checkout.sh.
# shellcheck source=ensure_checkout.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ensure_checkout.sh"
