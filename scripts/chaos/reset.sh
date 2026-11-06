#!/usr/bin/env bash
# Reset all tc rules on an interface.
# Usage: sudo ./reset.sh <iface>
set -euo pipefail
IFACE=${1:?}
tc qdisc del dev "$IFACE" root 2>/dev/null || echo "No rules to remove."
echo "tc rules cleared on $IFACE"
