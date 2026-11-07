# FlyTerm QUIC Troubleshooting

## Connection issues

| Symptom | Cause | Fix |
|---|---|---|
| "flyterm-server not installed" | Binary not on remote PATH | `curl -fsSL URL \| sh` |
| QUIC connect timed out | UDP port blocked by server firewall / security group, or the network blocks UDP | Allow UDP 61001-61999 (or the server's configured **UDP ports**); otherwise use the SSH transport |
| "Public key mismatch" | Server regenerated keys | For once mode: reconnect (new key each session). For daemon: check server health |
| "Session token expired" | Offline > 24h | Auto-creates new session on next connect |

## Performance

If throughput is poor on QUIC:
- Check carrier UDP QoS with: `sudo ./scripts/chaos/netem-loss.sh eth0 5` locally
- Compare with SCP: `time scp user@server:/tmp/100MB /dev/null`
- If QUIC consistently slower, switch to SSH/Mosh for that network

## File transfers

**Transfer not starting**
→ Requires QUIC connection. Look for 📎 icon in terminal AppBar.

**Transfer fails mid-way**
→ On next connect, a resume prompt appears. Select "Resume" to continue.

**Hash mismatch error**
→ File was modified during upload. Delete and re-upload.

## Debug logs

Enable verbose logging on server:
```bash
FLYTERM_SERVER_LOG=debug flyterm-server --once --bind 0.0.0.0
```

On app: Enable developer mode in Settings to see DebugOverlay with QUIC metrics (RTT, inFlight, cwnd).
