#!/usr/bin/env bash
# aws-optimize - smart network tuning for Xray / V2Ray / 3x-ui / Marzban servers
# on AWS (EC2, Lightsail) and other Linux VPS.
#
#   curl -fsSL https://raw.githubusercontent.com/javad48/aws-optimize/main/aws-optimize.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/javad48/aws-optimize/main/aws-optimize.sh | sudo bash -s -- apply -y
#
# Commands: check | apply | bench | rollback   (no command = interactive menu)

VERSION="1.0.0"
BACKUP_ROOT=/var/backups/aws-optimize
SYSCTL_FILE=/etc/sysctl.d/99-aws-optimize.conf
NETPLAN_FILE=/etc/netplan/99-aws-optimize.yaml
BOOT_SCRIPT=/usr/local/sbin/aws-optimize-boot
UNIT_NAME=aws-optimize.service
UNIT_FILE=/etc/systemd/system/$UNIT_NAME
SWAP_FILE=/swapfile-aws-optimize
PING_TARGET=1.1.1.1

ASSUME_YES=0
DO_SWAP=auto
DO_MTU=1
FORCE_MTU=""
BENCH_SECS=60
WARNS=0

if [ -t 1 ]; then R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[36m'; W=$'\e[1m'; N=$'\e[0m'; else R= G= Y= B= W= N=; fi

msg()  { printf '%s\n' "$*"; }
info() { printf '%s[*]%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s[!]%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%s[x]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
hr()   { printf '\n%s== %s ==%s\n' "$W" "$*" "$N"; }
sget() { sysctl -n "$1" 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/ $//'; }
have() { command -v "$1" >/dev/null 2>&1; }

row() { # label value state(ok|warn|info)
  local s
  case $3 in
    ok)   s="${G} OK ${N}" ;;
    warn) s="${Y}WARN${N}"; WARNS=$((WARNS + 1)) ;;
    *)    s="${B}INFO${N}" ;;
  esac
  printf '  %-26s %-34s [%s]\n' "$1" "$2" "$s"
}

usage() {
  cat <<EOF
aws-optimize v$VERSION - network tuning for Xray/V2Ray proxy servers

Usage: aws-optimize.sh [command] [options]

Commands:
  check       Read-only report: system, Xray clients, MTU, TCP health (default without TTY)
  apply       Apply tuning (backup first, no proxy restart)
  bench       Measure retransmit / timeout rate over N seconds
  rollback    Undo the last apply
  (none)      Interactive menu

Options:
  -y, --yes         Do not ask for confirmation
  --mtu N           Force interface MTU (default: auto, from path MTU)
  --no-mtu          Do not touch interface MTU
  --swap            Always create swap if none exists
  --no-swap         Never create swap
  --seconds N       Duration for bench (default 60)
  -h, --help        Show this help
EOF
}

tty_ok() { { : </dev/tty; } 2>/dev/null; }

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  tty_ok || die "No terminal for confirmation. Re-run with -y"
  local a
  printf '%s [y/N] ' "$1"
  read -r a </dev/tty
  case $a in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------- detection

detect() {
  IFACE=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  [ -n "$IFACE" ] || die "Cannot find default network interface"
  CUR_MTU=$(cat "/sys/class/net/$IFACE/mtu")
  CUR_QDISC=$(tc qdisc show dev "$IFACE" 2>/dev/null | awk 'NR==1{print $2}')
  DRIVER=$(basename "$(readlink -f "/sys/class/net/$IFACE/device/driver" 2>/dev/null)" 2>/dev/null)
  RAM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  SWAP_MB=$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo)
  CPUS=$(nproc)
  KERNEL=$(uname -r)
  OS=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")

  CLOUD="unknown"
  if grep -qi amazon /sys/class/dmi/id/sys_vendor 2>/dev/null || [ "$DRIVER" = ena ]; then
    CLOUD="AWS"
  elif grep -qiE 'hetzner|digitalocean|google|microsoft|ovh|vultr|linode' /sys/class/dmi/id/sys_vendor 2>/dev/null; then
    CLOUD=$(cat /sys/class/dmi/id/sys_vendor)
  fi

  PANEL="none"
  if pgrep -x x-ui >/dev/null; then PANEL="3x-ui / x-ui"
  elif [ -d /opt/marzban ] || (have docker && docker ps --format '{{.Names}}' 2>/dev/null | grep -qi marzban); then PANEL="Marzban"
  elif [ -d /opt/hiddify-manager ]; then PANEL="Hiddify"
  fi
  PROXY_PID=$(pgrep -f 'xray|v2ray|sing-box' | head -1)
  PROXY_NAME=$( [ -n "$PROXY_PID" ] && ps -o comm= -p "$PROXY_PID")

  BBR_OK=0
  modprobe tcp_bbr 2>/dev/null
  sget net.ipv4.tcp_available_congestion_control | grep -qw bbr && BBR_OK=1
}

# returns largest working MTU towards $1 (<=1500), 0 if ICMP is blocked
path_mtu() {
  local t=$1 lo=1280 hi=1500 mid
  ping -c1 -W2 "$t" >/dev/null 2>&1 || { echo 0; return; }
  if ping -c1 -W2 -M do -s $((hi - 28)) "$t" >/dev/null 2>&1; then echo "$hi"; return; fi
  while [ $((hi - lo)) -gt 1 ]; do
    mid=$(((lo + hi) / 2))
    if ping -c1 -W2 -M do -s $((mid - 28)) "$t" >/dev/null 2>&1; then lo=$mid; else hi=$mid; fi
  done
  echo "$lo"
}

tcp_counters() { # OutSegs RetransSegs
  awk '$1=="Tcp:"{ if(!h){for(i=1;i<=NF;i++)x[$i]=i; h=1} else print $x["OutSegs"], $x["RetransSegs"] }' /proc/net/snmp
}
tcp_timeouts() {
  awk '$1=="TcpExt:"{ if(!h){for(i=1;i<=NF;i++)x[$i]=i; h=1} else print $x["TCPTimeouts"] }' /proc/net/netstat
}
pct() { awk -v a="$1" -v b="$2" 'BEGIN{ if(b>0) printf "%.2f", a*100/b; else print "0.00" }'; }
gt()  { awk -v a="$1" -v b="$2" 'BEGIN{ exit !(a>b) }'; }

mss_clamp_present() { iptables -t mangle -S 2>/dev/null | grep -q TCPMSS; }

proxy_ports() {
  ss -Htlpn 2>/dev/null | grep -E '"(xray[^"]*|v2ray[^"]*|sing-box|hysteria[^"]*)"' \
    | awk '{print $4}' | grep -vE '^(127\.|\[::1\]|\[::ffff:127\.)' | awk -F: '{print $NF}' | sort -un
}

# ---------------------------------------------------------------- reports

report_clients() {
  hr "Proxy clients"
  row "Panel" "$PANEL" info
  row "Proxy process" "${PROXY_NAME:-not running}" "$( [ -n "$PROXY_PID" ] && echo ok || echo warn)"
  [ -n "$PROXY_PID" ] || return

  local ports p n u all=""
  ports=$(proxy_ports)
  for p in $ports; do
    n=$(ss -Htn state established "( sport = :$p )" | wc -l)
    u=$(ss -Htn state established "( sport = :$p )" | awk '{print $4}' | sed 's/:[0-9]*$//' | sort -u | wc -l)
    row "Inbound port $p" "$n conns / $u unique IPs" info
    all="$all $(ss -Htn state established "( sport = :$p )" | awk '{print $4}' | sed 's/:[0-9]*$//')"
  done
  if [ -n "${all// /}" ]; then
    msg "  Top client IPs:"
    printf '%s\n' $all | sed 's/^\[::ffff://; s/\]$//' | sort | uniq -c | sort -rn | head -10 | awk '{printf "    %6d  %s\n", $1, $2}'
  fi

  local lim
  lim=$(awk '/Max open files/{print $4}' "/proc/$PROXY_PID/limits" 2>/dev/null)
  row "Proxy open-files limit" "$lim" "$( [ "${lim:-0}" -ge 65535 ] 2>/dev/null && echo ok || echo warn)"

  if [ -f /etc/x-ui/x-ui.db ] && have python3; then
    python3 - /etc/x-ui/x-ui.db <<'PY' 2>/dev/null
import sqlite3, json, sys, time
c = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
for iid, remark, port, proto, enable, up, down, st, ss in c.execute(
        "select id,remark,port,protocol,enable,up,down,settings,stream_settings from inbounds").fetchall():
    s = json.loads(st or "{}"); t = json.loads(ss or "{}")
    cl = s.get("clients", [])
    try:
        on = c.execute("select count(*) from client_traffics where inbound_id=? and enable=1", (iid,)).fetchone()[0]
    except Exception:
        on = sum(1 for x in cl if x.get("enable", True))
    print("  x-ui inbound: %-12s port=%-5s %s/%s/%s clients=%d (enabled %d) traffic=%.1fGB%s" % (
        remark, port, proto, t.get("network"), t.get("security"), len(cl), on,
        (up + down) / 1e9, "" if enable else " [DISABLED]"))
    if t.get("security") in (None, "none"):
        print("    note: no TLS/Reality on this inbound - traffic is easy to fingerprint")
try:
    now = int(time.time() * 1000)
    n = c.execute("select count(*) from client_traffics where last_online > ?", (now - 600000,)).fetchone()[0]
    print("  x-ui clients online (last 10 min): %d" % n)
except Exception:
    pass
PY
  fi
}

report_network() {
  hr "System"
  row "OS / kernel" "$OS / $KERNEL" info
  row "Cloud / NIC driver" "$CLOUD / ${DRIVER:-?}" info
  row "CPU / RAM" "$CPUS vCPU / ${RAM_MB} MB" info
  if [ "$SWAP_MB" -eq 0 ] && [ "$RAM_MB" -lt 2048 ]; then
    row "Swap" "none (low RAM)" warn
  else
    row "Swap" "${SWAP_MB} MB" ok
  fi

  hr "Network ($IFACE)"
  info "Probing path MTU to $PING_TARGET ..."
  PMTU=$(path_mtu "$PING_TARGET")
  if [ "$PMTU" = 0 ]; then
    row "Path MTU" "unknown (ICMP blocked)" info
  else
    row "Path MTU" "$PMTU" info
  fi
  local eff=${PMTU:-1500}; [ "$eff" = 0 ] && eff=1500
  row "Interface MTU" "$CUR_MTU" "$( [ "$CUR_MTU" -gt "$eff" ] && echo warn || echo ok)"
  row "Qdisc" "${CUR_QDISC:-?}" "$( [ "$CUR_QDISC" = fq ] && echo ok || echo warn)"
  row "Congestion control" "$(sget net.ipv4.tcp_congestion_control)" "$( [ "$(sget net.ipv4.tcp_congestion_control)" = bbr ] && echo ok || echo warn)"
  row "tcp_mtu_probing" "$(sget net.ipv4.tcp_mtu_probing)" "$( [ "$(sget net.ipv4.tcp_mtu_probing)" -ge 1 ] && echo ok || echo warn)"
  row "tcp_slow_start_after_idle" "$(sget net.ipv4.tcp_slow_start_after_idle)" "$( [ "$(sget net.ipv4.tcp_slow_start_after_idle)" = 0 ] && echo ok || echo warn)"
  row "rmem_max / wmem_max" "$(sget net.core.rmem_max) / $(sget net.core.wmem_max)" "$( [ "$(sget net.core.rmem_max)" -ge 4194304 ] && echo ok || echo warn)"
  row "MSS clamp" "$(mss_clamp_present && echo present || echo missing)" "$(mss_clamp_present && echo ok || echo warn)"

  if [ -d /etc/netplan ] && [ -d /run/systemd/network ]; then
    if grep -qs 'UseMTU=true' /run/systemd/network/*"$IFACE"*.network; then
      row "DHCP may override MTU" "yes (UseMTU=true)" "$( [ "$CUR_MTU" -gt 1500 ] || grep -qs 'MTUBytes=' /run/systemd/network/*"$IFACE"*.network && echo warn || echo info)"
    fi
  fi

  hr "TCP health (since boot)"
  local out re to
  read -r out re < <(tcp_counters); to=$(tcp_timeouts)
  local rp tp
  rp=$(pct "$re" "$out"); tp=$(pct "$to" "$out")
  # cumulative since boot (includes history before tuning) -> informational; use bench for current rate
  row "Retransmitted segments" "$rp %$(gt "$rp" 1 && echo ' (high, run bench)')" info
  row "TCP timeouts" "$tp %$(gt "$tp" 0.2 && echo ' (high, run bench)')" info
  local rxd
  rxd=$(ip -s link show "$IFACE" | awk '/RX:/{getline; print $4; exit}')
  row "NIC RX dropped" "${rxd:-0}" info

  hr "Latency / loss to $PING_TARGET"
  local p loss avg
  p=$(ping -c 20 -i 0.2 -W 2 -q "$PING_TARGET" 2>/dev/null)
  loss=$(printf '%s' "$p" | grep -oE '[0-9.]+% packet loss' | cut -d% -f1)
  avg=$(printf '%s' "$p" | awk -F/ '/rtt|round-trip/{print $5}')
  row "Packet loss" "${loss:-?} %" "$(gt "${loss:-0}" 0 && echo warn || echo ok)"
  row "Avg RTT" "${avg:-?} ms" info
}

cmd_check() {
  detect
  report_network
  report_clients
  hr "Summary"
  if [ "$WARNS" -gt 0 ]; then
    warn "$WARNS item(s) can be improved. Run: apply"
  else
    ok "Server looks well tuned"
  fi
}

cmd_bench() {
  local s=$BENCH_SECS o1 r1 t1 o2 r2 t2 i
  info "Measuring TCP health for ${s}s (live traffic) ..."
  read -r o1 r1 < <(tcp_counters); t1=$(tcp_timeouts)
  for ((i = s; i > 0; i--)); do printf '\r  %3ds left ' "$i"; sleep 1; done; printf '\r              \r'
  read -r o2 r2 < <(tcp_counters); t2=$(tcp_timeouts)
  local out=$((o2 - o1)) re=$((r2 - r1)) to=$((t2 - t1)) rp tp
  rp=$(pct "$re" "$out"); tp=$(pct "$to" "$out")
  printf '  segments sent: %s   retransmitted: %s (%s%%)   timeouts: %s (%s%%)\n' "$out" "$re" "$rp" "$to" "$tp"
  if [ "$out" -lt 1000 ]; then warn "Too little traffic for a reliable result"
  elif gt 0.5 "$rp"; then ok "Excellent (retransmit < 0.5%)"
  elif gt 1.5 "$rp"; then ok "Good (retransmit < 1.5%)"
  else warn "Poor - high loss on client paths"
  fi
}

# ---------------------------------------------------------------- apply

netplan_id() { # netplan ethernets key that manages $IFACE
  have python3 || { echo "$IFACE"; return; }
  python3 - "$IFACE" <<'PY' 2>/dev/null || echo "$IFACE"
import sys, glob
import yaml
iface = sys.argv[1]
for f in sorted(glob.glob("/etc/netplan/*.yaml")):
    eth = ((yaml.safe_load(open(f)) or {}).get("network") or {}).get("ethernets") or {}
    for k, v in eth.items():
        if k == iface or (v or {}).get("set-name") == iface:
            print(k); sys.exit(0)
print(iface)
PY
}

write_boot_script() {
  local mtu=$1
  cat > "$BOOT_SCRIPT" <<EOF
#!/bin/sh
# generated by aws-optimize - re-applies runtime tuning at boot
IFACE=\$(ip route show default | awk '{for(i=1;i<=NF;i++) if(\$i=="dev"){print \$(i+1); exit}}')
[ -n "\$IFACE" ] || exit 0
MTU="$mtu"
[ -n "\$MTU" ] && ip link set dev "\$IFACE" mtu "\$MTU"
tc qdisc replace dev "\$IFACE" root fq 2>/dev/null
for ipt in iptables ip6tables; do
  command -v \$ipt >/dev/null 2>&1 || continue
  for chain in POSTROUTING FORWARD; do
    \$ipt -t mangle -C \$chain -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \\
      || \$ipt -t mangle -A \$chain -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  done
done
exit 0
EOF
  chmod 755 "$BOOT_SCRIPT"
  cat > "$UNIT_FILE" <<EOF
[Unit]
Description=aws-optimize network tuning (MTU, fq, MSS clamp)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$BOOT_SCRIPT

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$UNIT_NAME" >/dev/null 2>&1
  systemctl restart "$UNIT_NAME"
}

cmd_apply() {
  detect
  hr "Plan"
  PMTU=$(path_mtu "$PING_TARGET"); [ "$PMTU" = 0 ] && PMTU=1500
  local target_mtu=""
  if [ "$DO_MTU" = 1 ]; then
    if [ -n "$FORCE_MTU" ]; then target_mtu=$FORCE_MTU
    elif [ "$CUR_MTU" -gt "$PMTU" ]; then target_mtu=$PMTU
    fi
  fi
  local buf
  if [ "$RAM_MB" -le 1024 ]; then buf=16777216
  elif [ "$RAM_MB" -le 4096 ]; then buf=33554432
  else buf=67108864
  fi
  local cc=cubic; [ "$BBR_OK" = 1 ] && cc=bbr
  local make_swap=0
  if [ "$SWAP_MB" -eq 0 ]; then
    { [ "$DO_SWAP" = yes ] || { [ "$DO_SWAP" = auto ] && [ "$RAM_MB" -lt 2048 ]; }; } && make_swap=1
  fi
  local swap_mb=1024; [ "$RAM_MB" -ge 1024 ] && swap_mb=2048

  msg "  interface        : $IFACE (MTU $CUR_MTU, qdisc ${CUR_QDISC:-?})"
  msg "  MTU              : ${target_mtu:+$CUR_MTU -> $target_mtu}${target_mtu:-unchanged}"
  msg "  congestion / qdisc: $cc / fq"
  msg "  TCP buffers max  : $((buf / 1048576)) MB (RAM ${RAM_MB} MB)"
  msg "  MTU probing      : on,  MSS clamp: on (persistent via systemd)"
  msg "  swap             : $( [ $make_swap = 1 ] && echo "create ${swap_mb} MB" || echo unchanged)"
  msg "  proxy restart    : no"
  confirm "Apply these changes?" || die "Aborted"

  # ---- backup
  local TS BK
  TS=$(date +%Y%m%d-%H%M%S); BK="$BACKUP_ROOT/$TS"
  mkdir -p "$BK"
  cp -a /etc/sysctl.conf "$BK/" 2>/dev/null
  cp -a /etc/sysctl.d "$BK/sysctl.d"
  [ -d /etc/netplan ] && cp -a /etc/netplan "$BK/netplan"
  have iptables-save && iptables-save > "$BK/iptables.rules" 2>/dev/null
  {
    echo "IFACE=$IFACE"; echo "ORIG_MTU=$CUR_MTU"; echo "SWAP_CREATED=$make_swap"
  } > "$BK/state"
  : > "$BK/limits.list"
  echo "$BK" > "$BACKUP_ROOT/last"
  ok "Backup: $BK"

  # ---- swap
  local have_swap=0; [ "$SWAP_MB" -gt 0 ] && have_swap=1
  if [ $make_swap = 1 ]; then
    local free_mb
    free_mb=$(df -Pm / | awk 'NR==2{print $4}')
    if [ "$free_mb" -gt $((swap_mb + 1024)) ]; then
      { fallocate -l "${swap_mb}M" "$SWAP_FILE" 2>/dev/null || dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$swap_mb" status=none; } \
        && chmod 600 "$SWAP_FILE" && mkswap "$SWAP_FILE" >/dev/null && swapon "$SWAP_FILE" \
        && { grep -q "$SWAP_FILE" /etc/fstab || echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab; } \
        && { have_swap=1; ok "Swap ${swap_mb} MB created"; }
    else
      warn "Not enough disk space for swap, skipped"; sed -i 's/^SWAP_CREATED=1/SWAP_CREATED=0/' "$BK/state"
    fi
  fi

  # ---- sysctl
  local SYS=(
    "net.core.default_qdisc = fq"
    "net.ipv4.tcp_congestion_control = $cc"
    "net.ipv4.tcp_mtu_probing = 1"
    "net.ipv4.tcp_base_mss = 1024"
    "net.ipv4.tcp_fastopen = 3"
    "net.ipv4.tcp_slow_start_after_idle = 0"
    "net.ipv4.tcp_notsent_lowat = 16384"
    "net.core.rmem_max = $buf"
    "net.core.wmem_max = $buf"
    "net.ipv4.tcp_rmem = 4096 131072 $buf"
    "net.ipv4.tcp_wmem = 4096 65536 $buf"
    "net.core.netdev_max_backlog = 16384"
    "net.core.somaxconn = 8192"
    "net.ipv4.tcp_max_syn_backlog = 8192"
    "net.ipv4.tcp_fin_timeout = 15"
    "net.ipv4.tcp_keepalive_time = 300"
    "net.ipv4.tcp_keepalive_intvl = 30"
    "net.ipv4.tcp_keepalive_probes = 5"
  )
  [ $have_swap = 1 ] && SYS+=("vm.swappiness = 10")
  if [ -f /proc/sys/net/netfilter/nf_conntrack_max ] && [ "$(sget net.netfilter.nf_conntrack_max)" -lt 262144 ]; then
    SYS+=("net.netfilter.nf_conntrack_max = 262144")
  fi

  local kv k f
  : > "$BK/sysctl.snapshot"
  { echo "# generated by aws-optimize v$VERSION on $TS"; } > "$SYSCTL_FILE"
  for kv in "${SYS[@]}"; do
    k=${kv%% =*}
    echo "$k = $(sget "$k")" >> "$BK/sysctl.snapshot"
    echo "$kv" >> "$SYSCTL_FILE"
    # disable the same key in other files, so ours is not overridden (/etc/sysctl.conf loads last)
    for f in /etc/sysctl.conf /etc/sysctl.d/*.conf; do
      [ -f "$f" ] && [ ! -L "$f" ] && [ "$f" != "$SYSCTL_FILE" ] || continue
      if grep -qE "^[[:space:]]*${k//./\\.}[[:space:]]*=" "$f"; then
        sed -i -E "s/^[[:space:]]*(${k//./\\.})[[:space:]]*=/# aws-optimize: \1 =/" "$f"
        info "Disabled $k in $f"
      fi
    done
  done
  sysctl --system >/dev/null 2>&1
  sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1
  local bad=0 want
  for kv in "${SYS[@]}"; do
    k=${kv%% =*}; want=$(echo "${kv#*= }" | tr -s ' ')
    [ "$(sget "$k")" = "$want" ] || { warn "$k = $(sget "$k") (wanted $want)"; bad=1; }
  done
  [ $bad = 0 ] && ok "sysctl tuning applied (${#SYS[@]} keys)"

  # ---- MTU persistence
  if [ -n "$target_mtu" ]; then
    ip link set dev "$IFACE" mtu "$target_mtu" && ok "MTU $CUR_MTU -> $target_mtu"
    if [ -d /etc/netplan ] && have netplan; then
      local id
      id=$(netplan_id)
      cat > "$NETPLAN_FILE" <<EOF
# generated by aws-optimize - keep MTU and ignore DHCP MTU (AWS pushes 9001)
network:
  version: 2
  ethernets:
    $id:
      mtu: $target_mtu
      dhcp4-overrides:
        use-mtu: false
      dhcp6-overrides:
        use-mtu: false
EOF
      chmod 600 "$NETPLAN_FILE"
      if netplan generate 2>/dev/null; then
        systemctl is-active -q systemd-networkd && networkctl reload 2>/dev/null
        ok "MTU persisted in $NETPLAN_FILE (DHCP MTU ignored)"
      else
        rm -f "$NETPLAN_FILE"; netplan generate 2>/dev/null
        warn "netplan rejected MTU override; boot service will enforce MTU instead"
      fi
    fi
  fi

  # ---- qdisc + MSS clamp + boot persistence
  have iptables || { have apt-get && DEBIAN_FRONTEND=noninteractive apt-get install -y iptables </dev/null >/dev/null 2>&1; }
  write_boot_script "$target_mtu"
  mss_clamp_present && ok "MSS clamp active" || warn "MSS clamp could not be added"
  ok "qdisc: $(tc qdisc show dev "$IFACE" | awk 'NR==1{print $2}'), boot service: $(systemctl is-enabled "$UNIT_NAME" 2>/dev/null)"

  # ---- open files limit for proxy
  if [ -n "$PROXY_PID" ]; then
    local lim unit
    lim=$(awk '/Max open files/{print $4}' "/proc/$PROXY_PID/limits" 2>/dev/null)
    unit=$(ps -o unit= -p "$PROXY_PID" 2>/dev/null | tr -d ' ')
    if [ "${lim:-0}" -lt 65535 ] 2>/dev/null && [ -n "$unit" ] && [ "${unit%.service}" != "$unit" ] \
       && ! printf '%s' "$unit" | grep -qE 'docker|containerd|session'; then
      mkdir -p "/etc/systemd/system/$unit.d"
      printf '[Service]\nLimitNOFILE=1048576\n' > "/etc/systemd/system/$unit.d/99-aws-optimize.conf"
      echo "/etc/systemd/system/$unit.d/99-aws-optimize.conf" >> "$BK/limits.list"
      systemctl daemon-reload
      warn "Raised LimitNOFILE for $unit - takes effect after: systemctl restart $unit"
    fi
  fi

  hr "Done"
  ok "Nothing was restarted, clients stay connected."
  msg "  Measure result :  bash aws-optimize.sh bench --seconds 120"
  msg "  Undo           :  bash aws-optimize.sh rollback"
}

# ---------------------------------------------------------------- rollback

cmd_rollback() {
  [ -f "$BACKUP_ROOT/last" ] || die "No backup found in $BACKUP_ROOT"
  local BK; BK=$(cat "$BACKUP_ROOT/last")
  [ -d "$BK" ] || die "Backup dir $BK missing"
  # shellcheck disable=SC1091
  . "$BK/state"
  confirm "Rollback changes from $BK?" || die "Aborted"

  systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1
  rm -f "$UNIT_FILE" "$BOOT_SCRIPT"
  local ipt chain
  for ipt in iptables ip6tables; do
    have $ipt || continue
    for chain in POSTROUTING FORWARD; do
      while $ipt -t mangle -D $chain -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
    done
  done
  have netfilter-persistent && netfilter-persistent save >/dev/null 2>&1

  rm -f "$SYSCTL_FILE"
  [ -f "$BK/sysctl.conf" ] && cp -a "$BK/sysctl.conf" /etc/sysctl.conf
  cp -a "$BK/sysctl.d/." /etc/sysctl.d/
  sysctl -p "$BK/sysctl.snapshot" >/dev/null 2>&1
  sysctl --system >/dev/null 2>&1
  ok "sysctl restored"

  if [ -f "$NETPLAN_FILE" ]; then
    rm -f "$NETPLAN_FILE"
    netplan generate 2>/dev/null && systemctl is-active -q systemd-networkd && networkctl reload 2>/dev/null
  fi
  [ -n "$ORIG_MTU" ] && ip link set dev "$IFACE" mtu "$ORIG_MTU" && ok "MTU restored to $ORIG_MTU"
  tc qdisc del dev "$IFACE" root 2>/dev/null
  ok "qdisc reset to system default"

  if [ "$SWAP_CREATED" = 1 ] && [ -f "$SWAP_FILE" ]; then
    swapoff "$SWAP_FILE" 2>/dev/null && rm -f "$SWAP_FILE"
    sed -i "\|$SWAP_FILE|d" /etc/fstab
    ok "Swap removed"
  fi
  local f
  while read -r f; do [ -n "$f" ] && rm -f "$f"; done < "$BK/limits.list"
  systemctl daemon-reload
  rm -f "$BACKUP_ROOT/last"
  ok "Rollback complete"
}

# ---------------------------------------------------------------- main

menu() {
  local c
  msg "${W}aws-optimize v$VERSION${N} - Xray/V2Ray network tuning"
  msg "  1) Check server (read-only)"
  msg "  2) Apply optimizations"
  msg "  3) Benchmark retransmit rate (60s)"
  msg "  4) Rollback last apply"
  msg "  0) Exit"
  printf 'Select: '
  read -r c </dev/tty
  case $c in
    1) cmd_check ;;
    2) cmd_apply ;;
    3) cmd_bench ;;
    4) cmd_rollback ;;
    *) exit 0 ;;
  esac
}

main() {
  local cmd=""
  while [ $# -gt 0 ]; do
    case $1 in
      check|apply|bench|rollback) cmd=$1 ;;
      -y|--yes) ASSUME_YES=1 ;;
      --mtu) FORCE_MTU=$2; shift ;;
      --no-mtu) DO_MTU=0 ;;
      --swap) DO_SWAP=yes ;;
      --no-swap) DO_SWAP=no ;;
      --seconds) BENCH_SECS=$2; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "Unknown argument: $1" ;;
    esac
    shift
  done
  [ "$(id -u)" = 0 ] || die "Run as root (use: curl ... | sudo bash)"
  [ "$(uname -s)" = Linux ] || die "Linux only"
  have ip && have ss && have tc || die "Requires iproute2 (ip, ss, tc)"
  if [ -n "$FORCE_MTU" ] && ! [ "$FORCE_MTU" -ge 576 ] 2>/dev/null; then die "Invalid --mtu"; fi

  case $cmd in
    "") if tty_ok; then menu; else cmd_check; fi ;;
    check) cmd_check ;;
    apply) cmd_apply ;;
    bench) cmd_bench ;;
    rollback) cmd_rollback ;;
  esac
}

main "$@"
