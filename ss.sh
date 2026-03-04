#!/usr/bin/env bash
set -euo pipefail

# ===== CONFIG =====
DO_IP="161.35.213.138"
DO_SSH_USER="root"
DO_SSH_PORT="22"
DO_SSH_PASS="CHANGE_ME"   # <-- BURAYA DO ROOT SSH PAROLASINI YAZ

METHOD="chacha20-ietf-poly1305"
PORT_MIN=1024
PORT_MAX=10000
PASS_LEN=32

STATE_DIR="/var/lib/ss_do"
KEYFILE="/root/ss_keys/current.txt"
MARKER="${STATE_DIR}/installed"
DO_MARKER="/var/lib/ss_do_backend/installed"

FW_RULES="/etc/iptables/ss-do-forward.rules"
FW_SERVICE="/etc/systemd/system/ss-do-forward.service"

need_root(){ [[ ${EUID} -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }; }
mkdirs(){ mkdir -p /root/ss_keys "$STATE_DIR" /etc/iptables; }

iface_default(){ ip -4 route list default 2>/dev/null | awk '{print $5; exit}' || echo "eth0"; }
gcore_public_ip(){ curl -4 -s --max-time 3 https://api.ipify.org || hostname -I | awk '{print $1}'; }

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
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -d '\n' | tr '/+' 'Aa' | cut -c1-"${PASS_LEN}"
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${PASS_LEN}"
  fi
}

b64url_nopad(){ base64 -w 0 | tr '+/' '-_' | tr -d '='; }
make_ss_uri(){
  local host="$1" port="$2" pass="$3"
  local userinfo
  userinfo="$(printf '%s:%s' "$METHOD" "$pass" | b64url_nopad)"
  echo "ss://${userinfo}@${host}:${port}"
}

ipt_add(){
  local table="$1"; shift
  local chain="$1"; shift
  if iptables -t "$table" -C "$chain" "$@" >/dev/null 2>&1; then return 0; fi
  iptables -t "$table" -A "$chain" "$@"
}
ipt_del_all(){
  local table="$1"; shift
  local chain="$1"; shift
  while iptables -t "$table" -D "$chain" "$@" >/dev/null 2>&1; do :; done
}

ensure_fw_service(){
  cat > "$FW_SERVICE" <<EOF
[Unit]
Description=SS -> DO forward iptables restore
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/iptables-restore $FW_RULES
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable ss-do-forward.service >/dev/null 2>&1 || true
}

apply_forward(){
  local port="$1"
  local iface="$2"

  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ss-do-forward.conf

  ipt_add nat PREROUTING -i "$iface" -p tcp --dport "$port" -j DNAT --to-destination "${DO_IP}:${port}"
  ipt_add nat PREROUTING -i "$iface" -p udp --dport "$port" -j DNAT --to-destination "${DO_IP}:${port}"

  ipt_add filter FORWARD -i "$iface" -p tcp -d "$DO_IP" --dport "$port" -j ACCEPT
  ipt_add filter FORWARD -i "$iface" -p udp -d "$DO_IP" --dport "$port" -j ACCEPT
  ipt_add filter FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  ipt_add nat POSTROUTING -j MASQUERADE

  iptables-save > "$FW_RULES"
  ensure_fw_service
  systemctl restart ss-do-forward.service >/dev/null 2>&1 || true
}

remove_forward(){
  local port="$1"
  local iface="$2"
  ipt_del_all nat PREROUTING -i "$iface" -p tcp --dport "$port" -j DNAT --to-destination "${DO_IP}:${port}"
  ipt_del_all nat PREROUTING -i "$iface" -p udp --dport "$port" -j DNAT --to-destination "${DO_IP}:${port}"
  ipt_del_all filter FORWARD -i "$iface" -p tcp -d "$DO_IP" --dport "$port" -j ACCEPT
  ipt_del_all filter FORWARD -i "$iface" -p udp -d "$DO_IP" --dport "$port" -j ACCEPT
}

ssh_do(){
  # SSH password fixed via sshpass (no prompt)
  sshpass -p "${DO_SSH_PASS}" ssh \
    -o StrictHostKeyChecking=accept-new \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    -p "$DO_SSH_PORT" "${DO_SSH_USER}@${DO_IP}" "$@"
}

ensure_do_backend(){
  ssh_do "test -f '${DO_MARKER}' && exit 0; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update -y && apt-get install -y shadowsocks-libev openssl ca-certificates >/dev/null; \
    mkdir -p /var/lib/ss_do_backend; date -Is > '${DO_MARKER}'"
}

write_do_ss_config(){
  local port="$1" pass="$2"
  ssh_do "cat > /etc/shadowsocks-libev/config.json <<'EOF'
{
  \"server\":[\"0.0.0.0\"],
  \"server_port\": ${port},
  \"password\":\"${pass}\",
  \"timeout\":300,
  \"udp_timeout\": 60,
  \"method\":\"${METHOD}\",
  \"fast_open\": true,
  \"reuse_port\": true,
  \"mode\":\"tcp_and_udp\"
}
EOF
systemctl enable --now shadowsocks-libev-server@config >/dev/null 2>&1 || true
systemctl restart shadowsocks-libev-server@config"
}

current_port(){
  [[ -f "$KEYFILE" ]] || echo ""
  awk -F= '/^PORT=/{print $2; exit}' "$KEYFILE" 2>/dev/null || true
}

create_if_missing(){
  if [[ -f "$KEYFILE" && -f "$MARKER" ]]; then return 0; fi
  local port pass
  port="$(rand_port)"
  pass="$(rand_pass)"

  ensure_do_backend
  write_do_ss_config "$port" "$pass"

  cat > "$KEYFILE" <<EOF
METHOD=${METHOD}
PORT=${port}
PASSWORD=${pass}
SSURI=$(make_ss_uri "$(gcore_public_ip)" "$port" "$pass")
EOF
  date -Is > "$MARKER"

  local iface
  iface="$(iface_default)"
  apply_forward "$port" "$iface"
}

rotate_new(){
  local old_port iface port pass
  iface="$(iface_default)"
  old_port="$(current_port || true)"

  port="$(rand_port)"
  pass="$(rand_pass)"

  ensure_do_backend
  write_do_ss_config "$port" "$pass"

  if [[ -n "${old_port:-}" ]]; then
    remove_forward "$old_port" "$iface" || true
  fi
  apply_forward "$port" "$iface"

  cat > "$KEYFILE" <<EOF
METHOD=${METHOD}
PORT=${port}
PASSWORD=${pass}
SSURI=$(make_ss_uri "$(gcore_public_ip)" "$port" "$pass")
EOF

  echo
  echo "=== COPY ==="
  awk -F= '/^SSURI=/{print $2}' "$KEYFILE"
  echo "==========="
  echo
}

show(){
  if [[ ! -f "$KEYFILE" ]]; then
    echo "No key yet."
    exit 0
  fi
  awk -F= '/^SSURI=/{print $2}' "$KEYFILE"
}

main(){
  need_root
  mkdirs

  # Ensure base tools on Gcore (add sshpass)
  if [[ ! -f "$MARKER" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y iptables curl openssl ca-certificates sshpass >/dev/null 2>&1 || true
  else
    command -v sshpass >/dev/null 2>&1 || {
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y >/dev/null 2>&1 || true
      apt-get install -y sshpass >/dev/null 2>&1 || true
    }
  fi

  # basic guard
  if [[ "${DO_SSH_PASS}" == "CHANGE_ME" ]]; then
    echo "ERROR: Set DO_SSH_PASS in script first."
    exit 1
  fi

  case "${1:-}" in
    new)  rotate_new ;;
    show) show ;;
    "" )
      create_if_missing
      echo "GCORE IP: $(gcore_public_ip)"
      echo "DO EXIT : ${DO_IP}"
      echo "PORT    : $(current_port)"
      echo
      echo "=== KEY ==="
      show
      echo "==========="
      ;;
    *) echo "Usage: sudo bash $0 [new|show]"; exit 1 ;;
  esac
}

main "$@"
