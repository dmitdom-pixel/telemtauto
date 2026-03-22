#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "❌ Ошибка на строке $LINENO"; exit 1' ERR

[ "$(id -u)" -eq 0 ] || { echo "Запусти скрипт от root"; exit 1; }

ask() {
  local prompt="$1"
  local default="${2-}"
  local val
  if [ -n "$default" ]; then
    read -r -p "$prompt [$default]: " val
    printf '%s' "${val:-$default}"
  else
    read -r -p "$prompt: " val
    printf '%s' "$val"
  fi
}

ask_secret() {
  local prompt="$1"
  local val
  read -r -s -p "$prompt: " val
  echo
  printf '%s' "$val"
}

need_port_free() {
  local port="$1"
  if ss -ltnp 2>/dev/null | grep -q ":${port}\b"; then
    echo "❌ Порт ${port} уже занят:"
    ss -ltnp 2>/dev/null | grep ":${port}\b" || true
    exit 1
  fi
}

wait_service_active() {
  local svc="$1"
  local i
  for i in $(seq 1 30); do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

detect_arch() {
  case "$(uname -m)" in
    x86_64) echo "x86_64" ;;
    aarch64|arm64) echo "aarch64" ;;
    *)
      echo "❌ Неподдерживаемая архитектура: $(uname -m)"
      exit 1
      ;;
  esac
}

detect_libc() {
  if ldd --version 2>&1 | grep -qi musl; then
    echo "musl"
  else
    echo "gnu"
  fi
}

public_ip() {
  curl -4fsS ifconfig.me 2>/dev/null || curl -4fsS ipinfo.io/ip 2>/dev/null || true
}

echo "═════════════════════════════════════════════════════"
echo " Telemt + Panel + GeoIP installer"
echo "═════════════════════════════════════════════════════"

MASK_DOMAIN="$(ask 'Под какой домен маскироваться' 'drive.google.com')"
MM_ACCOUNT_ID="$(ask 'MaxMind Account ID')"
MM_LICENSE_KEY="$(ask_secret 'MaxMind License Key')"

TELEMT_USER_NAME="hello"
TELEMT_SECRET="$(openssl rand -hex 16)"
PANEL_USER="admin"
PANEL_PASS="$(openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-20)"
JWT_SECRET="$(openssl rand -hex 32)"

TELEMT_BIN="/bin/telemt"
TELEMT_CONFIG_DIR="/etc/telemt"
TELEMT_CONFIG="${TELEMT_CONFIG_DIR}/telemt.toml"
TELEMT_SERVICE_FILE="/etc/systemd/system/telemt.service"

PANEL_BIN="/usr/local/bin/telemt-panel"
PANEL_CONFIG_DIR="/etc/telemt-panel"
PANEL_CONFIG="${PANEL_CONFIG_DIR}/config.toml"
PANEL_DATA_DIR="/var/lib/telemt-panel"
PANEL_SERVICE_FILE="/etc/systemd/system/telemt-panel.service"

echo "📦 Обновляем Ubuntu в рамках текущей версии"
export DEBIAN_FRONTEND=noninteractive
apt update
apt upgrade -y
apt autoremove -y
apt clean

echo "📦 Ставим зависимости"
apt install -y \
  ca-certificates curl jq openssl python3 tar xz-utils \
  geoipupdate xxd

need_port_free 443
need_port_free 8080
need_port_free 9091

ARCH="$(detect_arch)"
LIBC_KIND="$(detect_libc)"

echo "📥 Скачиваем Telemt"
TMPDIR_TELEMT="$(mktemp -d)"
curl -fL "https://github.com/telemt/telemt/releases/latest/download/telemt-${ARCH}-linux-${LIBC_KIND}.tar.gz" -o "${TMPDIR_TELEMT}/telemt.tar.gz"
tar -xzf "${TMPDIR_TELEMT}/telemt.tar.gz" -C "${TMPDIR_TELEMT}"
[ -f "${TMPDIR_TELEMT}/telemt" ] || { echo "❌ В архиве Telemt не найден бинарник"; exit 1; }
install -m 0755 "${TMPDIR_TELEMT}/telemt" "${TELEMT_BIN}"
rm -rf "${TMPDIR_TELEMT}"

echo "👤 Создаём пользователя telemt"
useradd -d /opt/telemt -m -r -U telemt 2>/dev/null || true
mkdir -p "${TELEMT_CONFIG_DIR}"

cat > "${TELEMT_CONFIG}" <<EOF
[general]
fast_mode = true
use_middle_proxy = true
me2dc_fallback = true
proxy_secret_path = "proxy-secret"
log_level = "normal"

middle_proxy_nat_probe = true
middle_proxy_nat_stun = "stun.l.google.com:19302"
middle_proxy_nat_stun_servers = ["stun1.l.google.com:19302", "stun2.l.google.com:19302"]

middle_proxy_pool_size = 8
middle_proxy_warm_standby = 4

me_keepalive_enabled = true
me_keepalive_interval_secs = 25
me_keepalive_jitter_secs = 5
me_keepalive_payload_random = true

me_warmup_stagger_enabled = true
me_warmup_step_delay_ms = 500
me_warmup_step_jitter_ms = 300

me_reconnect_backoff_base_ms = 500
me_reconnect_backoff_cap_ms = 30000
me_reconnect_fast_retry_count = 8

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"

[network]
ipv4 = true
ipv6 = false
prefer = 4
multipath = false

[server]
port = 443
listen_addr_ipv4 = "0.0.0.0"

[timeouts]
client_handshake = 15
tg_connect = 10
client_keepalive = 60
client_ack = 300
me_one_retry = 8
me_one_timeout_ms = 1200

[censorship]
tls_domain = "${MASK_DOMAIN}"
tls_emulation = true
mask = true
mask_port = 443

[access]
replay_check_len = 65536
replay_window_secs = 1800
ignore_time_skew = false

[access.users]
${TELEMT_USER_NAME} = "${TELEMT_SECRET}"

[[upstreams]]
type = "direct"
enabled = true
weight = 10

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.0/8"]
minimal_runtime_enabled = false
minimal_runtime_cache_ttl_ms = 1000
EOF

chown -R telemt:telemt "${TELEMT_CONFIG_DIR}"
chmod 750 "${TELEMT_CONFIG_DIR}"
chmod 640 "${TELEMT_CONFIG}"

cat > "${TELEMT_SERVICE_FILE}" <<'EOF'
[Unit]
Description=Telemt
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=/opt/telemt
ExecStart=/bin/telemt /etc/telemt/telemt.toml
Restart=on-failure
RestartSec=2
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

echo "🚀 Запускаем Telemt"
systemctl daemon-reload
systemctl enable --now telemt
wait_service_active telemt || { systemctl status telemt --no-pager -l; exit 1; }

echo "🧪 Проверяем API Telemt"
curl -fsS http://127.0.0.1:9091/v1/users | jq >/dev/null

echo "📥 Скачиваем Telemt Panel"
PANEL_JSON="$(curl -fsSL https://api.github.com/repos/amirotin/telemt_panel/releases/latest)"
PANEL_TAG="$(printf '%s' "$PANEL_JSON" | jq -r '.tag_name')"
PANEL_URL="$(printf '%s' "$PANEL_JSON" | jq -r --arg a "$ARCH" '.assets[]?.browser_download_url | select(test("telemt-panel-" + $a + "-linux-gnu\\.tar\\.gz$"))' | head -n1)"
[ -n "$PANEL_URL" ] || { echo "❌ Не удалось найти бинарник telemt-panel под $ARCH"; exit 1; }

TMPDIR_PANEL="$(mktemp -d)"
curl -fL "$PANEL_URL" -o "${TMPDIR_PANEL}/telemt-panel.tar.gz"
tar -xzf "${TMPDIR_PANEL}/telemt-panel.tar.gz" -C "${TMPDIR_PANEL}"
[ -f "${TMPDIR_PANEL}/telemt-panel" ] || { echo "❌ В архиве панели не найден бинарник"; exit 1; }
install -m 0755 "${TMPDIR_PANEL}/telemt-panel" "${PANEL_BIN}"
rm -rf "${TMPDIR_PANEL}"

mkdir -p "${PANEL_CONFIG_DIR}" "${PANEL_DATA_DIR}"

echo "🌍 Настраиваем GeoIP"
cat > /etc/GeoIP.conf <<EOF
AccountID ${MM_ACCOUNT_ID}
LicenseKey ${MM_LICENSE_KEY}
EditionIDs GeoLite2-City GeoLite2-ASN
DatabaseDirectory ${PANEL_DATA_DIR}
EOF

timeout 300 geoipupdate

PASS_HASH="$("${PANEL_BIN}" hash-password "${PANEL_PASS}")"

cat > "${PANEL_CONFIG}" <<EOF
listen = "0.0.0.0:8080"

[telemt]
url = "http://127.0.0.1:9091"
auth_header = ""
binary_path = "/bin/telemt"
service_name = "telemt"

[panel]
binary_path = "/usr/local/bin/telemt-panel"
service_name = "telemt-panel"
github_repo = "amirotin/telemt_panel"

[geoip]
db_path = "/var/lib/telemt-panel/GeoLite2-City.mmdb"
asn_db_path = "/var/lib/telemt-panel/GeoLite2-ASN.mmdb"

[auth]
username = "${PANEL_USER}"
password_hash = "${PASS_HASH}"
jwt_secret = "${JWT_SECRET}"
session_ttl = "24h"
EOF

chmod 600 "${PANEL_CONFIG}"

cat > "${PANEL_SERVICE_FILE}" <<'EOF'
[Unit]
Description=Telemt Panel
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/telemt-panel --config /etc/telemt-panel/config.toml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
NoNewPrivileges=true
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

echo "🚀 Запускаем Telemt Panel"
systemctl daemon-reload
systemctl enable --now telemt-panel
wait_service_active telemt-panel || { systemctl status telemt-panel --no-pager -l; exit 1; }

echo "⏰ Настраиваем автообновление GeoIP"
cat > /etc/cron.d/telemt-panel-geoip <<'EOF'
20 4 * * * root /usr/bin/geoipupdate >/var/log/geoipupdate.log 2>&1 && /bin/systemctl restart telemt-panel
EOF
chmod 644 /etc/cron.d/telemt-panel-geoip

PUB_IP="$(public_ip)"
HEX_DOMAIN="$(printf '%s' "${MASK_DOMAIN}" | xxd -p -c 999 | tr -d '\n')"

echo
echo "═════════════════════════════════════════════════════"
echo "✅ Готово"
echo "Mask domain:    ${MASK_DOMAIN}"
echo "Telemt user:    ${TELEMT_USER_NAME}"
echo "Telemt secret:  ${TELEMT_SECRET}"
if [ -n "${PUB_IP}" ]; then
  echo "TG link:        tg://proxy?server=${PUB_IP}&port=443&secret=ee${TELEMT_SECRET}${HEX_DOMAIN}"
  echo "T.ME link:      https://t.me/proxy?server=${PUB_IP}&port=443&secret=ee${TELEMT_SECRET}${HEX_DOMAIN}"
  echo "Panel URL:      http://${PUB_IP}:8080"
else
  echo "Не удалось определить внешний IP"
fi
echo "Panel login:    ${PANEL_USER}"
echo "Panel password: ${PANEL_PASS}"
echo "═════════════════════════════════════════════════════"
