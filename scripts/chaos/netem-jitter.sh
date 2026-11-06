#!/usr/bin/env bash
# Apply delay+jitter via tc netem.
# Usage: sudo ./netem-jitter.sh <iface> <delay_ms> <jitter_ms>
set -euo pipefail
IFACE=${1:?}; DELAY=${2:?}; JITTER=${3:?}
tc qdisc del dev "$IFACE" root 2>/dev/null || true
tc qdisc add dev "$IFACE" root netem delay "${DELAY}ms" "${JITTER}ms" distribution normal
echo "Applied ${DELAY}ms ± ${JITTER}ms delay to $IFACE"
