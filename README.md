# aws-optimize

A smart script for checking and tuning the network of **Xray / V2Ray / 3x-ui / Marzban** servers on **AWS (EC2 and Lightsail)** and other Linux VPS.

It fixes MTU, MSS clamp, packet loss and latency problems with one command, and **does not restart Xray**, so users stay connected.

## Run with one command

```bash
curl -fsSL https://raw.githubusercontent.com/javad48/aws-optimize/main/aws-optimize.sh | sudo bash
```

This opens a menu:

```
1) Check server (read-only)
2) Apply optimizations
3) Benchmark retransmit rate (60s)
4) Rollback last apply
```

Direct commands without the menu:

```bash
# Read-only report
curl -fsSL https://raw.githubusercontent.com/javad48/aws-optimize/main/aws-optimize.sh | sudo bash -s -- check

# Apply the optimizations without asking for confirmation
curl -fsSL https://raw.githubusercontent.com/javad48/aws-optimize/main/aws-optimize.sh | sudo bash -s -- apply -y

# Measure the retransmit rate over 2 minutes
curl -fsSL https://raw.githubusercontent.com/javad48/aws-optimize/main/aws-optimize.sh | sudo bash -s -- bench --seconds 120

# Undo the changes
curl -fsSL https://raw.githubusercontent.com/javad48/aws-optimize/main/aws-optimize.sh | sudo bash -s -- rollback -y
```

## What makes it "smart"

| Detects | What it does |
|---|---|
| **Path MTU** to the internet (binary search with the DF bit) | If the interface MTU is too large (AWS defaults to 9001), sets it to the real value |
| AWS **DHCP pushing MTU 9001** | Sets `use-mtu: false` in netplan so the MTU doesn't revert on lease renewal |
| **RAM** size | Sizes TCP buffers to RAM (16/32/64 MB) |
| No **swap** on a server with little RAM (<2GB) | Creates a 1–2 GB swap file so Xray isn't killed by the OOM killer |
| Kernel **BBR** support | Enables BBR + `fq`, or falls back to cubic |
| Conflicting settings in `/etc/sysctl.conf` | Disables them so they don't override the new values |
| Panel (**3x-ui**, Marzban, Hiddify) and Xray inbound ports | Reports connection count, unique IPs, top clients, and inbounds without TLS |
| Low **open files** limit on the Xray service | Adds `LimitNOFILE` |

### Changes `apply` makes
- `tcp_mtu_probing=1` — prevents connections stalling when the client's ISP blocks ICMP
- **MSS clamp** (`--clamp-mss-to-pmtu`) with iptables/ip6tables
- `BBR` + `fq`, `tcp_slow_start_after_idle=0`, `tcp_notsent_lowat`, `tcp_fastopen=3`
- Larger TCP/UDP buffers, backlog, and keepalive settings
- The `aws-optimize.service` systemd service re-applies MTU, qdisc and MSS clamp after every reboot

**Backups:** before any change, a backup is saved under `/var/backups/aws-optimize/<time>`, and `rollback` restores all of it.

## Options

| Option | Description |
|---|---|
| `-y`, `--yes` | Don't ask for confirmation |
| `--mtu N` | Set the MTU manually |
| `--no-mtu` | Don't touch the MTU |
| `--swap` / `--no-swap` | Always create swap / never create swap |
| `--seconds N` | Duration for `bench` |

## Sample result (AWS Lightsail, 3x-ui, VLESS+WS, ~100 users)

| Metric | Before | After |
|---|---|---|
| Retransmit | 1.75% | 0.21% |
| TCP Timeout | 0.70% | 0.07% |

## Requirements
- Ubuntu 20.04+ / Debian 11+ (or any Linux with systemd and iproute2)
- root access

## License
MIT
