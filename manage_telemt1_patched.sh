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
    val="${val//$'\r'/}"
    printf '%s' "${val:-$default}"
  else
    read -r -p "$prompt: " val
    val="${val//$'\r'/}"
    printf '%s' "$val"
  fi
}

ask_required() {
  local prompt="$1"
  local val=""
  while [ -z "$val" ]; do
    read -r -p "$prompt: " val
    val="${val//$'\r'/}"
    [ -n "$val" ] || echo "❌ Поле не может быть пустым"
  done
  printf '%s' "$val"
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  local answer
  local shown="[Y/n]"
  [ "$default" = "n" ] && shown="[y/N]"

  while true; do
    read -r -p "$prompt $shown: " answer
    answer="${answer//$'\r'/}"
    answer="${answer,,}"

    if [ -z "$answer" ]; then
      answer="$default"
    fi

    case "$answer" in
      y|yes) echo "yes"; return 0 ;;
      n|no) echo "no"; return 0 ;;
      *) echo "Введите y или n" ;;
    esac
  done
}

pause() {
  echo
  read -r -p "Нажми Enter, чтобы продолжить..." _
}

port_must_be_free() {
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

fetch_release_json() {
  local api_url="$1"
  curl -fsSL "$api_url"
}

release_asset_url() {
  local json="$1"
  local regex="$2"
  jq -r --arg re "$regex" '.assets[] | select(.browser_download_url | test($re)) | .browser_download_url' <<<"$json" | head -n1
}

release_asset_digest() {
  local json="$1"
  local regex="$2"
  jq -r --arg re "$regex" '.assets[] | select(.browser_download_url | test($re)) | .digest // empty' <<<"$json" | head -n1
}

download_release_asset_checked() {
  local api_url="$1"
  local asset_regex="$2"
  local out_file="$3"

  local json url digest expected actual
  json="$(fetch_release_json "$api_url")"

  url="$(release_asset_url "$json" "$asset_regex")"
  [ -n "$url" ] || { echo "❌ Не найден релизный файл по шаблону: $asset_regex"; exit 1; }

  digest="$(release_asset_digest "$json" "$asset_regex")"
  [ -n "$digest" ] || { echo "❌ Не найден SHA256 digest для: $asset_regex"; exit 1; }

  echo "⬇️  Скачиваем: $url"
  curl -fL "$url" -o "$out_file"

  expected="${digest#sha256:}"
  actual="$(sha256sum "$out_file" | awk '{print $1}')"

  if [ "$actual" != "$expected" ]; then
    echo "❌ SHA256 не совпал для $(basename "$out_file")"
    echo "Ожидалось: $expected"
    echo "Получено:  $actual"
    exit 1
  fi

  echo "✅ SHA256 совпал: $(basename "$out_file")"
}

install_stack() {
  echo "═════════════════════════════════════════════════════"
  echo " Установка Telemt + Panel"
  echo "═════════════════════════════════════════════════════"

  local MASK_DOMAIN GEOIP_CHOICE MM_ACCOUNT_ID="" MM_LICENSE_KEY=""
  MASK_DOMAIN="$(ask 'Под какой домен маскироваться' 'drive.google.com')"

  echo "ℹ️ Если хочешь GeoIP в панели (страна / город / ASN пользователей),"
  echo "   заранее нужен бесплатный аккаунт MaxMind GeoLite и License Key."
  echo "   Регистрация: https://dev.maxmind.com/geoip/geolite2-free-geolocation-data/"
  echo

  GEOIP_CHOICE="$(ask_yes_no 'Включить GeoIP для панели? (показывает страну/город/ASN пользователей)' 'y')"
  if [ "$GEOIP_CHOICE" = "yes" ]; then
    echo "ℹ️ Введи данные MaxMind:"
    MM_ACCOUNT_ID="$(ask_required 'MaxMind Account ID')"
    MM_LICENSE_KEY="$(ask_required 'MaxMind License Key')"
  else
    echo "ℹ️ GeoIP будет пропущен: Telemt и панель будут работать нормально,"
    echo "   просто в панели не будут показываться страна / город / ASN пользователей."
  fi

  local TELEMT_USER_NAME="hello"
  local TELEMT_SECRET
  TELEMT_SECRET="$(openssl rand -hex 16)"

  local PANEL_USER PANEL_PASS JWT_SECRET
  PANEL_USER="$(ask 'Логин для панели' 'admin')"
  PANEL_PASS="$(ask_required 'Пароль для панели')"
  JWT_SECRET="$(openssl rand -hex 32)"

  local TELEMT_BIN="/bin/telemt"
  local TELEMT_CONFIG_DIR="/etc/telemt"
  local TELEMT_CONFIG="${TELEMT_CONFIG_DIR}/telemt.toml"
  local TELEMT_SERVICE_FILE="/etc/systemd/system/telemt.service"

  local PANEL_BIN="/usr/local/bin/telemt-panel"
  local PANEL_CONFIG_DIR="/etc/telemt-panel"
  local PANEL_CONFIG="${PANEL_CONFIG_DIR}/config.toml"
  local PANEL_DATA_DIR="/var/lib/telemt-panel"
  local PANEL_SERVICE_FILE="/etc/systemd/system/telemt-panel.service"

  export DEBIAN_FRONTEND=noninteractive

  echo "📦 Обновляем индексы пакетов"
  apt update

  echo "📦 Ставим зависимости"
  apt install -y ca-certificates curl jq openssl tar

  if [ "$GEOIP_CHOICE" = "yes" ]; then
    apt install -y geoipupdate
  fi

  if systemctl list-unit-files | grep -q '^telemt\.service'; then
    systemctl stop telemt 2>/dev/null || true
  fi
  if systemctl list-unit-files | grep -q '^telemt-panel\.service'; then
    systemctl stop telemt-panel 2>/dev/null || true
  fi

  port_must_be_free 443
  port_must_be_free 8080
  port_must_be_free 9091

  local ARCH LIBC_KIND
  ARCH="$(detect_arch)"
  LIBC_KIND="$(detect_libc)"

  echo "📥 Скачиваем Telemt"
  local TMPDIR_TELEMT
  TMPDIR_TELEMT="$(mktemp -d)"
  download_release_asset_checked \
    "https://api.github.com/repos/telemt/telemt/releases/latest" \
    "telemt-${ARCH}-linux-${LIBC_KIND}\\.tar\\.gz$" \
    "${TMPDIR_TELEMT}/telemt.tar.gz"
  tar -xzf "${TMPDIR_TELEMT}/telemt.tar.gz" -C "${TMPDIR_TELEMT}"
  [ -f "${TMPDIR_TELEMT}/telemt" ] || { echo "❌ В архиве Telemt не найден бинарник"; exit 1; }
  install -m 0755 "${TMPDIR_TELEMT}/telemt" "${TELEMT_BIN}"
  rm -rf "${TMPDIR_TELEMT}"

  echo "👤 Создаём пользователя telemt"
  useradd -d /opt/telemt -m -r -U telemt 2>/dev/null || true
  mkdir -p "${TELEMT_CONFIG_DIR}"

  cat > "${TELEMT_CONFIG}" <<EOF2
[general]
use_middle_proxy = false
log_level = "normal"

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"

[server]
port = 443

[censorship]
tls_domain = "${MASK_DOMAIN}"
mask = true
tls_emulation = true

[access.users]
${TELEMT_USER_NAME} = "${TELEMT_SECRET}"

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32"]
minimal_runtime_enabled = false
minimal_runtime_cache_ttl_ms = 1000
EOF2

  chown -R telemt:telemt "${TELEMT_CONFIG_DIR}"
  chmod 750 "${TELEMT_CONFIG_DIR}"
  chmod 640 "${TELEMT_CONFIG}"

  cat > "${TELEMT_SERVICE_FILE}" <<'EOF2'
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
EOF2

  echo "🚀 Запускаем Telemt"
  systemctl daemon-reload
  systemctl enable --now telemt
  wait_service_active telemt || { systemctl status telemt --no-pager -l; exit 1; }

  echo "🧪 Проверяем API Telemt"
  curl -fsS http://127.0.0.1:9091/v1/users | jq >/dev/null

  echo "📥 Скачиваем Telemt Panel"
  local TMPDIR_PANEL PANEL_EXTRACTED
  TMPDIR_PANEL="$(mktemp -d)"
  download_release_asset_checked \
    "https://api.github.com/repos/amirotin/telemt_panel/releases/latest" \
    "telemt-panel-${ARCH}-linux-gnu\\.tar\\.gz$" \
    "${TMPDIR_PANEL}/telemt-panel.tar.gz"
  tar -xzf "${TMPDIR_PANEL}/telemt-panel.tar.gz" -C "${TMPDIR_PANEL}"
  PANEL_EXTRACTED="${TMPDIR_PANEL}/telemt-panel-${ARCH}-linux"
  [ -f "${PANEL_EXTRACTED}" ] || { echo "❌ В архиве панели не найден бинарник ${PANEL_EXTRACTED}"; ls -la "${TMPDIR_PANEL}"; exit 1; }
  install -m 0755 "${PANEL_EXTRACTED}" "${PANEL_BIN}"
  rm -rf "${TMPDIR_PANEL}"

  mkdir -p "${PANEL_CONFIG_DIR}" "${PANEL_DATA_DIR}"

  local GEOIP_OK=0
  if [ "$GEOIP_CHOICE" = "yes" ]; then
    echo "🌍 Настраиваем GeoIP"
    cat > /etc/GeoIP.conf <<EOF2
AccountID ${MM_ACCOUNT_ID}
LicenseKey ${MM_LICENSE_KEY}
EditionIDs GeoLite2-City GeoLite2-ASN
DatabaseDirectory ${PANEL_DATA_DIR}
EOF2

    if timeout 180 geoipupdate; then
      if [ -f "${PANEL_DATA_DIR}/GeoLite2-City.mmdb" ] && [ -f "${PANEL_DATA_DIR}/GeoLite2-ASN.mmdb" ]; then
        GEOIP_OK=1
        echo "✅ GeoIP базы скачаны"
      else
        echo "⚠️ geoipupdate завершился, но базы не найдены — продолжим без GeoIP"
      fi
    else
      echo "⚠️ GeoIP не скачался автоматически, продолжим без GeoIP"
    fi
  fi

  local PASS_HASH
  PASS_HASH="$(printf '%s\n' "${PANEL_PASS}" | "${PANEL_BIN}" hash-password)"

  if [ "${GEOIP_OK}" -eq 1 ]; then
    cat > "${PANEL_CONFIG}" <<EOF2
listen = "0.0.0.0:8080"

[telemt]
url = "http://127.0.0.1:9091"
auth_header = ""
binary_path = "/bin/telemt"
service_name = "telemt"
github_repo = "telemt/telemt"
config_path = "/etc/telemt/telemt.toml"

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
EOF2
  else
    cat > "${PANEL_CONFIG}" <<EOF2
listen = "0.0.0.0:8080"

[telemt]
url = "http://127.0.0.1:9091"
auth_header = ""
binary_path = "/bin/telemt"
service_name = "telemt"
github_repo = "telemt/telemt"
config_path = "/etc/telemt/telemt.toml"

[panel]
binary_path = "/usr/local/bin/telemt-panel"
service_name = "telemt-panel"
github_repo = "amirotin/telemt_panel"

[auth]
username = "${PANEL_USER}"
password_hash = "${PASS_HASH}"
jwt_secret = "${JWT_SECRET}"
session_ttl = "24h"
EOF2
  fi

  chmod 600 "${PANEL_CONFIG}"

  cat > "${PANEL_SERVICE_FILE}" <<'EOF2'
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
EOF2

  echo "🚀 Запускаем Telemt Panel"
  systemctl daemon-reload
  systemctl enable --now telemt-panel
  wait_service_active telemt-panel || { systemctl status telemt-panel --no-pager -l; exit 1; }

  if [ "${GEOIP_OK}" -eq 1 ]; then
    echo "⏰ Настраиваем автообновление GeoIP"
    cat > /etc/cron.d/telemt-panel-geoip <<'EOF2'
20 4 * * * root /usr/bin/geoipupdate >/var/log/geoipupdate.log 2>&1 && /bin/systemctl restart telemt-panel
EOF2
    chmod 644 /etc/cron.d/telemt-panel-geoip
  else
    rm -f /etc/cron.d/telemt-panel-geoip 2>/dev/null || true
    [ "$GEOIP_CHOICE" = "yes" ] || rm -f /etc/GeoIP.conf 2>/dev/null || true
  fi

  local PUB_IP
  PUB_IP="$(public_ip)"

  echo
  echo "═════════════════════════════════════════════════════"
  echo "✅ Готово"
  echo "Mask domain:    ${MASK_DOMAIN}"
  echo "Telemt user:    ${TELEMT_USER_NAME}"
  echo "Telemt secret:  ${TELEMT_SECRET}"
  if [ -n "${PUB_IP}" ]; then
    echo "Panel URL:      http://${PUB_IP}:8080"
  else
    echo "Не удалось определить внешний IP"
  fi
  echo "Panel login:    ${PANEL_USER}"
  echo "Panel password: ${PANEL_PASS}"

  if [ "$GEOIP_CHOICE" = "no" ]; then
    echo "GeoIP:          отключён вручную"
    echo "                всё будет работать, просто без страны / города / ASN в панели"
  elif [ "${GEOIP_OK}" -eq 0 ]; then
    echo "GeoIP:          не скачался автоматически, можно добить позже"
  else
    echo "GeoIP:          настроен"
  fi

  echo "─────────────────────────────────────────────────────"
  echo "Ссылки Telemt из API:"
  curl -fsS http://127.0.0.1:9091/v1/users | jq || true
  echo "═════════════════════════════════════════════════════"
}

delete_stack() {
  echo "═════════════════════════════════════════════════════"
  echo " Полное удаление Telemt + Panel"
  echo "═════════════════════════════════════════════════════"

  read -r -p "Точно удалить Telemt, telemt-panel, конфиги и GeoIP-файлы? [yes/no]: " confirm
  confirm="${confirm//$'\r'/}"
  [ "$confirm" = "yes" ] || { echo "Отменено"; return 0; }

  systemctl stop telemt-panel 2>/dev/null || true
  systemctl disable telemt-panel 2>/dev/null || true
  systemctl stop telemt 2>/dev/null || true
  systemctl disable telemt 2>/dev/null || true

  rm -f /etc/systemd/system/telemt-panel.service
  rm -f /etc/systemd/system/telemt.service

  rm -f /usr/local/bin/telemt-panel
  rm -f /bin/telemt

  rm -rf /etc/telemt-panel
  rm -rf /etc/telemt
  rm -rf /var/lib/telemt-panel

  rm -f /etc/cron.d/telemt-panel-geoip
  rm -f /etc/GeoIP.conf

  userdel -r telemt 2>/dev/null || true

  systemctl daemon-reload
  systemctl reset-failed telemt telemt-panel 2>/dev/null || true

  echo "✅ Telemt и панель удалены"
  echo "ℹ️ Пакеты curl/jq/geoipupdate не удалялись"
}

main_menu() {
  while true; do
    echo
    echo "═════════════════════════════════════════════════════"
    echo " 1) Установка Telemt + Panel"
    echo " 2) Полное удаление Telemt + Panel"
    echo " 0) Выход"
    echo "═════════════════════════════════════════════════════"
    read -r -p "Выберите пункт: " choice
    choice="${choice//$'\r'/}"

    case "$choice" in
      1)
        install_stack
        pause
        ;;
      2)
        delete_stack
        pause
        ;;
      0)
        exit 0
        ;;
      *)
        echo "Неверный выбор"
        ;;
    esac
  done
}

main_menu
