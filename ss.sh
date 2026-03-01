cat > /root/ss.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

METHOD="chacha20-ietf-poly1305"
PORT_MIN=1024
PORT_MAX=10000
PASS_LEN=32

CFG="/etc/shadowsocks-libev/config.json"
OUTDIR="/root/ss_keys"
LAST="${OUTDIR}/current.txt"
UNIT="shadowsocks-libev-server@config"
MARKER="/var/lib/ssmgr/installed"

need_root(){ [[ ${EUID} -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }; }
ensure_dirs(){ mkdir -p "$OUTDIR" "$(dirname "$MARKER")"; }
installed_ok(){ [[ -f "$MARKER" ]] && command -v ss-server >/dev/null 2>&1; }

install_once(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y shadowsocks-libev openssl curl ca-certificates ethtool python3 >/dev/null
  date -Is > "$MARKER"
  echo "Installed."
}

rand_port(){
  local p
  while :; do
    p="$(shuf -i "${PORT_MIN}-${PORT_MAX}" -n 1)"
    if ! ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE ":${p}$"; then
      echo "$p"; return
    fi
  done
}

rand_pass(){
  openssl rand -base64 48 | tr -d '\n' | tr '/+' 'Aa' | cut -c1-"${PASS_LEN}"
}

detect_host(){
  local pub=""
  pub="$(curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)"
  if [[ "${pub}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then echo "$pub"; return; fi
  local lip=""
  lip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  echo "${lip:-127.0.0.1}"
}

b64url_nopad(){ base64 -w 0 | tr '+/' '-_' | tr -d '='; }
urlencode_min(){ local s="$1"; s="${s// /%20}"; s="${s//#/%23}"; echo "$s"; }

make_links(){
  local host="$1" port="$2" pass="$3" tag="$4"
  local tag_enc userinfo_b64 legacy_b64 sip002 legacy
  tag_enc="$(urlencode_min "$tag")"
  userinfo_b64="$(printf '%s:%s' "$METHOD" "$pass" | b64url_nopad)"
  sip002="ss://${userinfo_b64}@${host}:${port}#${tag_enc}"
  legacy_b64="$(printf '%s:%s@%s:%s' "$METHOD" "$pass" "$host" "$port" | base64 -w 0)"
  legacy="ss://${legacy_b64}#${tag_enc}"
  echo "$legacy" "$sip002"
}

write_config(){
  local port="$1" pass="$2"
  cat > "$CFG" <<EOF2
{
  "server":["0.0.0.0"],
  "server_port": ${port},
  "password":"${pass}",
  "timeout":300,
  "method":"${METHOD}",
  "fast_open": true,
  "reuse_port": true,
  "mode":"tcp_and_udp"
}
EOF2
}

restart_service(){
  systemctl enable --now "$UNIT" >/dev/null 2>&1 || true
  systemctl restart "$UNIT"
}

default_iface(){
  ip route get 1.1.1.1 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

iface_speed(){
  local iface="$1"
  command -v ethtool >/dev/null 2>&1 || return 0
  ethtool "$iface" 2>/dev/null | awk -F': ' '/Speed:/{print $2; exit}'
}

rate_mbps(){
  local iface="$1"
  local rx1 tx1 rx2 tx2
  rx1="$(cat /sys/class/net/"$iface"/statistics/rx_bytes 2>/dev/null || echo 0)"
  tx1="$(cat /sys/class/net/"$iface"/statistics/tx_bytes 2>/dev/null || echo 0)"
  sleep 1
  rx2="$(cat /sys/class/net/"$iface"/statistics/rx_bytes 2>/dev/null || echo 0)"
  tx2="$(cat /sys/class/net/"$iface"/statistics/tx_bytes 2>/dev/null || echo 0)"
  python3 - <<PY
rx=(${rx2}-${rx1}); tx=(${tx2}-${tx1})
print(f"{rx*8/1e6:.2f} {tx*8/1e6:.2f}")
PY
}

current_port(){
  grep -oP '"server_port"\s*:\s*\K[0-9]+' "$CFG" 2>/dev/null || true
}

connected_ips(){
  local port="$1"
  [[ -n "$port" ]] || { echo 0; return; }
  ss -Hnt "sport = :${port}" 2>/dev/null | awk '{print $5}' | sed 's/:\([0-9]\+\)$//' | sort -u | wc -l | tr -d ' '
}

status_view(){
  local iface speed rx tx port conn
  iface="$(default_iface || true)"; [[ -n "${iface:-}" ]] || iface="eth0"
  speed="$(iface_speed "$iface" || true)"
  read -r rx tx < <(rate_mbps "$iface" 2>/dev/null || echo "0.00 0.00")
  port="$(current_port || true)"
  conn="$(connected_ips "$port")"

  echo "=== SYSTEM ==="
  echo "Uptime : $(uptime -p 2>/dev/null || true)"
  echo "Load   : $(awk '{print $1" "$2" "$3}' /proc/loadavg)"
  echo "RAM    : $(free -m | awk '/Mem:/ {printf "%d/%d MB (free %d)\n",$3,$2,$4}')"
  echo "Disk / : $(df -h / | awk 'NR==2{print $3"/"$2" used ("$5")"}')"
  echo
  echo "=== NET ==="
  echo "Iface  : ${iface}"
  echo "Link   : ${speed:-Unknown}"
  echo "Now    : RX ${rx} Mbps | TX ${tx} Mbps"
  echo
  echo "=== SS ==="
  systemctl is-active "$UNIT" >/dev/null 2>&1 && echo "Service: active" || echo "Service: inactive"
  echo "Port   : ${port:-?}"
  echo "Conn   : ${conn}"
  echo
}

show_links_only(){
  if [[ -f "$LAST" ]]; then
    grep -E '^(LEGACY=|SIP002=)' "$LAST" | cut -d= -f2-
  else
    echo "No key yet. Create: sudo bash $0 new"
  fi
}

new_key(){
  local host="${1:-}" tag="${2:-ss}"
  [[ -n "$host" ]] || host="$(detect_host)"

  local port pass legacy sip002
  port="$(rand_port)"
  pass="$(rand_pass)"

  write_config "$port" "$pass"
  restart_service

  read -r legacy sip002 < <(make_links "$host" "$port" "$pass" "$tag")

  cat > "$LAST" <<EOF3
PORT=${port}
PASSWORD=${pass}
LEGACY=${legacy}
SIP002=${sip002}
EOF3

  echo
  echo "=== COPY ==="
  echo "${legacy}"
  echo "${sip002}"
  echo "==========="
  echo
}

main(){
  need_root
  ensure_dirs

  case "${1:-}" in
    install)
      install_once
      ;;
    status)
      installed_ok || { echo "Not installed. Run: sudo bash $0 install"; exit 1; }
      status_view
      ;;
    show)
      installed_ok || { echo "Not installed. Run: sudo bash $0 install"; exit 1; }
      cat "$LAST" 2>/dev/null || echo "No key yet. Create: sudo bash $0 new"
      ;;
    new)
      installed_ok || { echo "Not installed. Run: sudo bash $0 install"; exit 1; }
      status_view
      new_key "${2:-}" "${3:-ss}"
      ;;
    "" )
      installed_ok || { echo "Not installed. Run: sudo bash $0 install"; exit 1; }
      status_view
      echo "--- KEY ---"
      show_links_only
      echo "----------"
      ;;
    *)
      echo "Usage: $0 [install|status|show|new]"
      exit 1
      ;;
  esac
}

main "$@"
EOF

chmod +x /root/ss.sh
