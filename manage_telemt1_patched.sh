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
    err "Запусти скрипт от root: sudo bash $SCRIPT_NAME"
    exit 1
  fi
}

prompt() {
  local var_name="$1"
  local text="$2"
  local default_value="${3:-}"
  local value

  if [[ -n "$default_value" ]]; then
    read -r -p "$text [$default_value]: " value || true
    value="${value:-$default_value}"
  else
    read -r -p "$text: " value || true
  fi

  printf -v "$var_name" '%s' "$value"
}

confirm() {
  local text="$1"
  local default="${2:-N}"
  local answer
  read -r -p "$text [$default]: " answer || true
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[YyДд]$ ]]
}

detect_arch() {
  case "$(uname -m)" in
    x86_64) TELEMT_ARCH="x86_64"; PANEL_ARCH="x86_64" ;;
    aarch64|arm64) TELEMT_ARCH="aarch64"; PANEL_ARCH="aarch64" ;;
    *)
      err "Неподдерживаемая архитектура: $(uname -m)"
      exit 1
      ;;
  esac
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  log "Обновляю индекс пакетов"
  apt update

  log "Ставлю зависимости"
  apt install -y curl jq tar ca-certificates openssl ufw
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

  asset="$(select_asset "$release_json" "^telemt-${TELEMT_ARCH}-linux-gnu\\.tar\\.gz$")"
  if [[ -z "$asset" ]]; then
    asset="$(select_asset "$release_json" "^telemt-${TELEMT_ARCH}-linux-musl\\.tar\\.gz$")"
  fi
  if [[ -z "$asset" ]]; then
    err "Не найден архив telemt под архитектуру ${TELEMT_ARCH}"
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

  asset="$(select_asset "$release_json" "^telemt-panel-${PANEL_ARCH}-linux-gnu\\.tar\\.gz$")"
  if [[ -z "$asset" ]]; then
    err "Не найден архив telemt-panel под архитектуру ${PANEL_ARCH}"
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

create_user_and_dirs() {
  if ! id telemt >/dev/null 2>&1; then
    useradd -d /opt/telemt -m -r -U -s /usr/sbin/nologin telemt
  fi

  mkdir -p /opt/telemt /etc/telemt /etc/telemt-panel /var/lib/telemt/tlsfront
  chown -R telemt:telemt /opt/telemt /var/lib/telemt /etc/telemt
  chmod 750 /etc/telemt
  chmod 700 /etc/telemt-panel
}

generate_values() {
  PANEL_USER="admin"
  TELEMT_SECRET="$(openssl rand -hex 16)"
  PANEL_PASSWORD="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 16)"
  JWT_SECRET="$(openssl rand -hex 32)"

  if [[ -z "${PUBLIC_IP:-}" ]]; then
    PUBLIC_IP="$(curl -4 -fsSL https://api.ipify.org || true)"
  fi

  if [[ -z "${PUBLIC_IP:-}" ]]; then
    prompt PUBLIC_IP "Не удалось автоопределить внешний IP. Введи IP сервера"
  fi

  prompt MASK_DOMAIN "Домен для маскировки telemt" "ya.ru"
}

generate_panel_hash() {
  local output
  output="$(printf '%s\n' "$PANEL_PASSWORD" | /usr/local/bin/telemt-panel hash-password 2>/dev/null | tr -d '\r' || true)"
  PANEL_HASH="$(printf '%s\n' "$output" | grep -E '^\$2[aby]\$' | tail -n1 || true)"

  if [[ -z "$PANEL_HASH" ]]; then
    err "Не удалось получить bcrypt-хеш через telemt-panel hash-password"
    exit 1
  fi
}

write_telemt_config() {
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
public_host = "${PUBLIC_IP}"
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
main = "${TELEMT_SECRET}"
EOF

  chown telemt:telemt /etc/telemt/telemt.toml
  chmod 640 /etc/telemt/telemt.toml
}

write_panel_config() {
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
RestartSec=3
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

configure_firewall() {
  if ! command -v ufw >/dev/null 2>&1; then
    return 0
  fi

  if confirm "Открыть порты 22, 443 и 8080 через UFW?" "Y"; then
    ufw allow 22/tcp || true
    ufw allow 443/tcp || true
    ufw allow 8080/tcp || true
    if ufw status | grep -q inactive; then
      ufw --force enable
    else
      ufw reload || true
    fi
  fi
}

start_services() {
  systemctl daemon-reload
  systemctl enable --now telemt
  systemctl restart telemt

  systemctl enable --now telemt-panel
  systemctl restart telemt-panel
}

show_result() {
  local user_json tg_links
  echo
  echo "=============================================="
  echo "Telemt и панель установлены"
  echo "=============================================="
  echo "Panel URL     : http://${PUBLIC_IP}:8080/"
  echo "Panel user    : ${PANEL_USER}"
  echo "Panel password: ${PANEL_PASSWORD}"
  echo "Telemt secret : ${TELEMT_SECRET}"
  echo "Mask domain   : ${MASK_DOMAIN}"
  echo

  echo "Проверка сервисов:"
  systemctl --no-pager --full status telemt telemt-panel | sed -n '1,80p' || true
  echo

  echo "Пользователи telemt через API:"
  user_json="$(curl -fsSL http://127.0.0.1:9091/v1/users 2>/dev/null || true)"
  if [[ -n "$user_json" ]]; then
    echo "$user_json" | jq . || echo "$user_json"

    tg_links="$(echo "$user_json" | jq -r '.. | strings | select(startswith("tg://proxy") or startswith("https://t.me/proxy"))' 2>/dev/null || true)"
    if [[ -n "$tg_links" ]]; then
      echo
      echo "Найденные proxy-ссылки:"
      echo "$tg_links"
    fi
  else
    warn "API telemt пока не ответил. Проверь: journalctl -u telemt -n 100 --no-pager"
  fi

  echo
  echo "Полезные команды:"
  echo "  journalctl -u telemt -n 100 --no-pager"
  echo "  journalctl -u telemt-panel -n 100 --no-pager"
  echo "  curl -s http://127.0.0.1:9091/v1/users | jq"
  echo "  ss -ltnp | egrep ':443|:8080|:9091'"
}

install_all() {
  require_root
  detect_arch
  install_packages
  install_telemt_binary
  install_panel_binary
  create_user_and_dirs
  generate_values
  generate_panel_hash
  write_telemt_config
  write_panel_config
  write_telemt_service
  write_panel_service
  configure_firewall
  start_services
  show_result
}

uninstall_all() {
  require_root

  if ! confirm "Точно удалить Telemt + Panel?" "N"; then
    echo "Отмена."
    return 0
  fi

  systemctl disable --now telemt-panel 2>/dev/null || true
  systemctl disable --now telemt 2>/dev/null || true

  rm -f /etc/systemd/system/telemt.service
  rm -f /etc/systemd/system/telemt-panel.service
  systemctl daemon-reload

  rm -f /bin/telemt
  rm -f /usr/local/bin/telemt-panel

  rm -rf /etc/telemt /etc/telemt-panel /var/lib/telemt /opt/telemt

  if id telemt >/dev/null 2>&1; then
    userdel -r telemt 2>/dev/null || true
  fi

  if command -v ufw >/dev/null 2>&1; then
    ufw delete allow 443/tcp 2>/dev/null || true
    ufw delete allow 8080/tcp 2>/dev/null || true
  fi

  echo "Удаление завершено."
}

menu() {
  echo "=============================================="
  echo "1) Установка Telemt + Panel"
  echo "2) Полное удаление Telemt + Panel"
  echo "0) Выход"
  echo "=============================================="
  read -r -p "Выбери пункт: " choice

  case "$choice" in
    1) install_all ;;
    2) uninstall_all ;;
    0) exit 0 ;;
    *) err "Неизвестный пункт меню"; exit 1 ;;
  esac
}

menu
