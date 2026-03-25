#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "❌ Ошибка на строке ${LINENO}" >&2' ERR

SCRIPT_NAME="$(basename "$0")"
WORK_DIR="/tmp/telemt-install.$$"
mkdir -p "$WORK_DIR"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

log()  { echo -e "\e[1;32m[INFO]\e[0m $*"; }
warn() { echo -e "\e[1;33m[WARN]\e[0m $*" >&2; }
err()  { echo -e "\e[1;31m[ERR ]\e[0m $*" >&2; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Запусти скрипт от root: sudo bash ${SCRIPT_NAME}"
    exit 1
  fi
}

ask() {
  local prompt="$1"
  local default="${2-}"
  local val
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " val || true
    val="${val//$'\r'/}"
    printf '%s' "${val:-$default}"
  else
    read -r -p "$prompt: " val || true
    val="${val//$'\r'/}"
    printf '%s' "$val"
  fi
}

ask_required() {
  local prompt="$1"
  local val=""
  while [[ -z "$val" ]]; do
    read -r -p "$prompt: " val || true
    val="${val//$'\r'/}"
    [[ -n "$val" ]] || echo "❌ Поле не может быть пустым"
  done
  printf '%s' "$val"
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  local answer
  local shown="[Y/n]"
  [[ "$default" == "n" ]] && shown="[y/N]"
  while true; do
    read -r -p "$prompt $shown: " answer || true
    answer="${answer//$'\r'/}"
    answer="${answer,,}"
    if [[ -z "$answer" ]]; then
      answer="$default"
    fi
    case "$answer" in
      y|yes|д|да) echo "yes"; return 0 ;;
      n|no|н|нет) echo "no"; return 0 ;;
      *) echo "Введите y или n" ;;
    esac
  done
}

pause() {
  echo
  read -r -p "Нажми Enter, чтобы продолжить..." _ || true
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

fetch_latest_release_json() {
  local repo="$1"
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${repo}/releases/latest"
}

select_asset() {
  local release_json="$1"
  local regex="$2"
  echo "$release_json" | jq -r --arg re "$regex" '
    .assets[]
    | select(.name | test($re))
    | [.name, .browser_download_url, (.digest // "")]
    | @tsv
  ' | head -n1
}

download_and_verify() {
  local url="$1"
  local digest="$2"
  local out="$3"

  curl -fL "$url" -o "$out"

  if [[ -n "$digest" && "$digest" != "null" ]]; then
    if [[ "$digest" =~ ^sha256:([a-fA-F0-9]{64})$ ]]; then
      local expected="${BASH_REMATCH[1]}"
      local actual
      actual="$(sha256sum "$out" | awk '{print $1}')"
      if [[ "$actual" != "$expected" ]]; then
        err "SHA256 не совпал для $(basename "$out")"
        err "Ожидалось: $expected"
        err "Получено : $actual"
        exit 1
      fi
      log "SHA256 OK: $(basename "$out")"
    else
      warn "Неизвестный формат digest '$digest', проверку пропускаю"
    fi
  else
    warn "GitHub не вернул digest для $(basename "$out"), проверку пропускаю"
  fi
}

install_telemt_binary() {
  local release_json asset name url digest archive extract_dir
  release_json="$(fetch_latest_release_json "telemt/telemt")"

  asset="$(select_asset "$release_json" "^telemt-${ARCH}-linux-${LIBC_KIND}\\.tar\\.gz$")"
  if [[ -z "$asset" ]]; then
    asset="$(select_asset "$release_json" "^telemt-${ARCH}-linux-gnu\\.tar\\.gz$")"
  fi
  if [[ -z "$asset" ]]; then
    asset="$(select_asset "$release_json" "^telemt-${ARCH}-linux-musl\\.tar\\.gz$")"
  fi
  if [[ -z "$asset" ]]; then
    err "Не найден архив telemt под архитектуру ${ARCH}"
    exit 1
  fi

  IFS=$'\t' read -r name url digest <<<"$asset"
  archive="$WORK_DIR/$name"
  extract_dir="$WORK_DIR/telemt"

  log "Скачиваю telemt: $name"
  download_and_verify "$url" "$digest" "$archive"

  mkdir -p "$extract_dir"
  tar -xzf "$archive" -C "$extract_dir"

  if [[ ! -f "$extract_dir/telemt" ]]; then
    err "В архиве telemt не найден бинарник"
    exit 1
  fi

  install -m 0755 "$extract_dir/telemt" /bin/telemt
  /bin/telemt --version || true
}

install_panel_binary() {
  local release_json asset name url digest archive extract_dir bin_path
  release_json="$(fetch_latest_release_json "amirotin/telemt_panel")"

  asset="$(select_asset "$release_json" "^telemt-panel-${ARCH}-linux-gnu\\.tar\\.gz$")"
  if [[ -z "$asset" ]]; then
    err "Не найден архив telemt-panel под архитектуру ${ARCH}"
    exit 1
  fi

  IFS=$'\t' read -r name url digest <<<"$asset"
  archive="$WORK_DIR/$name"
  extract_dir="$WORK_DIR/panel"

  log "Скачиваю telemt-panel: $name"
  download_and_verify "$url" "$digest" "$archive"

  mkdir -p "$extract_dir"
  tar -xzf "$archive" -C "$extract_dir"

  bin_path="$(find "$extract_dir" -maxdepth 2 -type f -name 'telemt-panel*linux*' | head -n1 || true)"
  if [[ -z "$bin_path" ]]; then
    err "В архиве telemt-panel не найден бинарник"
    exit 1
  fi

  install -m 0755 "$bin_path" /usr/local/bin/telemt-panel
  /usr/local/bin/telemt-panel version || true
}

generate_panel_hash() {
  local output
  output="$(printf '%s\n' "$PANEL_PASS" | /usr/local/bin/telemt-panel hash-password 2>/dev/null | tr -d '\r' || true)"
  PANEL_HASH="$(printf '%s\n' "$output" | grep -E '^\$2[aby]\$' | tail -n1 || true)"
  if [[ -z "${PANEL_HASH:-}" ]]; then
    err "Не удалось получить bcrypt-хеш через telemt-panel hash-password"
    exit 1
  fi
}

write_geoip_conf() {
  cat > /etc/GeoIP.conf <<EOF
AccountID ${MM_ACCOUNT_ID}
LicenseKey ${MM_LICENSE_KEY}
EditionIDs GeoLite2-City GeoLite2-ASN
DatabaseDirectory /usr/share/GeoIP
EOF
  chmod 600 /etc/GeoIP.conf
}

install_geoip() {
  GEOIP_OK=0
  rm -f /etc/cron.d/telemt-panel-geoip 2>/dev/null || true

  if [[ "$GEOIP_CHOICE" != "yes" ]]; then
    rm -f /etc/GeoIP.conf 2>/dev/null || true
    return 0
  fi

  log "Настраиваю GeoIP"
  mkdir -p /usr/share/GeoIP
  write_geoip_conf

  if geoipupdate >/dev/null 2>&1; then
    GEOIP_OK=1
    cat > /etc/cron.d/telemt-panel-geoip <<'EOF'
20 4 * * * root /usr/bin/geoipupdate >/var/log/geoipupdate.log 2>&1 && /bin/systemctl restart telemt-panel
EOF
    chmod 644 /etc/cron.d/telemt-panel-geoip
  else
    warn "GeoIP не скачался автоматически. Панель встанет без геобаз, можно добить позже командой: geoipupdate"
  fi
}

write_telemt_config() {
  mkdir -p /etc/telemt /var/lib/telemt/tlsfront
  cat > /etc/telemt/telemt.toml <<EOF
[general]
use_middle_proxy = false
log_level = "normal"

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"
public_host = "${PUB_IP}"
public_port = 443

[server]
port = 443

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32"]

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain = "${MASK_DOMAIN}"
mask = true
tls_emulation = true
tls_front_dir = "/var/lib/telemt/tlsfront"

[access.users]
hello = "${TELEMT_SECRET}"
EOF
  chown -R telemt:telemt /etc/telemt /var/lib/telemt /opt/telemt
  chmod 750 /etc/telemt
  chmod 640 /etc/telemt/telemt.toml
}

write_panel_config() {
  mkdir -p /etc/telemt-panel /var/lib/telemt-panel
  cat > /etc/telemt-panel/config.toml <<EOF
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
password_hash = "${PANEL_HASH}"
jwt_secret = "${JWT_SECRET}"
session_ttl = "24h"
EOF

  if [[ "$GEOIP_CHOICE" == "yes" ]]; then
    cat >> /etc/telemt-panel/config.toml <<'EOF'

[geoip]
db_path = "/usr/share/GeoIP/GeoLite2-City.mmdb"
asn_db_path = "/usr/share/GeoIP/GeoLite2-ASN.mmdb"
EOF
  fi

  chmod 600 /etc/telemt-panel/config.toml
}

write_telemt_service() {
  cat > /etc/systemd/system/telemt.service <<'EOF'
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
}

write_panel_service() {
  cat > /etc/systemd/system/telemt-panel.service <<'EOF'
[Unit]
Description=Telemt Panel
After=network.target telemt.service
Wants=telemt.service

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
}

show_proxy_links_from_api() {
  local users_json
  users_json="$(curl -fsS http://127.0.0.1:9091/v1/users 2>/dev/null || true)"
  if [[ -z "$users_json" ]]; then
    warn "API telemt пока не ответил. Проверь: journalctl -u telemt -n 100 --no-pager"
    return 0
  fi

  echo "$users_json" | jq . || echo "$users_json"
  echo
  echo "Proxy-ссылки из API:"
  echo "$users_json" | jq -r '.. | strings | select(startswith("tg://proxy") or startswith("https://t.me/proxy"))' 2>/dev/null || true
}

install_stack() {
  echo "═════════════════════════════════════════════════════"
  echo " Установка Telemt + Panel"
  echo "═════════════════════════════════════════════════════"

  require_root

  MASK_DOMAIN="$(ask 'Под какой домен маскироваться' 'drive.google.com')"
  echo "ℹ️ Если хочешь GeoIP в панели (страна / город / ASN пользователей),"
  echo "   нужен бесплатный аккаунт MaxMind GeoLite и License Key."
  echo "   Регистрация: https://dev.maxmind.com/geoip/geolite2-free-geolocation-data/"
  GEOIP_CHOICE="$(ask_yes_no 'Включить GeoIP для панели? (показывает страну/город/ASN пользователей)' 'y')"

  MM_ACCOUNT_ID=""
  MM_LICENSE_KEY=""
  if [[ "$GEOIP_CHOICE" == "yes" ]]; then
    echo "ℹ️ Введи данные MaxMind:"
    MM_ACCOUNT_ID="$(ask_required 'MaxMind Account ID')"
    MM_LICENSE_KEY="$(ask_required 'MaxMind License Key')"
  else
    echo "ℹ️ GeoIP будет пропущен: Telemt и панель будут работать нормально,"
    echo "   просто в панели не будут показываться страна / город / ASN пользователей."
  fi

  PANEL_USER="$(ask 'Логин для панели' 'admin')"
  PANEL_PASS="$(ask_required 'Пароль для панели')"
  TELEMT_SECRET="$(openssl rand -hex 16)"
  JWT_SECRET="$(openssl rand -hex 32)"
  PUB_IP="$(public_ip)"
  if [[ -z "$PUB_IP" ]]; then
    PUB_IP="$(ask_required 'Не удалось определить внешний IP. Введи IP сервера')"
  fi

  export DEBIAN_FRONTEND=noninteractive
  echo " Обновляем индекс пакетов"
  apt update

  echo " Ставим зависимости"
  apt install -y ca-certificates curl jq openssl tar xz-utils python3 ufw
  if [[ "$GEOIP_CHOICE" == "yes" ]]; then
    apt install -y geoipupdate
  fi

  systemctl stop telemt 2>/dev/null || true
  systemctl stop telemt-panel 2>/dev/null || true

  port_must_be_free 443
  port_must_be_free 8080
  port_must_be_free 9091

  ARCH="$(detect_arch)"
  LIBC_KIND="$(detect_libc)"

  echo " Скачиваем Telemt"
  install_telemt_binary

  echo " Создаём пользователя telemt"
  useradd -d /opt/telemt -m -r -U -s /usr/sbin/nologin telemt 2>/dev/null || true
  mkdir -p /opt/telemt

  echo " Генерируем хеш пароля панели"
  install_panel_binary
  generate_panel_hash

  echo " Пишем конфиги"
  write_telemt_config
  install_geoip
  write_panel_config

  echo " Пишем systemd-сервисы"
  write_telemt_service
  write_panel_service

  echo " Запускаем Telemt"
  systemctl daemon-reload
  systemctl enable --now telemt
  wait_service_active telemt || { systemctl status telemt --no-pager -l; exit 1; }

  echo " Проверяем API Telemt"
  curl -fsS http://127.0.0.1:9091/v1/users | jq >/dev/null

  echo " Запускаем Telemt Panel"
  systemctl enable --now telemt-panel
  wait_service_active telemt-panel || { systemctl status telemt-panel --no-pager -l; exit 1; }

  if command -v ufw >/dev/null 2>&1; then
    ufw allow 22/tcp >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
    ufw allow 8080/tcp >/dev/null 2>&1 || true
  fi

  echo
  echo "═════════════════════════════════════════════════════"
  echo "✅ Готово"
  echo "Mask domain   : ${MASK_DOMAIN}"
  echo "Panel URL     : http://${PUB_IP}:8080"
  echo "Panel login   : ${PANEL_USER}"
  echo "Panel password: ${PANEL_PASS}"
  echo "Telemt secret : ${TELEMT_SECRET}"
  if [[ "$GEOIP_CHOICE" == "no" ]]; then
    echo "GeoIP         : отключён вручную"
    echo "               всё будет работать, просто без страны / города / ASN в панели"
  elif [[ "${GEOIP_OK:-0}" -eq 1 ]]; then
    echo "GeoIP         : настроен"
  else
    echo "GeoIP         : не скачался автоматически, можно добить позже командой: geoipupdate"
  fi
  echo "═════════════════════════════════════════════════════"
  echo

  echo "Пользователи telemt через API:"
  show_proxy_links_from_api
}

delete_stack() {
  echo "═════════════════════════════════════════════════════"
  echo " Полное удаление Telemt + Panel"
  echo "═════════════════════════════════════════════════════"

  require_root

  read -r -p "Точно удалить Telemt, telemt-panel, конфиги и GeoIP-файлы? [yes/no]: " confirm || true
  confirm="${confirm//$'\r'/}"
  [[ "$confirm" == "yes" ]] || { echo "Отменено"; return 0; }

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
  rm -rf /var/lib/telemt
  rm -f /etc/cron.d/telemt-panel-geoip
  rm -f /etc/GeoIP.conf
  userdel -r telemt 2>/dev/null || true

  systemctl daemon-reload
  systemctl reset-failed telemt telemt-panel 2>/dev/null || true

  echo "✅ Telemt и панель удалены"
  echo "ℹ️ Пакеты curl/jq/python3/geoipupdate не удалялись"
}

main_menu() {
  while true; do
    echo
    echo "═════════════════════════════════════════════════════"
    echo " 1) Установка Telemt + Panel"
    echo " 2) Полное удаление Telemt + Panel"
    echo " 0) Выход"
    echo "═════════════════════════════════════════════════════"
    read -r -p "Выберите пункт: " choice || true
    choice="${choice//$'\r'/}"

    case "$choice" in
      1) install_stack; pause ;;
      2) delete_stack; pause ;;
      0) exit 0 ;;
      *) echo "Неверный выбор" ;;
    esac
  done
}

main_menu
