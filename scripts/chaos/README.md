# FlyTerm QUIC Chaos Test Harness

Linux `tc netem` scripts for network impairment testing.

Requires: `sudo` + `iproute2`.

## Scenarios

| Scenario | Script |
|---|---|
| 5% packet loss | `sudo ./netem-loss.sh eth0 5` |
| 30% packet loss | `sudo ./netem-loss.sh eth0 30` |
| 200ms RTT | `sudo ./netem-jitter.sh eth0 100 100` |
| 5s blackout | `sudo ./netem-blackout.sh eth0 5` |
| 30s blackout | `sudo ./netem-blackout.sh eth0 30` |
| 5min blackout | `sudo ./netem-blackout.sh eth0 300` |

## Reset

```bash
sudo ./reset.sh eth0
# or
sudo tc qdisc del dev eth0 root
```
