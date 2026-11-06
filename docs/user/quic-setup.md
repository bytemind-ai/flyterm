# FlyTerm QUIC Setup Guide

QUIC transport is **experimental** in v3.1. It provides:
- Resilient connections in lossy networks (BBR congestion control)
- 8 MB scrollback buffer that survives disconnects
- Built-in file transfer (📎 icon)
- Automatic WiFi ↔ 4G handover

## Step 1: Install flyterm-server on remote host

```bash
curl -fsSL https://raw.githubusercontent.com/bytemind-ai/flyterm/main/rust/flyterm-server/install.sh | bash
export PATH="$HOME/.flyterm-server/bin:$PATH"
flyterm-server --version
```

Supports: Linux x86_64 and Linux aarch64.

## Step 2: Choose server mode

### Mode A: SSH bootstrap (recommended)

No service needed. FlyTerm spawns a temporary server each connection.

Verify:
```bash
ssh user@myserver "flyterm-server --once --bind 127.0.0.1"
# Should print AQT_VER=1 AQT_PORT=... AQT_PUBKEY=... AQT_TOKEN=...
```

### Mode B: Always-on daemon

For persistent scrollback + faster reconnect:
```bash
systemctl --user enable --now flyterm-server
# Opens UDP port 9876. Firewall: sudo ufw allow 9876/udp
```

## Step 3: Configure in FlyTerm

1. Edit server → **Connection strategy**
2. Choose `QUIC → SSH fallback` (tries QUIC, falls back to SSH if blocked)
3. Save + connect

The status indicator shows `QUIC` when active.

## Troubleshooting

**"Server does not have flyterm-server installed"**
→ Run the install script above on the remote host.

**"QUIC handshake timeout — falling back to SSH"**
→ UDP may be blocked. Some carriers/firewalls block UDP. SSH fallback is automatic.

**File transfer icon not visible**
→ QUIC connection is required. Icon only appears on QUIC sessions.

**Session lost during long disconnect**
→ Sessions persist 24 hours. Reconnect within 24h to replay scrollback.
