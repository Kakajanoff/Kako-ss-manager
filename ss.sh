#!/usr/bin/env bash
# ss.sh - Minimal Shadowsocks multi-key manager + clean stats
# 1) One-time install:
#    sudo bash /root/ss.sh install
# 2) Run:
#    sudo bash /root/ss.sh

set -euo pipefail

METHOD="chacha20-ietf-poly1305"
PORT_MIN=1024
PORT_MAX=10000
PASS_LEN=32

USERS_DIR="/etc/shadowsocks-libev/users"
OUTDIR="/root/ss_keys"
DB_CSV="${OUTDIR}/keys.csv"
UNIT="/etc/systemd/system/ss-user@.service"
MARKER="/var/lib/ssmgr/installed"

need_root(){ [[ ${EUID} -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }; }

ensure_dirs(){
  mkdir -p "$USERS_DIR" "$OUTDIR" "$(dirname "$MARKER")"
  [[ -f "$DB_CSV" ]] || echo "id,created_at,host,port,method,password,tag,sip002,legacy" > "$DB_CSV"
}

installed_ok(){
  [[ -f "$MARKER" ]] && [[ -f "$UNIT" ]] && command -v ss-server >/dev/null 2>&1
}

install_deps_once(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y shadowsocks-libev openssl curl ca-certificates ethtool >/dev/null

  cat > "$UNIT" <<'EOF'
[Unit]
Description=Shadowsocks user instance (%i)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/ss-server -c /etc/shadowsocks-libev/users/%i.json
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  date -Is > "$MARKER"
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

urlencode_min(){
  local s="$1"
  s="${s// /%20}"
  s="${s//#/%23}"
  echo "$s"
}

make_links(){
  local host="$1" port="$2" pass="$3" tag="$4"
  local tag_enc userinfo_b64 legacy_b64 sip002 legacy

  tag_enc="$(urlencode_min "$tag")"

  # SIP002
  userinfo_b64="$(printf '%s:%s' "$METHOD" "$pass" | b64url_nopad)"
  sip002="ss://${userinfo_b64}@${host}:${port}#${tag_enc}"

  # Legacy (çok client’ta sorunsuz)
  legacy_b64="$(printf '%s:%s@%s:%s' "$METHOD" "$pass" "$host" "$port" | base64 -w 0)"
  legacy="ss://${legacy_b64}#${tag_enc}"

  echo "$sip002" "$legacy"
}

connected_ips_for_port(){
  local port="$1"
  ss -Hnt "sport = :${port}" 2>/dev/null \
    | awk '{print $5}' \
    | sed 's/:\([0-9]\+\)$//' \
    | sort -u \
    | wc -l \
    | tr -d ' '
}

default_iface(){
  ip route get 1.1.1.1 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

iface_speed(){
  local iface="$1"
  if command -v ethtool >/dev/null 2>&1; then
    ethtool "$iface" 2>/dev/null | awk -F': ' '/Speed:/{print $2; exit}'
  fi
}

rate_mbps(){
  # anlık hız (1 saniye) - gerçek akan trafik
  local iface="$1"
  local rx1 tx1 rx2 tx2
  rx1="$(cat /sys/class/net/"$iface"/statistics/rx_bytes 2>/dev/null || echo 0)"
  tx1="$(cat /sys/class/net/"$iface"/statistics/tx_bytes 2>/dev/null || echo 0)"
  sleep 1
  rx2="$(cat /sys/class/net/"$iface"/statistics/rx_bytes 2>/dev/null || echo 0)"
  tx2="$(cat /sys/class/net/"$iface"/statistics/tx_bytes 2>/dev/null || echo 0)"

  # bytes/sec -> Mbps
  python3 - <<PY
rx=(${rx2}-${rx1})
tx=(${tx2}-${tx1})
rx_mbps=rx*8/1e6
tx_mbps=tx*8/1e6
print(f"{rx_mbps:.2f} {tx_mbps:.2f}")
PY
}

mini_status(){
  local iface speed rx tx
  iface="$(default_iface || true)"
  [[ -n "${iface:-}" ]] || iface="eth0"

  speed="$(iface_speed "$iface" || true)"
  read -r rx tx < <(rate_mbps "$iface" 2>/dev/null || echo "0.00 0.00")

  echo "=== SYSTEM ==="
  echo "Uptime : $(uptime -p 2>/dev/null || true)"
  echo "Load   : $(awk '{print $1" "$2" "$3}' /proc/loadavg)"
  echo "RAM    : $(free -m | awk '/Mem:/ {printf "%d/%d MB (free %d)\n",$3,$2,$4}')"
  echo "Disk / : $(df -h / | awk 'NR==2{print $3"/"$2" used ("$5")"}')"
  echo
  echo "=== NETWORK ==="
  echo "Iface  : ${iface}"
  echo "Link   : ${speed:-Unknown}"
  echo "Now    : RX ${rx} Mbps | TX ${tx} Mbps"
  echo
}

new_key(){
  local host="${1:-}" tag="${2:-ss}"
  [[ -n "$host" ]] || host="$(detect_host)"

  local id port pass created cfg sip002 legacy
  id="$(date +%Y%m%d-%H%M%S)-$RANDOM"
  port="$(rand_port)"
  pass="$(rand_pass)"
  created="$(date -Is)"

  cfg="${USERS_DIR}/${id}.json"
  cat > "$cfg" <<EOF
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
EOF

  read -r sip002 legacy < <(make_links "$host" "$port" "$pass" "$tag")

  systemctl enable "ss-user@${id}.service" >/dev/null 2>&1 || true
  systemctl restart "ss-user@${id}.service" >/dev/null

  echo "${id},${created},${host},${port},${METHOD},${pass},${tag},${sip002},${legacy}" >> "$DB_CSV"

  # “current.txt” her seferinde overwrite (tek key)
  {
    echo "PORT=${port}"
    echo "PASSWORD=${pass}"
    echo "LEGACY=${legacy}"
    echo "SIP002=${sip002}"
  } > "${OUTDIR}/current.txt"

  # KOPYALAMA İÇİN: SADECE LINKLER (tek başına)
  echo
  echo "=== COPY ==="
  echo "${legacy}"
  echo "${sip002}"
  echo "==========="
  echo
  echo "Port: ${port}  (service: ss-user@${id}.service)"
}

list_keys(){
  echo "=== KEYS (PORT | CONNECTED) ==="
  tail -n +2 "$DB_CSV" | while IFS=',' read -r id created host port method pass tag sip002 legacy; do
    [[ -z "${id:-}" ]] && continue
    local c
    c="$(connected_ips_for_port "$port" || echo 0)"
    printf "%-6s | %s\n" "$port" "$c"
  done
  echo "==============================="
  echo
}

del_key(){
  local id="${1:-}"
  [[ -n "$id" ]] || { echo "Usage: $0 del <ID>"; exit 1; }

  systemctl stop "ss-user@${id}.service" >/dev/null 2>&1 || true
  systemctl disable "ss-user@${id}.service" >/dev/null 2>&1 || true
  rm -f "${USERS_DIR}/${id}.json" >/dev/null 2>&1 || true
  systemctl daemon-reload >/dev/null 2>&1 || true

  awk -F',' -v id="$id" 'NR==1{print;next} $1!=id{print}' "$DB_CSV" > "${DB_CSV}.tmp"
  mv "${DB_CSV}.tmp" "$DB_CSV"
  echo "Deleted: $id"
}

menu(){
  echo "1) Status"
  echo "2) Keys (port|connected)"
  echo "3) New key"
  echo "4) Delete key (by ID)"
  echo "5) Exit"
  echo -n "> "
  read -r ch
  case "$ch" in
    1) mini_status ;;
    2) list_keys ;;
    3)
      echo -n "HOST (blank=auto public IP): "
      read -r host
      echo -n "TAG  (blank=ss): "
      read -r tag
      new_key "${host:-}" "${tag:-ss}"
      ;;
    4)
      echo -n "ID: "
      read -r id
      del_key "$id"
      ;;
    *) exit 0 ;;
  esac
}

main(){
  need_root
  ensure_dirs

  case "${1:-}" in
    install)
      install_deps_once
      echo "Installed. Next runs will not install again."
      ;;
    new)
      installed_ok || { echo "Not installed. Run: sudo bash $0 install"; exit 1; }
      new_key "${2:-}" "${3:-ss}"
      ;;
    list)
      installed_ok || { echo "Not installed. Run: sudo bash $0 install"; exit 1; }
      list_keys
      ;;
    del)
      installed_ok || { echo "Not installed. Run: sudo bash $0 install"; exit 1; }
      del_key "${2:-}"
      ;;
    "" )
      installed_ok || { echo "Not installed. Run once: sudo bash $0 install"; exit 1; }
      mini_status
      list_keys
      while :; do menu; done
      ;;
    *)
      echo "Usage: $0 [install|new|list|del]"
      exit 1
      ;;
  esac
}

main "$@"
