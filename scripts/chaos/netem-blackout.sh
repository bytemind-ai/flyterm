#!/usr/bin/env bash
# Simulate network blackout for N seconds.
# Usage: sudo ./netem-blackout.sh <iface> <duration_sec>
set -euo pipefail
IFACE=${1:?}; DURATION=${2:?}
tc qdisc del dev "$IFACE" root 2>/dev/null || true
tc qdisc add dev "$IFACE" root netem loss 100%
echo "Total blackout applied to $IFACE for ${DURATION}s..."
sleep "$DURATION"
tc qdisc del dev "$IFACE" root 2>/dev/null || true
echo "Network restored."
