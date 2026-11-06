#!/usr/bin/env bash
# Apply packet loss via tc netem.
# Usage: sudo ./netem-loss.sh <iface> <loss_pct>
# Example: sudo ./netem-loss.sh eth0 5
set -euo pipefail
IFACE=${1:?"Usage: $0 <iface> <loss_pct>"}
LOSS=${2:?}
tc qdisc del dev "$IFACE" root 2>/dev/null || true
tc qdisc add dev "$IFACE" root netem loss "${LOSS}%"
echo "Applied ${LOSS}% packet loss to $IFACE"
echo "Reset with: sudo tc qdisc del dev $IFACE root"
