#!/usr/bin/env bash
# FlyTerm QUIC Performance Gate
# Measures: handshake latency, PTY latency, file throughput, loss resilience.
# Usage: AQT_HOST=server.example.com AQT_PORT=9876 ./run-bench.sh

set -euo pipefail

HOST="${AQT_HOST:?Set AQT_HOST}"
PORT="${AQT_PORT:-9876}"
REPORT="bench-results-$(date +%Y%m%dT%H%M%S).txt"

echo "=== FlyTerm QUIC Performance Gate $(date) ===" | tee "$REPORT"
echo "Host: $HOST:$PORT" | tee -a "$REPORT"
echo "" | tee -a "$REPORT"

echo "## Performance Targets" | tee -a "$REPORT"
echo "  1-RTT handshake (LAN):     < 50ms" | tee -a "$REPORT"
echo "  0-RTT resume:              < 1 RTT (PSK)" | tee -a "$REPORT"
echo "  PTY latency (LAN):         < 5ms" | tee -a "$REPORT"
echo "  PTY latency (4G 50ms RTT): < 60ms" | tee -a "$REPORT"
echo "  Throughput 4G:             >= 0.85x SCP baseline" | tee -a "$REPORT"
echo "  5% loss throughput drop:   < 30%" | tee -a "$REPORT"
echo "  8MB scrollback replay LAN: < 2s" | tee -a "$REPORT"
echo "" | tee -a "$REPORT"

echo "## Handshake latency (LAN, 10 samples)" | tee -a "$REPORT"
echo "  [Manual: run flyterm-server --once --bind 127.0.0.1]" | tee -a "$REPORT"
echo "  [Then: time 10x quinn client HELLO→HELLO_ACK roundtrips]" | tee -a "$REPORT"
echo "  Result: TBD (requires flyterm-server binary + Rust bench tool)" | tee -a "$REPORT"
echo "" | tee -a "$REPORT"

echo "## Instructions" | tee -a "$REPORT"
echo "  1. Install flyterm-server on remote: curl -fsSL URL | sh" | tee -a "$REPORT"
echo "  2. Run flyterm-server --listen 9876 on remote" | tee -a "$REPORT"
echo "  3. Install cargo bench tool: cargo install --path rust/bench/ (future)" | tee -a "$REPORT"
echo "  4. Run each scenario with chaos scripts in scripts/chaos/" | tee -a "$REPORT"
echo "  5. Fill in results above and commit as bench-results-DATE.txt" | tee -a "$REPORT"

echo "" | tee -a "$REPORT"
echo "Report template saved: $REPORT"
