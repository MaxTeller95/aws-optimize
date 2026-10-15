#!/usr/bin/env bash
# aws-optimize - smart network tuning for Xray / V2Ray / 3x-ui / Marzban servers
# on AWS (EC2, Lightsail) and other Linux VPS.
#
#   curl -fsSL https://raw.githubusercontent.com/javad48/aws-optimize/main/aws-optimize.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/javad48/aws-optimize/main/aws-optimize.sh | sudo bash -s -- apply -y
#
# Commands: check | apply | bench | doctor | rollback   (no command = interactive menu)

VERSION="1.1.0"
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
DO_DOCTOR=1
DOCTOR_SHADOW=0
IDLE_SECS=300
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
  doctor      What the client connection doctor reset (stuck / idle phone connections)
  rollback    Undo the last apply
  (none)      Interactive menu

Options:
  -y, --yes         Do not ask for confirmation
  --mtu N           Force interface MTU (default: auto, from path MTU)
  --no-mtu          Do not touch interface MTU
  --swap            Always create swap if none exists
  --no-swap         Never create swap
  --seconds N       Duration for bench (default 60)
  --no-doctor       Do not install the client connection doctor
  --doctor-shadow   Doctor only counts what it would reset (no resets)
  --idle N          Doctor: reset a client connection idle N seconds (default 300, 0 = off)
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
  report_doctor
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
  local doc="off (--no-doctor)"
  [ "$DO_DOCTOR" = 1 ] && doc="$( [ "$DOCTOR_SHADOW" = 1 ] && echo "shadow (count only)" || echo on): stuck 10s / idle ${IDLE_SECS}s reset, thin streams, keepalive"
  msg "  client conn doctor: $doc"
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
    echo "IFACE=$IFACE"; echo "ORIG_MTU=$CUR_MTU"; echo "SWAP_CREATED=$make_swap"; echo "DOCTOR=$DO_DOCTOR"
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

  # ---- client connection doctor
  if [ "$DO_DOCTOR" = 1 ]; then
    local dopts="--idle $IDLE_SECS"; [ "$DOCTOR_SHADOW" = 1 ] && dopts="$dopts --shadow"
    if install_doctor $dopts; then
      ok "Client connection doctor running ($DOCTOR_UNIT$( [ "$DOCTOR_SHADOW" = 1 ] && echo ', shadow'))"
    else
      warn "Client connection doctor did not start: journalctl -u $DOCTOR_UNIT"
    fi
  fi

  hr "Done"
  ok "Nothing was restarted, clients stay connected."
  msg "  Measure result :  bash aws-optimize.sh bench --seconds 120"
  [ "$DO_DOCTOR" = 1 ] && msg "  Doctor status  :  bash aws-optimize.sh doctor"
  msg "  Undo           :  bash aws-optimize.sh rollback"
}

# ---------------------------------------------------------------- client connection doctor
#
# Phones leave connections behind: the screen goes off, the app is sent to the background, the
# phone hops between Wi-Fi and mobile data. The connection stays open on the server but nothing
# moves - data waits unacknowledged in RTO backoff (retransmits doubling up to 12.8 s and on), or
# nothing goes either way at all - and the app keeps using it: the user sees a "stuck" VPN until
# timeouts run out, minutes later. A small daemon (stdlib Python, no restart of anything):
#   * thin streams: TCP_THIN_LINEAR_TIMEOUTS on every client connection - a connection with
#     little in flight retransmits ~one RTO apart for its first six tries instead of doubling, so
#     it recovers as soon as the phone's network is back
#   * keepalive 45 s + TCP_USER_TIMEOUT 90 s on every client connection: a phone that is gone
#     is noticed in ~1.5 minutes instead of ~15 (tcp_retries2)
#   * stuck: no ACK for 10 s, in backoff, while the same client shows life (data on another of
#     its connections, a new connection, or SYNs that go unanswered twice running - it is
#     trying to reach us and failing) -> reset (RST): the app dials a fresh connection at once
#   * idle: no data either way for 5 minutes -> reset
# The options are set on the proxy's own sockets through pidfd_getfd(2) (kernel 5.6+); resets
# are sock_destroy (ss -K). A client's address can be shared (carrier NAT): resetting a gone
# phone's connection only does sooner what TCP_USER_TIMEOUT does anyway.

DOCTOR_BIN=/usr/local/sbin/aws-optimize-doctor
DOCTOR_UNIT=aws-optimize-doctor.service
DOCTOR_UNIT_FILE=/etc/systemd/system/$DOCTOR_UNIT
DOCTOR_STATE=/run/aws-optimize-doctor.json

doctor_source() {
  cat <<'CONN_DOCTOR_PY'
#!/usr/bin/env python3
"""aws-optimize-doctor - resets client connections a phone left behind (see aws-optimize.sh).

    aws-optimize-doctor run [--shadow] [--idle S] [--stall S] [--no-tune]   the daemon
    aws-optimize-doctor status                                              what it did
    aws-optimize-doctor scan                                                one look, changes nothing
"""
import argparse, collections, ctypes, errno, json, os, re, signal, socket, subprocess, sys, syslog, time

STATE = "/run/aws-optimize-doctor.json"
PROXY = re.compile(r"^(xray|v2ray|sing-box)")
LOOP = ("127.", "::1")
SYS_PIDFD_GETFD = 438
TCP_THIN_LINEAR_TIMEOUTS = getattr(socket, "TCP_THIN_LINEAR_TIMEOUTS", 16)
INFO = {k: re.compile(r"\b%s:(\d+)" % k) for k in ("unacked", "lastack", "lastsnd", "lastrcv", "backoff")}


def split_hostport(s):
    host, _, port = s.rpartition(":")
    host = host.strip("[]")
    if host.startswith("::ffff:"):
        host = host[7:]
    return host, int(port) if port.isdigit() else 0


def ss(*args):
    return subprocess.run(["ss", *args], capture_output=True, text=True, timeout=15).stdout


def listen_ports():
    """The proxy's public listening ports: its inbounds, whatever the panel."""
    ports = set()
    for line in ss("-Htlpn").splitlines():
        f = line.split()
        m = re.search(r'users:\(\("([^"]+)"', line)
        if len(f) >= 4 and m and PROXY.match(m.group(1)):
            host, port = split_hostport(f[3])
            if not host.startswith(LOOP):
                ports.add(port)
    return ports


def sockets(ports):
    """Established client connections to those ports, with owner and TCP_INFO (one ss call)."""
    out, cur = [], None
    for line in ss("-tinpeH", "state", "established").splitlines():
        if not line:
            continue
        if not line[0].isspace():
            f = line.split()
            cur = None
            if len(f) < 4:
                continue
            lh, lp = split_hostport(f[2])
            ph, pp = split_hostport(f[3])
            m = re.search(r'users:\(\("([^"]+)",pid=(\d+),fd=(\d+)\)', line)
            ino = re.search(r"\bino:(\d+)", line)
            if not m or not PROXY.match(m.group(1)) or lp not in ports or lh.startswith(LOOP) or ph.startswith(LOOP):
                continue
            cur = {"l": lh, "lp": lp, "p": ph, "pp": pp, "pid": int(m.group(2)), "fd": int(m.group(3)),
                   "ino": int(ino.group(1)) if ino else 0}
            out.append(cur)
        elif cur is not None:
            for k, rx in INFO.items():
                m = rx.search(line)
                if m:
                    cur[k] = int(m.group(1))
    return out


def syn_recv(ports):
    c = collections.Counter()
    for line in ss("-tnH", "state", "syn-recv").splitlines():
        f = line.split()
        if len(f) >= 4 and split_hostport(f[2])[1] in ports:
            c[split_hostport(f[3])[0]] += 1
    return c


def kill(socks, chunk=40):
    """Reset these connections (sock_destroy: an RST to the client). Matched by server port,
    client port and client address - exact for one connection; a dual-stack listener's
    ::ffff:a.b.c.d socket matches the plain IPv4 address."""
    done = 0
    for i in range(0, len(socks), chunk):
        flt = " or ".join("( sport = :%d and dport = :%d and dst %s )" % (s["lp"], s["pp"], s["p"])
                          for s in socks[i:i + chunk])
        done += len([l for l in ss("-K", "-tnH", "state", "established", flt).splitlines() if l.strip()])
    return done


class Tuner:
    """keepalive + TCP_USER_TIMEOUT + linear thin-stream retransmits, set from outside on the
    proxy's own sockets through a duplicate of the descriptor: the very same socket, no restart."""

    def __init__(self, on=True):
        self.libc = ctypes.CDLL(None, use_errno=True)
        self.done, self.pidfds = set(), {}
        self.count = collections.Counter()
        self.off = None if on else "turned off (--no-tune)"

    def getfd(self, pid, fd):
        if pid not in self.pidfds:
            self.pidfds[pid] = os.pidfd_open(pid)
        r = self.libc.syscall(SYS_PIDFD_GETFD, self.pidfds[pid], fd, 0)
        if r < 0:
            e = ctypes.get_errno()
            raise OSError(e, os.strerror(e))
        return r

    def run(self, socks):
        if self.off:
            return
        seen = {s["ino"] for s in socks}
        self.done &= seen
        for s in socks:
            if not s["ino"] or s["ino"] in self.done:
                continue
            self.done.add(s["ino"])
            try:
                dup = self.getfd(s["pid"], s["fd"])
            except AttributeError:                       # Python < 3.9: no os.pidfd_open
                self.off = "Python 3.9+ needed"
                return
            except OSError as e:
                if e.errno in (errno.ENOSYS, errno.EPERM):
                    self.off = "kernel 5.6+ needed (pidfd_getfd)" if e.errno == errno.ENOSYS else "not permitted"
                    syslog.syslog("socket tuning off: %s" % self.off)
                    return
                self.pidfds.pop(s["pid"], None)
                self.count["gone"] += 1
                continue
            try:
                if os.fstat(dup).st_ino != s["ino"]:        # the fd was reused since ss looked
                    os.close(dup)
                    continue
                k = socket.socket(fileno=dup)
                try:
                    k.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
                    k.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, 45)
                    k.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, 15)
                    k.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 4)
                    k.setsockopt(socket.IPPROTO_TCP, socket.TCP_USER_TIMEOUT, 90000)
                    k.setsockopt(socket.IPPROTO_TCP, TCP_THIN_LINEAR_TIMEOUTS, 1)
                    self.count["tuned"] += 1
                finally:
                    k.close()                               # the duplicate only
            except OSError:
                self.count["gone"] += 1
        live = {s["pid"] for s in socks}
        for pid in [p for p in self.pidfds if p not in live]:
            os.close(self.pidfds.pop(pid))


class Doctor:
    def __init__(self, stall_ms=10000, stall_backoff=2, alive_ms=5000, idle_s=300, kill_max=100):
        self.stall_ms, self.stall_backoff, self.alive_ms = stall_ms, stall_backoff, alive_ms
        self.idle_s, self.kill_max = idle_s, kill_max
        self.prev, self.flagged = set(), set()
        self.syn_prev = collections.Counter()
        self.last = {}

    def pick(self, socks, syn):
        """(connection, why) to reset - no side effects."""
        alive = {s["p"] for s in socks if s.get("lastrcv", 10 ** 9) < self.alive_ms}
        new = {s["p"] for s in socks if s["ino"] not in self.prev} if self.prev else set()
        failing = {ip for ip in syn if self.syn_prev.get(ip)}     # unanswered SYNs two looks running
        self.prev, self.syn_prev = {s["ino"] for s in socks}, syn
        out = []
        for s in socks:
            if (s.get("unacked") and s.get("lastack", 0) >= self.stall_ms
                    and s.get("backoff", 0) >= self.stall_backoff):
                why = ("alive" if s["p"] in alive else "new-conn" if s["p"] in new
                       else "failing" if s["p"] in failing else None)
                if why:
                    out.append((s, "stuck/" + why))
            elif (self.idle_s and s.get("lastrcv", 0) >= self.idle_s * 1000
                  and s.get("lastsnd", 0) >= self.idle_s * 1000):
                out.append((s, "idle"))
        self.last = {"connections": len(socks), "clients": len({s["p"] for s in socks}),
                     "failing_clients": len(failing), "syn_recv": sum(syn.values()),
                     "in_backoff": sum(1 for s in socks if s.get("backoff"))}
        return out[:self.kill_max]

    def once(self, socks, syn):
        """pick() without counting a connection twice (in shadow mode it is still there)."""
        picked = self.pick(socks, syn)
        self.flagged &= {s["ino"] for s in socks}
        picked = [(s, w) for s, w in picked if s["ino"] not in self.flagged]
        self.flagged |= {s["ino"] for s, _ in picked}
        return picked


def run(a):
    syslog.openlog("aws-optimize-doctor")
    stop = []
    signal.signal(signal.SIGTERM, lambda *_: stop.append(1))
    tuner, doc = Tuner(not a.no_tune), Doctor(stall_ms=a.stall * 1000, idle_s=a.idle)
    total, minute, recent = collections.Counter(), collections.Counter(), collections.deque(maxlen=20)
    ports, ports_t, minute_t, started = set(), 0, time.time(), time.time()
    syslog.syslog("start: %s, idle %ss, stall %ss" % ("shadow" if a.shadow else "live", a.idle, a.stall))
    while not stop:
        t0 = time.time()
        try:
            if t0 - ports_t > 30:
                ports, ports_t = listen_ports(), t0
            socks = sockets(ports) if ports else []
            tuner.run(socks)
            picked = doc.once(socks, syn_recv(ports) if ports else {})
            if picked and not a.shadow:
                kill([s for s, _ in picked])
            for s, why in picked:
                total[why.split("/")[0]] += 1
                minute[why.split("/")[0]] += 1
                recent.append({"t": round(t0), "ip": s["p"], "port": s["lp"], "why": why})
            if t0 - minute_t >= 60:
                if minute:
                    syslog.syslog("%s in the last minute: %s" % ("would reset" if a.shadow else "reset", dict(minute)))
                minute, minute_t = collections.Counter(), t0
            state = {"t": round(t0, 1), "started": round(started), "mode": "shadow" if a.shadow else "live",
                     "ports": sorted(ports), "now": doc.last, "reset": dict(total), "recent": list(recent),
                     "tuning": tuner.off or "on", "tuned": dict(tuner.count),
                     "rules": {"stall_s": a.stall, "idle_s": a.idle}}
            with open(STATE + ".tmp", "w") as f:
                json.dump(state, f)
            os.replace(STATE + ".tmp", STATE)
        except Exception as e:                               # one bad look must not stop the daemon
            syslog.syslog("look failed: %s" % e)
        time.sleep(max(0.2, 2 - (time.time() - t0)))


def status():
    try:
        v = json.load(open(STATE))
    except (OSError, ValueError):
        sys.exit("not running (no %s)" % STATE)
    n = v.get("now") or {}
    print("mode %s | ports %s | %s s old" % (v["mode"], ",".join(map(str, v["ports"])), round(time.time() - v["t"])))
    print("now: %s connections from %s clients, %s in RTO backoff, %s clients failing to connect (%s unanswered SYNs)" % (
        n.get("connections"), n.get("clients"), n.get("in_backoff"), n.get("failing_clients"), n.get("syn_recv")))
    print("reset since start: %s (stuck after %ss, idle after %ss)" % (v["reset"] or "none", v["rules"]["stall_s"], v["rules"]["idle_s"]))
    print("socket tuning: %s %s" % (v["tuning"], v["tuned"] or ""))
    for r in v["recent"][-8:]:
        print("  %s  %-15s :%-5s %s" % (time.strftime("%H:%M:%S", time.localtime(r["t"])), r["ip"], r["port"], r["why"]))


def scan():
    """key=value lines for aws-optimize.sh check. Two looks 2 s apart, so new connections and
    unanswered SYNs count as they do in the daemon."""
    ports = listen_ports()
    doc = Doctor()
    doc.pick(sockets(ports), syn_recv(ports))
    time.sleep(2)
    picked = doc.pick(sockets(ports), syn_recv(ports))
    c = collections.Counter(w.split("/")[0] for _, w in picked)
    for k, v in dict(doc.last, stuck=c["stuck"], idle=c["idle"]).items():
        print("%s=%s" % (k, v))


def main():
    p = argparse.ArgumentParser()
    p.add_argument("cmd", choices=["run", "status", "scan"])
    p.add_argument("--shadow", action="store_true", help="count what would be reset, reset nothing")
    p.add_argument("--idle", type=int, default=300, help="reset after S seconds with no data (0: off)")
    p.add_argument("--stall", type=int, default=10, help="stuck after S seconds with no ACK")
    p.add_argument("--no-tune", action="store_true", help="no keepalive / timeouts on sockets")
    a = p.parse_args()
    {"run": lambda: run(a), "status": status, "scan": scan}[a.cmd]()


if __name__ == "__main__":
    main()
CONN_DOCTOR_PY
}

install_doctor() { # args: extra ExecStart options
  have python3 || { warn "python3 not found - client connection doctor skipped"; return 1; }
  python3 -c 'import os; os.pidfd_open' 2>/dev/null \
    || warn "Python < 3.9: socket tuning off, stuck/idle resets still work"
  doctor_source > "$DOCTOR_BIN" && chmod 755 "$DOCTOR_BIN"
  cat > "$DOCTOR_UNIT_FILE" <<EOF
[Unit]
Description=aws-optimize client connection doctor (stuck / idle phone connections, thin streams)
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/env python3 $DOCTOR_BIN run $*
Restart=always
RestartSec=3
MemoryHigh=64M

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$DOCTOR_UNIT" >/dev/null 2>&1
  systemctl restart "$DOCTOR_UNIT"
  sleep 3
  systemctl is-active -q "$DOCTOR_UNIT"
}

remove_doctor() {
  systemctl disable --now "$DOCTOR_UNIT" >/dev/null 2>&1
  rm -f "$DOCTOR_UNIT_FILE" "$DOCTOR_BIN" "$DOCTOR_STATE" "$DOCTOR_STATE.tmp"
}

report_doctor() {
  hr "Client connections (phones: screen off, background, network hops)"
  if systemctl is-active -q "$DOCTOR_UNIT" 2>/dev/null; then
    row "Connection doctor" "running" ok
    "$DOCTOR_BIN" status 2>/dev/null | sed 's/^/  /'
    return
  fi
  [ -n "$PROXY_PID" ] && have python3 || return
  local tmp out; tmp=$(mktemp); doctor_source > "$tmp"
  out=$(python3 "$tmp" scan 2>/dev/null); rm -f "$tmp"
  [ -n "$out" ] || return
  local conns stuck idle back fail
  conns=$(printf '%s\n' "$out" | sed -n 's/^connections=//p')
  stuck=$(printf '%s\n' "$out" | sed -n 's/^stuck=//p')
  idle=$(printf '%s\n' "$out" | sed -n 's/^idle=//p')
  back=$(printf '%s\n' "$out" | sed -n 's/^in_backoff=//p')
  fail=$(printf '%s\n' "$out" | sed -n 's/^failing_clients=//p')
  row "Client connections" "${conns:-0}" info
  row "Stuck (client alive)" "${stuck:-0}" "$( [ "${stuck:-0}" -gt 0 ] && echo warn || echo ok)"
  row "Idle 5+ min" "${idle:-0}" "$( [ "${idle:-0}" -gt 0 ] && echo warn || echo ok)"
  row "In RTO backoff" "${back:-0}" info
  row "Failing to connect" "${fail:-0}" info
  row "Connection doctor" "not installed" warn
}

cmd_doctor() {
  [ -x "$DOCTOR_BIN" ] || die "Connection doctor is not installed. Run: apply"
  "$DOCTOR_BIN" status
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
  if [ -f "$DOCTOR_UNIT_FILE" ]; then remove_doctor; ok "Client connection doctor removed"; fi
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
  msg "  5) Client connection doctor status"
  msg "  0) Exit"
  printf 'Select: '
  read -r c </dev/tty
  case $c in
    1) cmd_check ;;
    2) cmd_apply ;;
    3) cmd_bench ;;
    4) cmd_rollback ;;
    5) cmd_doctor ;;
    *) exit 0 ;;
  esac
}

main() {
  local cmd=""
  while [ $# -gt 0 ]; do
    case $1 in
      check|apply|bench|doctor|rollback) cmd=$1 ;;
      -y|--yes) ASSUME_YES=1 ;;
      --mtu) FORCE_MTU=$2; shift ;;
      --no-mtu) DO_MTU=0 ;;
      --swap) DO_SWAP=yes ;;
      --no-swap) DO_SWAP=no ;;
      --seconds) BENCH_SECS=$2; shift ;;
      --no-doctor) DO_DOCTOR=0 ;;
      --doctor-shadow) DOCTOR_SHADOW=1 ;;
      --idle) IDLE_SECS=$2; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "Unknown argument: $1" ;;
    esac
    shift
  done
  [ "$(id -u)" = 0 ] || die "Run as root (use: curl ... | sudo bash)"
  [ "$(uname -s)" = Linux ] || die "Linux only"
  have ip && have ss && have tc || die "Requires iproute2 (ip, ss, tc)"
  if [ -n "$FORCE_MTU" ] && ! [ "$FORCE_MTU" -ge 576 ] 2>/dev/null; then die "Invalid --mtu"; fi
  [ "$IDLE_SECS" -ge 0 ] 2>/dev/null || die "Invalid --idle"

  case $cmd in
    "") if tty_ok; then menu; else cmd_check; fi ;;
    check) cmd_check ;;
    apply) cmd_apply ;;
    bench) cmd_bench ;;
    doctor) cmd_doctor ;;
    rollback) cmd_rollback ;;
  esac
}

main "$@"
