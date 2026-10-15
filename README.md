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
5) Client connection doctor status
```

Direct commands without the menu:

```bash
# Read-only report
curl -fsSL https://raw.githubusercontent.com/javad48/aws-optimize/main/aws-optimize.sh | sudo bash -s -- check

# Apply the optimizations without asking for confirmation
curl -fsSL https://raw.githubusercontent.com/javad48/aws-optimize/main/aws-optimize.sh | sudo bash -s -- apply -y

# Measure the retransmit rate over 2 minutes
curl -fsSL https://raw.githubusercontent.com/javad48/aws-optimize/main/aws-optimize.sh | sudo bash -s -- bench --seconds 120

# What the client connection doctor did
curl -fsSL https://raw.githubusercontent.com/javad48/aws-optimize/main/aws-optimize.sh | sudo bash -s -- doctor

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
| Client connections **stuck** or **idle** (phone screen off, app in the background, Wi-Fi ⇄ mobile data) | Resets them so the app opens a fresh connection at once (see below) |

### Changes `apply` makes
- `tcp_mtu_probing=1` — prevents connections stalling when the client's ISP blocks ICMP
- **MSS clamp** (`--clamp-mss-to-pmtu`) with iptables/ip6tables
- `BBR` + `fq`, `tcp_slow_start_after_idle=0`, `tcp_notsent_lowat`, `tcp_fastopen=3`
- Larger TCP/UDP buffers, backlog, and keepalive settings
- The `aws-optimize.service` systemd service re-applies MTU, qdisc and MSS clamp after every reboot

### Client connection doctor
Phones leave connections behind: the screen goes off, the app goes to the background, the phone hops between Wi-Fi and mobile data. The connection stays open on the server but nothing moves, and the app keeps using it: the user sees a "stuck" VPN until timeouts run out, minutes later. `apply` installs `aws-optimize-doctor.service`, a small daemon (Python 3, standard library only) that looks at the proxy's client connections every 2 seconds:

| Detects | What it does |
|---|---|
| A connection with no ACK for **10 s**, in RTO backoff, while the same client shows life (data on another connection, a new connection, or SYNs that go unanswered — it is trying to connect and failing) | Resets it (RST): the app dials a fresh connection at once |
| A connection with **no data either way for 5 minutes** (`--idle N`, `0` = off) | Resets it |
| Every client connection | Linear retransmits for thin streams (`TCP_THIN_LINEAR_TIMEOUTS`: the first six stay ~one RTO apart instead of doubling to 12.8 s), keepalive 45 s and `TCP_USER_TIMEOUT` 90 s — so a connection recovers as soon as the phone's network is back, and a phone that is gone is noticed in ~1.5 minutes instead of ~15 |

Nothing is restarted: the options are set on the proxy's own sockets through `pidfd_getfd(2)` (kernel 5.6+, Python 3.9+; older systems still get the resets), resets are `ss -K`. The proxy and its ports are found automatically (Xray, V2Ray, sing-box; any panel). A connection with no sign of its client is left alone — the phone may come back. `check` shows how many connections are stuck or idle right now; `--doctor-shadow` only counts what would be reset; `--no-doctor` skips it.

**Backups:** before any change, a backup is saved under `/var/backups/aws-optimize/<time>`, and `rollback` restores all of it.

## Options

| Option | Description |
|---|---|
| `-y`, `--yes` | Don't ask for confirmation |
| `--mtu N` | Set the MTU manually |
| `--no-mtu` | Don't touch the MTU |
| `--swap` / `--no-swap` | Always create swap / never create swap |
| `--seconds N` | Duration for `bench` |
| `--no-doctor` | Don't install the client connection doctor |
| `--doctor-shadow` | The doctor only counts what it would reset |
| `--idle N` | Doctor: reset a connection idle N seconds (default 300, `0` = off) |

## Sample result (AWS Lightsail, 3x-ui, VLESS+WS, ~100 users)

| Metric | Before | After |
|---|---|---|
| Retransmit | 1.75% | 0.21% |
| TCP Timeout | 0.70% | 0.07% |

## Requirements
- Ubuntu 20.04+ / Debian 11+ (or any Linux with systemd and iproute2)
- Python 3 for the client connection doctor (3.9+ and kernel 5.6+ for its socket tuning)
- root access

## License
MIT
