#!/usr/bin/env bash
set -euo pipefail

# ====== SETTINGS ======
DO_IP="161.35.213.138"              # DigitalOcean exit
METHOD="chacha20-ietf-poly1305"
PORT_MIN=1024
PORT_MAX=10000
PASS_LEN=32

CFG="/etc/shadowsocks-libev/config.json"
OUTDIR="/root/ss_keys"
LAST="${OUTDIR}/current.txt"
UNIT="shadowsocks-libev-server@config"
MARKER="/var/lib/ssmgr/installed"

FW_RULES="/etc/iptables/ss-do-forward.rules"
FW_SERVICE="/etc/systemd/system/ss-do-forward.service"

need_root(){ [[ ${EUID} -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }; }
ensure_dirs(){ mkdir -p "$OUTDIR" "$(dirname "$MARKER")" /etc/iptables; }

installed_ok(){ [[ -f "$MARKER" ]] && command -v ss-server >/dev/null 2>&1; }

install_once(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y shadowsocks-libev openssl curl ca-certificates iptables python3 >/dev/null
  date -Is > "$MARKER"
}

# ---- net helpers ----
iface_default(){ ip -4 route list default 2>/dev/null | awk '{print $5; exit}' || echo "eth0"; }
public_ip(){ curl -4 -s --max-time 3 https://api.ipify.org || true; }

# ---- ss key helpers ----
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

b64url_nopad(){ base64 -w 0 | tr '+/' '-_' | tr -d '='; }
urlencode_min(){ local s="$1"; s="${s// /%20}"; s="${s//#/%23}"; echo "$s"; }

make_links(){
  local host="$1" port="$2" pass="$3" tag="${4:-ss}"
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
  cat > "$CFG" <<EOF
{
  "server":["0.0.0.0"],
  "server_port": ${port},
  "password":"${pass}",
  "timeout":300,
  "udp_timeout": 60,
  "method":"${METHOD}",
  "fast_open": true,
  "reuse_port": true,
  "mode":"tcp_and_udp"
}
EOF
}

restart_service(){
  systemctl enable --now "$UNIT" >/dev/null 2>&1 || true
  systemctl restart "$UNIT"
}

# ---- iptables helpers (NO FLUSH) ----
ipt_add(){
  local table="$1"; shift
  local chain="$1"; shift
  if iptables -t "$table" -C "$chain" "$@" >/dev/null 2>&1; then return 0; fi
  iptables -t "$table" -A "$chain" "$@"
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

apply_forward_rules(){
  local port="$1"
  local iface="$2"

  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ss-do-forward.conf

  # Gcore incoming PORT -> DO:PORT (TCP+UDP)
  ipt_add nat PREROUTING -i "$iface" -p tcp --dport "$port" -j DNAT --to-destination "${DO_IP}:${port}"
  ipt_add nat PREROUTING -i "$iface" -p udp --dport "$port" -j DNAT --to-destination "${DO_IP}:${port}"

  # Allow forwarding (basic)
  ipt_add filter FORWARD -i "$iface" -p tcp -d "$DO_IP" --dport "$port" -j ACCEPT
  ipt_add filter FORWARD -i "$iface" -p udp -d "$DO_IP" --dport "$port" -j ACCEPT
  ipt_add filter FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  # Outbound masquerade (exit looks like DO)
  ipt_add nat POSTROUTING -j MASQUERADE

  iptables-save > "$FW_RULES"
  ensure_fw_service
  systemctl start ss-do-forward.service >/dev/null 2>&1 || true
}

# ---- high level actions ----
create_key_if_missing(){
  if [[ -f "$LAST" && -f "$CFG" ]]; then
    return 0
  fi
  local host port pass legacy sip002
  host="$(public_ip)"; [[ -n "$host" ]] || host="$(hostname -I | awk '{print $1}')"
  port="$(rand_port)"
  pass="$(rand_pass)"
  write_config "$port" "$pass"
  restart_service

  read -r legacy sip002 < <(make_links "$host" "$port" "$pass" "ss")

  cat > "$LAST" <<EOF
METHOD=${METHOD}
PORT=${port}
PASSWORD=${pass}
LEGACY=${legacy}
SIP002=${sip002}
EOF
}

rotate_key(){
  local host port pass legacy sip002 iface
  host="$(public_ip)"; [[ -n "$host" ]] || host="$(hostname -I | awk '{print $1}')"
  port="$(rand_port)"
  pass="$(rand_pass)"
  write_config "$port" "$pass"
  restart_service

  read -r legacy sip002 < <(make_links "$host" "$port" "$pass" "ss")

  cat > "$LAST" <<EOF
METHOD=${METHOD}
PORT=${port}
PASSWORD=${pass}
LEGACY=${legacy}
SIP002=${sip002}
EOF

  iface="$(iface_default)"
  apply_forward_rules "$port" "$iface"

  echo
  echo "=== COPY ==="
  echo "$legacy"
  echo "$sip002"
  echo "==========="
  echo
}

show_status(){
  local port iface
  port="$(awk -F= '/^PORT=/{print $2; exit}' "$LAST" 2>/dev/null || true)"
  iface="$(iface_default)"
  echo "GCORE SS IP : $(public_ip)"
  echo "DO EXIT IP  : ${DO_IP}"
  echo "PORT        : ${port:-?}"
  echo "IFACE       : ${iface}"
  echo "SS SERVICE  : $(systemctl is-active "$UNIT" 2>/dev/null || echo unknown)"
  echo "FWD SERVICE : $(systemctl is-active ss-do-forward.service 2>/dev/null || echo unknown)"
}

apply_forward_from_current(){
  local port iface
  port="$(awk -F= '/^PORT=/{print $2; exit}' "$LAST" 2>/dev/null || true)"
  [[ -n "$port" ]] || { echo "No PORT. Create key first."; exit 1; }
  iface="$(iface_default)"
  apply_forward_rules "$port" "$iface"
}

main(){
  need_root
  ensure_dirs

  # auto install once
  if [[ "${1:-}" != "install" ]] && ! installed_ok; then
    install_once
  fi

  case "${1:-}" in
    install)
      install_once
      ;;
    new)
      # new key + apply forward immediately
      rotate_key
      ;;
    forward)
      # just (re)apply forward for current port
      apply_forward_from_current
      ;;
    "")
      # normal run: ensure key exists, ensure forward exists, show key (no rotate)
      create_key_if_missing
      apply_forward_from_current
      show_status
      echo "--- KEY ---"
      grep -E '^(LEGACY=|SIP002=)' "$LAST" | cut -d= -f2-
      echo "----------"
      ;;
    *)
      echo "Usage: sudo bash $0 [install|new|forward]"
      exit 1
      ;;
  esac
}

main "$@"
