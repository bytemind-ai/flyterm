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

Step 1 is optional: when you first connect over QUIC, FlyTerm offers to
install flyterm-server for you over SSH (no root needed).

## Step 2: Open the UDP ports

FlyTerm runs flyterm-server as a per-user daemon (started over SSH, survives
disconnects) listening on a UDP port in **61001-61999** by default. Allow that
range in the server's firewall and, on a cloud host, its security group:

```bash
sudo ufw allow 61001:61999/udp
```

To use other ports, set **UDP ports** in the server's QUIC settings: a single
port (`60000`) or a range (`60000-60010`), between 1024 and 65535. Several users
on the same host each get their own daemon, so give a range rather than one
port if the host is shared.

If a daemon is already running on a port outside the new setting, FlyTerm asks
before restarting it: a restart ends every AQT session on that host, including
ones on other devices.

## Step 3: Configure in FlyTerm

1. Edit server → transport **QUIC** (keep **Daemon mode** on)
2. Optionally set **UDP ports** (see Step 2)
3. Save + connect

The status indicator shows `QUIC` when active.

## Troubleshooting

**"Server does not have flyterm-server installed"**
→ Run the install script above on the remote host.

**"QUIC connect timed out … Allow UDP 61001-61999 …"**
→ The UDP port is not reachable: open the range from Step 2 in the server
firewall / security group. If your current network blocks UDP entirely, switch
the server to the SSH transport for now.

**File transfer icon not visible**
→ QUIC connection is required. Icon only appears on QUIC sessions.

**Session lost during long disconnect**
→ The daemon keeps sessions for 7 days; reconnect within that window to
restore the screen and scrollback.
