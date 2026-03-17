#!/usr/bin/env bash
set -euo pipefail

WORK_DIR="$HOME/telemt-proxy"
BUILD_DIR="$WORK_DIR/build_telemt"

NATIVE_DIR="/etc/telemt"
NATIVE_CONFIG="$NATIVE_DIR/telemt.toml"
NATIVE_BINARY="/bin/telemt"
NATIVE_SERVICE="telemt"

PANEL_DIR="/etc/telemt-panel"
PANEL_CONFIG="$PANEL_DIR/config.toml"
PANEL_BINARY="/usr/local/bin/telemt-panel"
PANEL_SERVICE="telemt-panel"

DOCKER_IMAGE="ghcr.io/telemt/telemt:latest"
DOCKER_CONTAINER="telemt_proxy"

TTY_INPUT="/dev/tty"
[ -r "$TTY_INPUT" ] || TTY_INPUT="/dev/stdin"

say()  { printf '%s\n' "$*"; }
warn() { printf '⚠️ %s\n' "$*" >&2; }
die()  { printf '❌ %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Запускайте этот скрипт от root"

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

install_base_deps() {
  apt-get update -qq
  apt-get install -yqq \
    ca-certificates curl git openssl sed grep coreutils util-linux \
    tar gzip xz-utils systemd jq python3
  if ! command -v awk >/dev/null 2>&1; then
    apt-get install -yqq mawk || apt-get install -yqq gawk
  fi
}

install_build_deps() {
  apt-get update -qq
  apt-get install -yqq build-essential pkg-config libssl-dev
}

ensure_rust() {
  if command -v cargo >/dev/null 2>&1; then
    return 0
  fi
  say "🦀 Устанавливаем Rust"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  # shellcheck disable=SC1090
  source "$HOME/.cargo/env"
}

ensure_docker_client_only() {
  if command -v docker >/dev/null 2>&1; then
    return 0
  fi
  warn "Docker не найден. Для миграции Docker -> служба нужен docker-клиент."
  warn "Если Docker у вас уже должен быть, установите/почините его отдельно."
  die "Команда docker недоступна"
}

docker_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
    return 0
  fi
  die "Docker Compose v2 не найден"
}

service_exists() {
  systemctl list-unit-files | grep -q "^${NATIVE_SERVICE}\.service"
}

service_active() {
  systemctl is-active --quiet "$NATIVE_SERVICE" 2>/dev/null
}

panel_exists() {
  systemctl list-unit-files | grep -q "^${PANEL_SERVICE}\.service" || [ -f "$PANEL_CONFIG" ] || [ -x "$PANEL_BINARY" ]
}

panel_active() {
  systemctl is-active --quiet "$PANEL_SERVICE" 2>/dev/null
}

docker_telemt_exists() {
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${DOCKER_CONTAINER}$"
}

docker_telemt_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${DOCKER_CONTAINER}$"
}

wait_port_free() {
  local ports_regex="$1"
  local i
  for i in $(seq 1 20); do
    if ! ss -ltnp 2>/dev/null | grep -qE "$ports_regex"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

get_public_ip() {
  curl -fsS --max-time 8 -4 ifconfig.me 2>/dev/null || true
}

read_domain_from_cfg() {
  local cfg="$1"
  [ -f "$cfg" ] || return 0
  awk -F'"' '/^tls_domain[[:space:]]*=/{print $2; exit}' "$cfg"
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

  [ -n "$domain" ] || return 0
  [ -n "$secret" ] || return 0

  hex="$(printf '%s' "$domain" | xxd -p -c 999 | tr -d '\n')"

  say "📄 Конфиг: $cfg"
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

ensure_native_api_config() {
  [ -f "$NATIVE_CONFIG" ] || return 0

  python3 - "$NATIVE_CONFIG" <<'PY'
from pathlib import Path
import sys

cfg = Path(sys.argv[1])
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

  chmod 600 "$NATIVE_CONFIG"
}

sync_panel_for_service() {
  [ -f "$PANEL_CONFIG" ] || return 0

  mkdir -p "$PANEL_DIR"

  python3 - "$PANEL_CONFIG" <<'PY'
from pathlib import Path
import sys

cfg = Path(sys.argv[1])
text = cfg.read_text()

if "[telemt]" not in text:
    text += "\n[telemt]\n"

lines = text.splitlines()
out = []
in_telemt = False
seen_url = False
seen_auth = False
seen_bin = False
seen_srv = False

def flush_missing(out_list):
    global seen_url, seen_auth, seen_bin, seen_srv
    if not seen_url:
        out_list.append('url = "http://127.0.0.1:9091"')
    if not seen_auth:
        out_list.append('auth_header = ""')
    if not seen_bin:
        out_list.append('binary_path = "/bin/telemt"')
    if not seen_srv:
        out_list.append('service_name = "telemt"')

for line in lines:
    s = line.strip()
    if s == "[telemt]":
        in_telemt = True
        out.append(line)
        continue

    if in_telemt and s.startswith("[") and s != "[telemt]":
        flush_missing(out)
        in_telemt = False
        out.append(line)
        continue

    if in_telemt and s.startswith("url ="):
        out.append('url = "http://127.0.0.1:9091"')
        seen_url = True
        continue

    if in_telemt and s.startswith("auth_header ="):
        out.append('auth_header = ""')
        seen_auth = True
        continue

    if in_telemt and s.startswith("binary_path ="):
        out.append('binary_path = "/bin/telemt"')
        seen_bin = True
        continue

    if in_telemt and s.startswith("service_name ="):
        out.append('service_name = "telemt"')
        seen_srv = True
        continue

    out.append(line)

if in_telemt:
    flush_missing(out)

cfg.write_text("\n".join(out) + "\n")
PY

  chmod 600 "$PANEL_CONFIG"
  systemctl restart "$PANEL_SERVICE" 2>/dev/null || true
}

choose_version_mode() {
  printf '\n'
  say "Какую версию ставить?"
  say "1) Stable / LTS"
  say "2) Latest"
  local choice
  choice="$(ask "Выберите пункт" "1")"
  case "$choice" in
    1) echo "stable" ;;
    2) echo "latest" ;;
    *) echo "stable" ;;
  esac
}

clone_telemt_source() {
  local version_mode="$1"

  rm -rf "$BUILD_DIR"
  mkdir -p "$WORK_DIR"
  git clone --depth 1 https://github.com/telemt/telemt.git "$BUILD_DIR"

  (
    cd "$BUILD_DIR"

    git fetch --tags --force >/dev/null 2>&1 || true

    if [ "$version_mode" = "stable" ]; then
      local tag
      tag="$(git tag --sort=-v:refname | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)"
      [ -n "$tag" ] || die "Не удалось определить stable tag"
      say "📌 Ставим stable tag: $tag"
      git checkout "$tag" >/dev/null 2>&1
    else
      local tag
      tag="$(git tag --sort=-creatordate | head -n1)"
      [ -n "$tag" ] || tag="$(git tag --sort=-v:refname | head -n1)"
      [ -n "$tag" ] || die "Не удалось определить latest tag"
      say "📌 Ставим latest tag: $tag"
      git checkout "$tag" >/dev/null 2>&1
    fi
  )
}

create_native_config() {
  local domain="$1"
  local secret="$2"

  mkdir -p "$NATIVE_DIR"
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

  chmod 600 "$NATIVE_CONFIG"
  ensure_native_api_config
}

install_or_update_panel_for_service() {
  install_base_deps

  say "📦 Устанавливаем / обновляем Telemt Panel"
  curl -fsSL https://raw.githubusercontent.com/amirotin/telemt_panel/main/install.sh | bash

  [ -f "$PANEL_CONFIG" ] || die "После установки панели не найден $PANEL_CONFIG"

  sync_panel_for_service
  systemctl enable --now "$PANEL_SERVICE" 2>/dev/null || true
}

install_service_and_panel() {
  install_base_deps
  install_build_deps
  ensure_rust
  # shellcheck disable=SC1090
  [ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"

  local version_mode domain secret
  version_mode="$(choose_version_mode)"
  domain="$(ask "Домен маскировки" "google.com")"
  secret="$(openssl rand -hex 16)"

  clone_telemt_source "$version_mode"

  (
    cd "$BUILD_DIR"
    cargo build --release
  )

  install -m 0755 "$BUILD_DIR/target/release/telemt" "$NATIVE_BINARY"

  create_native_config "$domain" "$secret"

  cat > "/etc/systemd/system/${NATIVE_SERVICE}.service" <<EOF
[Unit]
Description=Telemt Proxy
After=network.target

[Service]
Type=simple
User=root
ExecStart=$NATIVE_BINARY $NATIVE_CONFIG
Restart=on-failure
RestartSec=2
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$NATIVE_SERVICE"

  sleep 2
  service_active || die "Telemt service не поднялся"

  install_or_update_panel_for_service

  say "✅ Служба и панель установлены"
}

migrate_docker_to_service() {
  ensure_docker_client_only
  install_base_deps
  install_build_deps
  ensure_rust
  # shellcheck disable=SC1090
  [ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"

  [ -f "$CFG" ] || die "Не найден Docker-конфиг: $CFG"

  local version_mode
  version_mode="$(choose_version_mode)"

  clone_telemt_source "$version_mode"

  (
    cd "$BUILD_DIR"
    cargo build --release
  )

  install -m 0755 "$BUILD_DIR/target/release/telemt" "$NATIVE_BINARY"

  mkdir -p "$NATIVE_DIR"
  cp "$CFG" "$NATIVE_CONFIG"
  chmod 600 "$NATIVE_CONFIG"
  ensure_native_api_config

  local compose_cmd
  compose_cmd="$(docker_compose_cmd)"

  if [ -f "$COMPOSE" ]; then
    (
      cd "$WORK_DIR"
      $compose_cmd down >/dev/null 2>&1 || true
    )
  fi

  docker rm -f "$DOCKER_CONTAINER" >/dev/null 2>&1 || true

  if ! wait_port_free ':(443|9091)\b'; then
    warn "Порты 443/9091 ещё заняты:"
    ss -ltnp 2>/dev/null | grep -E ':(443|9091)\b' || true
    die "Не удалось освободить порты перед запуском службы"
  fi

  cat > "/etc/systemd/system/${NATIVE_SERVICE}.service" <<EOF
[Unit]
Description=Telemt Proxy
After=network.target

[Service]
Type=simple
User=root
ExecStart=$NATIVE_BINARY $NATIVE_CONFIG
Restart=on-failure
RestartSec=2
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$NATIVE_SERVICE"

  sleep 2
  service_active || die "После миграции служба Telemt не поднялась"

  if panel_exists; then
    sync_panel_for_service
  else
    install_or_update_panel_for_service
  fi

  say "✅ Миграция Docker → служба завершена"
}

deep_cleanup_keep_amnezia() {
  say "🧹 Глубокая очистка мусора без удаления Amnezia"

  apt-get clean
  apt-get autoremove -y || true
  journalctl --vacuum-time=7d || true

  rm -rf /tmp/* /var/tmp/* 2>/dev/null || true
  rm -rf "$BUILD_DIR" 2>/dev/null || true
  rm -rf "$HOME/.cargo/registry" "$HOME/.cargo/git" 2>/dev/null || true

  if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
    docker container prune -f || true
    docker image prune -f || true
    docker builder prune -a -f || true
  else
    warn "Docker daemon не запущен, docker-prune пропущен"
  fi

  say "✅ Очистка завершена"
  df -h /
}

show_current_links() {
  say "📊 Статус Telemt"

  if service_exists; then
    if service_active; then
      say "• Служба: active"
    else
      say "• Служба: installed, inactive"
    fi
  else
    say "• Служба: не установлена"
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
  elif [ -f "$CFG" ]; then
    print_links_for_cfg "$CFG"
  else
    warn "Конфиг Telemt не найден"
  fi
}

delete_all_telemt() {
  local confirm
  confirm="$(ask "Точно удалить весь Telemt и панель? (yes/no)" "no")"
  [ "$confirm" = "yes" ] || {
    say "Отменено"
    return 0
  }

  systemctl stop "$PANEL_SERVICE" 2>/dev/null || true
  systemctl disable "$PANEL_SERVICE" 2>/dev/null || true
  rm -f "/etc/systemd/system/${PANEL_SERVICE}.service"
  rm -f "$PANEL_BINARY"
  rm -rf "$PANEL_DIR"

  systemctl stop "$NATIVE_SERVICE" 2>/dev/null || true
  systemctl disable "$NATIVE_SERVICE" 2>/dev/null || true
  rm -f "/etc/systemd/system/${NATIVE_SERVICE}.service"
  rm -f "$NATIVE_BINARY"
  rm -rf "$NATIVE_DIR"

  if command -v docker >/dev/null 2>&1; then
    local compose_cmd
    if docker compose version >/dev/null 2>&1; then
      compose_cmd="docker compose"
      [ -f "$COMPOSE" ] && (
        cd "$WORK_DIR"
        $compose_cmd down >/dev/null 2>&1 || true
      )
    fi
    docker rm -f "$DOCKER_CONTAINER" >/dev/null 2>&1 || true
    docker image rm -f "$DOCKER_IMAGE" >/dev/null 2>&1 || true
  fi

  rm -rf "$WORK_DIR"

  systemctl daemon-reload
  systemctl reset-failed "$NATIVE_SERVICE" "$PANEL_SERVICE" 2>/dev/null || true

  say "✅ Всё, что связано с Telemt, удалено"
}

show_menu() {
  clear
  say "═════════════════════════════════════════════════════"
  say " 🛠️  Telemt Service Manager"
  say "═════════════════════════════════════════════════════"
  say "1) Установить службу + панель"
  say "2) Миграция Docker → служба"
  say "3) Глубокая очистка мусора"
  say "4) Показать текущие ссылки"
  say "5) Удалить весь Telemt"
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
        migrate_docker_to_service
        pause
        ;;
      3)
        deep_cleanup_keep_amnezia
        pause
        ;;
      4)
        show_current_links
        pause
        ;;
      5)
        delete_all_telemt
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
