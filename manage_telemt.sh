#!/usr/bin/env bash
set -Eeuo pipefail

WORK_DIR="/root/telemt-proxy"
BUILD_DIR="$WORK_DIR/build_telemt"

NATIVE_USER="telemt"
NATIVE_HOME="/opt/telemt"
NATIVE_BIN="/bin/telemt"
NATIVE_DIR="/etc/telemt"
NATIVE_CONFIG="$NATIVE_DIR/telemt.toml"
NATIVE_SERVICE="telemt"

PANEL_BIN="/usr/local/bin/telemt-panel"
PANEL_DIR="/etc/telemt-panel"
PANEL_CONFIG="$PANEL_DIR/config.toml"
PANEL_SERVICE="telemt-panel"

DOCKER_CONTAINER="telemt_proxy"
DOCKER_IMAGE="ghcr.io/telemt/telemt:latest"

TTY_INPUT="/dev/tty"
[ -r "$TTY_INPUT" ] || TTY_INPUT="/dev/stdin"

say()  { printf '%s\n' "$*"; }
warn() { printf '⚠️ %s\n' "$*" >&2; }
die()  { printf '❌ %s\n' "$*" >&2; exit 1; }

trap 'warn "Ошибка на строке $LINENO"' ERR

[ "$(id -u)" -eq 0 ] || die "Запускай от root"

ask() {
  local prompt="$1"
  local default="${2-}"
  local answer
  if [ -n "$default" ]; then
    IFS= read -r -p "$prompt [$default]: " answer <"$TTY_INPUT"
    printf '%s' "${answer:-$default}"
  else
    IFS= read -r -p "$prompt: " answer <"$TTY_INPUT"
    printf '%s' "$answer"
  fi
}

pause() {
  printf '\n'
  IFS= read -r -p "Нажмите Enter, чтобы вернуться в меню..." _ <"$TTY_INPUT"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Не найдена команда: $1"
}

docker_client_available() {
  command -v docker >/dev/null 2>&1
}

docker_compose_available() {
  docker compose version >/dev/null 2>&1
}

docker_daemon_ready() {
  docker version >/dev/null 2>&1
}

service_exists() {
  systemctl list-unit-files | grep -q "^${NATIVE_SERVICE}\.service"
}

service_active() {
  systemctl is-active --quiet "$NATIVE_SERVICE" 2>/dev/null
}

panel_exists() {
  [ -x "$PANEL_BIN" ] || [ -f "$PANEL_CONFIG" ] || systemctl list-unit-files | grep -q "^${PANEL_SERVICE}\.service"
}

panel_active() {
  systemctl is-active --quiet "$PANEL_SERVICE" 2>/dev/null
}

wait_service_active() {
  local service="$1"
  local i
  for i in $(seq 1 30); do
    if systemctl is-active --quiet "$service" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_port_free() {
  local port="$1"
  local i
  for i in $(seq 1 30); do
    if ! ss -ltnp 2>/dev/null | grep -q ":${port}\b"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

install_base_deps() {
  apt-get update -qq
  apt-get install -yqq \
    ca-certificates curl jq openssl python3 tar xz-utils \
    sed grep coreutils util-linux xxd
  if ! command -v awk >/dev/null 2>&1; then
    apt-get install -yqq mawk || apt-get install -yqq gawk
  fi
}

get_public_ip() {
  curl -fsS --max-time 8 -4 ifconfig.me 2>/dev/null || true
}

read_cfg_value() {
  local cfg="$1"
  local key="$2"
  [ -f "$cfg" ] || return 0
  awk -F'"' -v k="$key" '$0 ~ "^"k"[[:space:]]*=" {print $2; exit}' "$cfg"
}

read_domain_from_cfg() {
  read_cfg_value "$1" "tls_domain"
}

read_secret_from_cfg() {
  local cfg="$1"
  [ -f "$cfg" ] || return 0
  awk -F'"' '/^(main_user|hello)[[:space:]]*=/{print $2; exit}' "$cfg"
}

print_links_for_cfg() {
  local cfg="$1"
  [ -f "$cfg" ] || return 0

  local domain secret ip hex
  domain="$(read_domain_from_cfg "$cfg")"
  secret="$(read_secret_from_cfg "$cfg")"
  ip="$(get_public_ip)"

  [ -n "$domain" ] || { warn "Не найден tls_domain в $cfg"; return 0; }
  [ -n "$secret" ] || { warn "Не найден secret в $cfg"; return 0; }

  hex="$(printf '%s' "$domain" | xxd -p -c 999 | tr -d '\n')"

  say "📄 Активный конфиг: $cfg"
  say "🌍 Домен маскировки: $domain"

  if [ -n "$ip" ]; then
    say "🔗 TG: tg://proxy?server=$ip&port=443&secret=ee${secret}${hex}"
    say "🔗 T.ME: https://t.me/proxy?server=$ip&port=443&secret=ee${secret}${hex}"
    if panel_exists; then
      say "🌐 ПАНЕЛЬ: http://$ip:8080"
    fi
  else
    warn "Не удалось определить внешний IP"
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64) echo "x86_64" ;;
    aarch64|arm64) echo "aarch64" ;;
    *) die "Неподдерживаемая архитектура: $(uname -m)" ;;
  esac
}

detect_libc() {
  if ldd --version 2>&1 | grep -qi musl; then
    echo "musl"
  else
    echo "gnu"
  fi
}

download_latest_telemt() {
  local arch libc url tmpdir
  arch="$(detect_arch)"
  libc="$(detect_libc)"

  url="$(curl -fsSL https://api.github.com/repos/telemt/telemt/releases/latest \
    | jq -r --arg a "$arch" --arg l "$libc" \
      '.assets[]?.browser_download_url
       | select(test("telemt-" + $a + "-linux-" + $l + "\\.tar\\.gz$"))' \
    | head -n1)"

  [ -n "$url" ] || die "Не удалось найти подходящий релиз Telemt для ${arch}/${libc}"

  say "📦 Скачиваем Telemt: $url"
  tmpdir="$(mktemp -d)"
  curl -fL "$url" -o "$tmpdir/telemt.tar.gz" || die "Не удалось скачать бинарник Telemt"
  tar -xzf "$tmpdir/telemt.tar.gz" -C "$tmpdir"
  [ -f "$tmpdir/telemt" ] || die "В архиве не найден бинарник telemt"
  install -m 0755 "$tmpdir/telemt" "$NATIVE_BIN"
  rm -rf "$tmpdir"
}

prepare_user_and_dirs() {
  useradd -d "$NATIVE_HOME" -m -r -U "$NATIVE_USER" 2>/dev/null || true
  mkdir -p "$NATIVE_DIR"
}

patch_native_api_config() {
  [ -f "$NATIVE_CONFIG" ] || die "Не найден $NATIVE_CONFIG"

  python3 - <<'PY'
from pathlib import Path

cfg = Path("/etc/telemt/telemt.toml")
text = cfg.read_text()

block = """[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.0/8"]
minimal_runtime_enabled = false
minimal_runtime_cache_ttl_ms = 1000
"""

lines = text.splitlines()
out = []
in_api = False
seen = False

for line in lines:
    s = line.strip()
    if s == "[server.api]":
        if not seen:
            out.extend(block.strip().splitlines())
            seen = True
        in_api = True
        continue
    if in_api and s.startswith("[") and s != "[server.api]":
        in_api = False
        out.append(line)
        continue
    if not in_api:
        out.append(line)

if not seen:
    out.append("")
    out.extend(block.strip().splitlines())

cfg.write_text("\n".join(out) + "\n")
PY
}

fix_native_permissions() {
  chown -R "$NATIVE_USER:$NATIVE_USER" "$NATIVE_DIR"
  chmod 750 "$NATIVE_DIR"
  chmod 640 "$NATIVE_CONFIG"
}

write_service_unit() {
  cat > "/etc/systemd/system/${NATIVE_SERVICE}.service" <<'EOF'
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

check_native_api() {
  curl -fsS http://127.0.0.1:9091/v1/users | jq . >/dev/null
  say "✅ Telemt API отвечает на 127.0.0.1:9091"
}

sync_panel_for_service() {
  [ -f "$PANEL_CONFIG" ] || die "Не найден конфиг панели: $PANEL_CONFIG"

  python3 - <<'PY'
from pathlib import Path

cfg = Path("/etc/telemt-panel/config.toml")
text = cfg.read_text()

if "[telemt]" not in text:
    text += "\n[telemt]\n"

lines = text.splitlines()
out = []
in_block = False
seen_url = False
seen_auth = False
seen_bin = False
seen_srv = False

def emit_missing(dst):
    global seen_url, seen_auth, seen_bin, seen_srv
    if not seen_url:
        dst.append('url = "http://127.0.0.1:9091"')
    if not seen_auth:
        dst.append('auth_header = ""')
    if not seen_bin:
        dst.append('binary_path = "/bin/telemt"')
    if not seen_srv:
        dst.append('service_name = "telemt"')

for line in lines:
    s = line.strip()

    if s == "[telemt]":
        in_block = True
        out.append(line)
        continue

    if in_block and s.startswith("[") and s != "[telemt]":
        emit_missing(out)
        in_block = False
        out.append(line)
        continue

    if in_block and s.startswith("url ="):
        out.append('url = "http://127.0.0.1:9091"')
        seen_url = True
        continue

    if in_block and s.startswith("auth_header ="):
        out.append('auth_header = ""')
        seen_auth = True
        continue

    if in_block and s.startswith("binary_path ="):
        out.append('binary_path = "/bin/telemt"')
        seen_bin = True
        continue

    if in_block and s.startswith("service_name ="):
        out.append('service_name = "telemt"')
        seen_srv = True
        continue

    out.append(line)

if in_block:
    emit_missing(out)

cfg.write_text("\n".join(out) + "\n")
PY
}

install_or_update_panel() {
  say "📦 Устанавливаем / обновляем Telemt Panel"
  curl -fsSL https://raw.githubusercontent.com/amirotin/telemt_panel/main/install.sh | bash
  [ -f "$PANEL_CONFIG" ] || die "После установки панели не найден $PANEL_CONFIG"
  sync_panel_for_service
  systemctl enable --now "$PANEL_SERVICE" 2>/dev/null || true
  systemctl restart "$PANEL_SERVICE"
}

stop_only_telemt_docker() {
  if docker_client_available; then
    docker stop "$DOCKER_CONTAINER" >/dev/null 2>&1 || true
    docker rm "$DOCKER_CONTAINER" >/dev/null 2>&1 || true
  fi
}

remove_only_telemt_docker_traces() {
  if ! docker_client_available; then
    return 0
  fi

  docker stop "$DOCKER_CONTAINER" >/dev/null 2>&1 || true
  docker rm "$DOCKER_CONTAINER" >/dev/null 2>&1 || true
  docker image rm "$DOCKER_IMAGE" >/dev/null 2>&1 || true
  docker network rm telemt-proxy_default >/dev/null 2>&1 || true
  rm -rf "$WORK_DIR"
}

safe_cleanup_keep_amnezia() {
  say "🧹 Безопасная очистка мусора"
  apt-get clean
  journalctl --vacuum-time=7d || true
  rm -rf "$BUILD_DIR" 2>/dev/null || true
  rm -rf /tmp/* /var/tmp/* 2>/dev/null || true

  if docker_client_available && docker_daemon_ready; then
    docker container prune -f || true
    docker image prune -f || true
    docker builder prune -a -f || true
  else
    warn "Docker daemon не запущен, docker-prune пропущен"
  fi

  say "✅ Очистка завершена"
  df -h /
}

detect_docker_config_source() {
  local src=""
  if docker_client_available && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${DOCKER_CONTAINER}$"; then
    src="$(docker inspect "$DOCKER_CONTAINER" \
      --format '{{range .Mounts}}{{println .Source " " .Destination}}{{end}}' \
      | awk '$2 ~ /\/config\.toml$/ {print $1; exit}')"
  fi

  if [ -z "$src" ] && [ -f "$DOCKER_WORKDIR/config.toml" ]; then
    src="$DOCKER_WORKDIR/config.toml"
  fi

  [ -n "$src" ] || die "Не удалось определить путь к docker config.toml"
  printf '%s' "$src"
}

install_service_and_panel() {
  install_base_deps
  download_latest_telemt
  prepare_user_and_dirs

  local domain secret
  domain="$(ask "Под какой домен маскируемся" "google.com")"
  secret="$(openssl rand -hex 16)"

  cat > "$NATIVE_CONFIG" <<EOF
users = [ "me" ]
ad_tag = ""
tls_domain = "$domain"

auto_update_time = 0
workers = 1
keepalive_secs = 10

listener = "0.0.0.0:443"
main_user = "$secret"
EOF

  patch_native_api_config
  fix_native_permissions
  write_service_unit

  if ! wait_port_free 443; then
    ss -ltnp | grep ':443' || true
    die "Порт 443 занят"
  fi

  if ! wait_port_free 9091; then
    ss -ltnp | grep ':9091' || true
    die "Порт 9091 занят"
  fi

  systemctl daemon-reload
  systemctl enable --now "$NATIVE_SERVICE"
  wait_service_active "$NATIVE_SERVICE" || die "telemt.service не поднялся"
  check_native_api

  install_or_update_panel
  say "✅ Служба и панель установлены"
}

migrate_docker_to_service_and_panel() {
  install_base_deps
  need_cmd docker
  docker_compose_available || warn "Docker Compose v2 не найден, это не критично для миграции"
  docker_daemon_ready || die "Docker daemon недоступен"

  local docker_cfg
  docker_cfg="$(detect_docker_config_source)"
  [ -f "$docker_cfg" ] || die "Не найден docker config.toml: $docker_cfg"

  cp "$docker_cfg" "$docker_cfg.bak.$(date +%F-%H%M%S)"
  say "💾 Бэкап docker-конфига создан: $docker_cfg.bak.*"

  download_latest_telemt
  prepare_user_and_dirs

  cp "$docker_cfg" "$NATIVE_CONFIG"
  patch_native_api_config
  fix_native_permissions
  write_service_unit

  stop_only_telemt_docker

  if ! wait_port_free 443; then
    ss -ltnp | grep ':443' || true
    die "Порт 443 не освободился"
  fi

  if ! wait_port_free 9091; then
    ss -ltnp | grep ':9091' || true
    die "Порт 9091 не освободился"
  fi

  systemctl daemon-reload
  systemctl enable --now "$NATIVE_SERVICE"
  wait_service_active "$NATIVE_SERVICE" || die "telemt.service не поднялся после миграции"
  check_native_api

  install_or_update_panel
  remove_only_telemt_docker_traces

  say "✅ Миграция Docker → служба и установка панели завершены"
}

show_current_links() {
  say "📊 Статус"

  if service_exists; then
    if service_active; then
      say "• Служба telemt: active"
    else
      say "• Служба telemt: installed, inactive"
    fi
  else
    say "• Служба telemt: не установлена"
  fi

  if panel_exists; then
    if panel_active; then
      say "• Панель: active"
    else
      say "• Панель: installed, inactive"
    fi
  else
    say "• Панель: не установлена"
  fi

  printf '\n'

  if [ -f "$NATIVE_CONFIG" ]; then
    print_links_for_cfg "$NATIVE_CONFIG"
  else
    warn "Не найден $NATIVE_CONFIG"
  fi
}

show_menu() {
  clear
  say "═════════════════════════════════════════════════════"
  say " 🛠️  Telemt Service Manager"
  say "═════════════════════════════════════════════════════"
  say "1) Установить службу + панель"
  say "2) Миграция Docker → служба + установка панели"
  say "3) Очистка мусора (безопасная)"
  say "4) Показать текущие ссылки"
  say "0) Выход"
}

main_loop() {
  while true; do
    show_menu
    local choice
    choice="$(ask "Выберите пункт" "4")"
    printf '\n'

    case "$choice" in
      1)
        install_service_and_panel
        pause
        ;;
      2)
        migrate_docker_to_service_and_panel
        pause
        ;;
      3)
        safe_cleanup_keep_amnezia
        pause
        ;;
      4)
        show_current_links
        pause
        ;;
      0)
        exit 0
        ;;
      *)
        warn "Неверный выбор"
        sleep 1
        ;;
    esac
  done
}

main_loop
