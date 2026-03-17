#!/usr/bin/env bash
set -euo pipefail

WORK_DIR="$HOME/telemt-proxy"
BUILD_DIR="$WORK_DIR/build_telemt"
NATIVE_USER="telemt"
NATIVE_HOME="/opt/telemt"
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

say() { printf '%s\n' "$*"; }
warn() { printf '⚠️ %s\n' "$*" >&2; }
die() { printf '❌ %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Запускайте этот скрипт от root"

ask() {
  local prompt="$1"
  local default="${2-}"
  local answer
  if [ -n "$default" ]; then
    read -r -p "$prompt [$default]: " answer < "$TTY_INPUT"
    printf '%s' "${answer:-$default}"
  else
    read -r -p "$prompt: " answer < "$TTY_INPUT"
    printf '%s' "$answer"
  fi
}

pause_if_needed() {
  :
}

install_base_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  local pkgs=(
    ca-certificates
    curl
    git
    openssl
    python3
    python3-venv
    tar
    gzip
    sed
    grep
    coreutils
    util-linux
    passwd
    systemd
    jq
  )
  apt-get install -yqq "${pkgs[@]}"
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    say "🐳 Устанавливаем Docker"
    curl -fsSL https://get.docker.com | sh
  fi

  if ! docker compose version >/dev/null 2>&1; then
    say "📦 Устанавливаем Docker Compose v2"
    apt-get update -qq
    apt-get install -yqq docker-compose-plugin || true
  fi

  docker version >/dev/null 2>&1 || die "Docker недоступен"
  docker compose version >/dev/null 2>&1 || die "Нужен Docker Compose v2 (команда docker compose)"
}

ensure_rust() {
  if ! command -v cargo >/dev/null 2>&1; then
    say "🦀 Устанавливаем Rust toolchain"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  fi
  # shellcheck disable=SC1090
  [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
  command -v cargo >/dev/null 2>&1 || die "cargo не найден после установки Rust"
}

choose_branch_mode() {
  say ""
  say "Выберите ветку Telemt:"
  say "1) LTS / стабильный релиз"
  say "2) Latest / самый свежий релиз"
  local ch
  ch=$(ask "Выберите пункт" "1")
  case "$ch" in
    1) printf 'stable' ;;
    2) printf 'latest' ;;
    *) printf 'stable' ;;
  esac
}

choose_docker_source() {
  say ""
  say "Как обновлять / ставить Docker-версию Telemt:"
  say "1) Docker pull готового образа"
  say "2) Сборка Docker-образа из исходников"
  local ch
  ch=$(ask "Выберите пункт" "1")
  case "$ch" in
    1) printf 'pull' ;;
    2) printf 'build' ;;
    *) printf 'pull' ;;
  esac
}

clone_telemt_source() {
  local branch_mode="$1"
  rm -rf "$BUILD_DIR"
  mkdir -p "$WORK_DIR"
  git clone https://github.com/telemt/telemt.git "$BUILD_DIR"
  cd "$BUILD_DIR"

  local tag=""
  if [ "$branch_mode" = "stable" ]; then
    tag=$(git tag --sort=-v:refname | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true)
  else
    tag=$(git tag --sort=-creatordate | head -n1 || true)
  fi

  if [ -n "$tag" ]; then
    git checkout "$tag"
  else
    git checkout main
  fi
}

hex_domain() {
  python3 - "$1" <<'PY'
import sys
print(sys.argv[1].encode().hex())
PY
}

read_cfg_value() {
  local cfg="$1"
  local key="$2"
  python3 - "$cfg" "$key" <<'PY'
from pathlib import Path
import sys, re
p = Path(sys.argv[1])
key = sys.argv[2]
if not p.exists():
    raise SystemExit(0)
text = p.read_text(errors='ignore')
m = re.search(rf'(?m)^\s*{re.escape(key)}\s*=\s*"([^"]*)"', text)
print(m.group(1) if m else "")
PY
}

current_external_ip() {
  local ip
  ip=$(curl -fsS --max-time 8 -4 https://api.ipify.org 2>/dev/null || true)
  [ -n "$ip" ] || ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  printf '%s' "$ip"
}

native_installed() {
  [ -f "$NATIVE_CONFIG" ] || [ -x "$NATIVE_BINARY" ] || systemctl list-unit-files 2>/dev/null | grep -q "^${NATIVE_SERVICE}\.service"
}

native_running() {
  systemctl is-active --quiet "$NATIVE_SERVICE" 2>/dev/null
}

docker_installed() {
  [ -f "$WORK_DIR/docker-compose.yml" ] || docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${DOCKER_CONTAINER}$"
}

docker_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${DOCKER_CONTAINER}$"
}

panel_installed() {
  [ -f "$PANEL_CONFIG" ] || [ -x "$PANEL_BINARY" ] || systemctl list-unit-files 2>/dev/null | grep -q "^${PANEL_SERVICE}\.service"
}

panel_running() {
  systemctl is-active --quiet "$PANEL_SERVICE" 2>/dev/null
}

active_mode() {
  if docker_running; then
    printf 'docker'
  elif native_running; then
    printf 'service'
  elif docker_installed; then
    printf 'docker-stopped'
  elif native_installed; then
    printf 'service-stopped'
  else
    printf 'none'
  fi
}

ensure_native_user() {
  if ! id -u "$NATIVE_USER" >/dev/null 2>&1; then
    useradd -d "$NATIVE_HOME" -m -r -U "$NATIVE_USER"
  fi
  mkdir -p "$NATIVE_HOME"
  chown -R "$NATIVE_USER:$NATIVE_USER" "$NATIVE_HOME"
}

make_native_service_file() {
  cat > "/etc/systemd/system/${NATIVE_SERVICE}.service" <<EOF2
[Unit]
Description=Telemt
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${NATIVE_USER}
Group=${NATIVE_USER}
WorkingDirectory=${NATIVE_HOME}
ExecStart=${NATIVE_BINARY} ${NATIVE_CONFIG}
Restart=on-failure
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF2
}

ensure_native_api_config() {
  [ -f "$NATIVE_CONFIG" ] || return 0
  python3 - "$NATIVE_CONFIG" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text(errors='ignore')
block = '''[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.0/8"]
'''
lines = text.splitlines()
out = []
in_block = False
seen = False
for line in lines:
    s = line.strip()
    if s == '[server.api]':
        if not seen:
            out.extend(block.strip().splitlines())
            seen = True
        in_block = True
        continue
    if in_block and s.startswith('[') and s != '[server.api]':
        in_block = False
        out.append(line)
        continue
    if not in_block:
        out.append(line)
if not seen:
    if out and out[-1].strip():
        out.append('')
    out.extend(block.strip().splitlines())
p.write_text('\n'.join(out) + '\n')
PY
  chmod 600 "$NATIVE_CONFIG"
  chown -R "$NATIVE_USER:$NATIVE_USER" "$NATIVE_DIR"
}

ensure_docker_api_config() {
  local cfg="$1"
  [ -f "$cfg" ] || return 0
  python3 - "$cfg" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text(errors='ignore')
block = '''[server.api]
enabled = true
listen = "0.0.0.0:9091"
whitelist = ["127.0.0.0/8", "172.16.0.0/12"]
'''
lines = text.splitlines()
out = []
in_block = False
seen = False
for line in lines:
    s = line.strip()
    if s == '[server.api]':
        if not seen:
            out.extend(block.strip().splitlines())
            seen = True
        in_block = True
        continue
    if in_block and s.startswith('[') and s != '[server.api]':
        in_block = False
        out.append(line)
        continue
    if not in_block:
        out.append(line)
if not seen:
    if out and out[-1].strip():
        out.append('')
    out.extend(block.strip().splitlines())
p.write_text('\n'.join(out) + '\n')
PY
}

write_basic_native_config() {
  local domain="$1"
  local secret="$2"
  mkdir -p "$NATIVE_DIR"
  cat > "$NATIVE_CONFIG" <<EOF2
[general]
use_middle_proxy = false

[general.modes]
classic = false
secure = false
tls = true

[server]
port = 443

[censorship]
tls_domain = "$domain"

[access.users]
main_user = "$secret"
EOF2
  chmod 600 "$NATIVE_CONFIG"
  ensure_native_api_config
  ensure_native_user
  chown -R "$NATIVE_USER:$NATIVE_USER" "$NATIVE_DIR"
}

write_basic_docker_config() {
  local domain="$1"
  local secret="$2"
  mkdir -p "$WORK_DIR"
  cat > "$WORK_DIR/config.toml" <<EOF2
[general]
use_middle_proxy = false

[general.modes]
classic = false
secure = false
tls = true

[server]
port = 443

[censorship]
tls_domain = "$domain"

[access.users]
main_user = "$secret"
EOF2
  ensure_docker_api_config "$WORK_DIR/config.toml"
}

write_docker_compose() {
  mkdir -p "$WORK_DIR"
  cat > "$WORK_DIR/docker-compose.yml" <<EOF2
services:
  telemt:
    image: ${DOCKER_IMAGE}
    container_name: ${DOCKER_CONTAINER}
    restart: unless-stopped
    ports:
      - "443:443"
      - "127.0.0.1:9091:9091"
    working_dir: /run/telemt
    volumes:
      - ./config.toml:/run/telemt/config.toml:ro
    tmpfs:
      - /run/telemt:rw,mode=1777,size=1m
    environment:
      - RUST_LOG=info
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    read_only: true
    security_opt:
      - no-new-privileges:true
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
EOF2
}

compose() {
  docker compose "$@"
}

start_docker_stack() {
  ensure_docker
  write_docker_compose
  cd "$WORK_DIR"
  compose down --remove-orphans >/dev/null 2>&1 || true
  docker rm -f "$DOCKER_CONTAINER" >/dev/null 2>&1 || true
  compose up -d
}

stop_and_remove_docker_stack() {
  if [ -f "$WORK_DIR/docker-compose.yml" ]; then
    cd "$WORK_DIR"
    compose down --remove-orphans >/dev/null 2>&1 || true
  fi
  docker rm -f "$DOCKER_CONTAINER" >/dev/null 2>&1 || true
}

build_native_binary() {
  local branch_mode="$1"
  ensure_rust
  clone_telemt_source "$branch_mode"
  cargo build --release
  install -m 0755 target/release/telemt "$NATIVE_BINARY"
}

build_docker_image() {
  local branch_mode="$1"
  ensure_docker
  clone_telemt_source "$branch_mode"
  docker build -t "$DOCKER_IMAGE" .
}

pull_docker_image() {
  ensure_docker
  docker pull "$DOCKER_IMAGE"
}

install_or_update_panel_binary() {
  install_base_deps
  say "🧩 Устанавливаем / обновляем Telemt Panel"
  curl -fsSL https://raw.githubusercontent.com/amirotin/telemt_panel/main/install.sh | bash
}

sync_panel_config() {
  local mode="$1"
  [ -f "$PANEL_CONFIG" ] || return 0
  local telemt_url="http://127.0.0.1:9091"
  if [ "$mode" = "docker" ]; then
    telemt_url="http://127.0.0.1:9091"
  fi
  python3 - "$PANEL_CONFIG" "$telemt_url" <<'PY'
from pathlib import Path
import sys
cfg = Path(sys.argv[1])
telemt_url = sys.argv[2]
text = cfg.read_text(errors='ignore')
if '[telemt]' not in text:
    if text and not text.endswith('\n'):
        text += '\n'
    text += '\n[telemt]\n'
lines = text.splitlines()
out = []
in_block = False
seen_url = seen_auth = seen_bin = seen_srv = False
for line in lines:
    s = line.strip()
    if s == '[telemt]':
        in_block = True
        out.append(line)
        continue
    if in_block and s.startswith('[') and s != '[telemt]':
        if not seen_url:
            out.append(f'url = "{telemt_url}"')
        if not seen_auth:
            out.append('auth_header = ""')
        if not seen_bin:
            out.append('binary_path = "/bin/telemt"')
        if not seen_srv:
            out.append('service_name = "telemt"')
        in_block = False
        out.append(line)
        continue
    if in_block and s.startswith('url ='):
        out.append(f'url = "{telemt_url}"')
        seen_url = True
        continue
    if in_block and s.startswith('auth_header ='):
        out.append('auth_header = ""')
        seen_auth = True
        continue
    if in_block and s.startswith('binary_path ='):
        out.append('binary_path = "/bin/telemt"')
        seen_bin = True
        continue
    if in_block and s.startswith('service_name ='):
        out.append('service_name = "telemt"')
        seen_srv = True
        continue
    out.append(line)
if in_block:
    if not seen_url:
        out.append(f'url = "{telemt_url}"')
    if not seen_auth:
        out.append('auth_header = ""')
    if not seen_bin:
        out.append('binary_path = "/bin/telemt"')
    if not seen_srv:
        out.append('service_name = "telemt"')
cfg.write_text('\n'.join(out) + '\n')
PY
  chmod 600 "$PANEL_CONFIG"
}

ensure_panel_for_mode() {
  local mode="$1"
  install_or_update_panel_binary
  sync_panel_config "$mode"
  systemctl daemon-reload
  systemctl enable "$PANEL_SERVICE" >/dev/null 2>&1 || true
  systemctl restart "$PANEL_SERVICE"
}

auto_cleanup() {
  say "🧹 Автоочистка мусора"
  rm -rf "$BUILD_DIR" 2>/dev/null || true
  if command -v docker >/dev/null 2>&1; then
    docker image prune -f >/dev/null 2>&1 || true
    docker builder prune -f >/dev/null 2>&1 || true
  fi
}

show_links() {
  local cfg=""
  if docker_installed && [ -f "$WORK_DIR/config.toml" ]; then
    cfg="$WORK_DIR/config.toml"
  elif [ -f "$NATIVE_CONFIG" ]; then
    cfg="$NATIVE_CONFIG"
  fi

  local domain="" secret="" ip=""
  if [ -n "$cfg" ]; then
    domain=$(read_cfg_value "$cfg" "tls_domain")
    secret=$(read_cfg_value "$cfg" "main_user")
  fi
  ip=$(current_external_ip)

  say "═════════════════════════════════════════════════════"
  say "Статус Telemt: $(active_mode)"
  say "Service: $(native_running && printf 'active' || printf 'inactive')"
  say "Docker: $(docker_running && printf 'running' || printf 'stopped')"
  say "Panel:  $(panel_running && printf 'active' || printf 'inactive')"
  if [ -n "$domain" ] && [ -n "$secret" ] && [ -n "$ip" ]; then
    say "🔗 TELEGRAM: tg://proxy?server=${ip}&port=443&secret=ee${secret}$(hex_domain "$domain")"
  fi
  if [ -n "$ip" ]; then
    say "🌐 PANEL:   http://${ip}:8080"
  fi
  if [ -n "$cfg" ]; then
    say "📄 CONFIG:  ${cfg}"
  fi
  say "═════════════════════════════════════════════════════"
}

install_new_service() {
  local with_panel="$1"
  local branch_mode domain secret
  branch_mode=$(choose_branch_mode)
  domain=$(ask "Домен маскировки" "google.com")
  secret=$(openssl rand -hex 16)

  stop_and_remove_docker_stack

  install_base_deps
  build_native_binary "$branch_mode"
  ensure_native_user
  write_basic_native_config "$domain" "$secret"
  make_native_service_file
  systemctl daemon-reload
  systemctl enable --now "$NATIVE_SERVICE"

  if [ "$with_panel" = "yes" ]; then
    ensure_panel_for_mode service
  fi
  auto_cleanup
  show_links
}

install_new_docker() {
  local with_panel="$1"
  local source_mode domain secret branch_mode="stable"
  source_mode=$(choose_docker_source)
  if [ "$source_mode" = "build" ]; then
    branch_mode=$(choose_branch_mode)
  fi
  domain=$(ask "Домен маскировки" "google.com")
  secret=$(openssl rand -hex 16)

  systemctl stop "$NATIVE_SERVICE" >/dev/null 2>&1 || true
  systemctl disable "$NATIVE_SERVICE" >/dev/null 2>&1 || true

  install_base_deps
  write_basic_docker_config "$domain" "$secret"
  if [ "$source_mode" = "pull" ]; then
    pull_docker_image
  else
    build_docker_image "$branch_mode"
  fi
  start_docker_stack

  if [ "$with_panel" = "yes" ]; then
    ensure_panel_for_mode docker
  fi
  auto_cleanup
  show_links
}

update_existing_telemt() {
  local mode
  mode=$(active_mode)
  case "$mode" in
    service|service-stopped)
      local branch_mode
      branch_mode=$(choose_branch_mode)
      install_base_deps
      build_native_binary "$branch_mode"
      [ -f "$NATIVE_CONFIG" ] || die "Не найден $NATIVE_CONFIG"
      ensure_native_api_config
      make_native_service_file
      systemctl daemon-reload
      systemctl enable "$NATIVE_SERVICE" >/dev/null 2>&1 || true
      systemctl restart "$NATIVE_SERVICE"
      if panel_installed; then
        sync_panel_config service
        systemctl restart "$PANEL_SERVICE" >/dev/null 2>&1 || true
      fi
      auto_cleanup
      show_links
      ;;
    docker|docker-stopped)
      local source_mode branch_mode="stable"
      source_mode=$(choose_docker_source)
      install_base_deps
      [ -f "$WORK_DIR/config.toml" ] || die "Не найден $WORK_DIR/config.toml"
      ensure_docker_api_config "$WORK_DIR/config.toml"
      if [ "$source_mode" = "pull" ]; then
        pull_docker_image
      else
        branch_mode=$(choose_branch_mode)
        build_docker_image "$branch_mode"
      fi
      start_docker_stack
      if panel_installed; then
        sync_panel_config docker
        systemctl restart "$PANEL_SERVICE" >/dev/null 2>&1 || true
      fi
      auto_cleanup
      show_links
      ;;
    *)
      die "Telemt не найден ни как служба, ни как Docker-контейнер"
      ;;
  esac
}

repair_or_update_panel() {
  local mode
  mode=$(active_mode)
  case "$mode" in
    service|service-stopped)
      ensure_native_api_config
      systemctl enable "$NATIVE_SERVICE" >/dev/null 2>&1 || true
      systemctl restart "$NATIVE_SERVICE" >/dev/null 2>&1 || true
      ensure_panel_for_mode service
      auto_cleanup
      show_links
      ;;
    docker|docker-stopped)
      [ -f "$WORK_DIR/config.toml" ] || die "Не найден $WORK_DIR/config.toml"
      ensure_docker_api_config "$WORK_DIR/config.toml"
      start_docker_stack
      ensure_panel_for_mode docker
      auto_cleanup
      show_links
      ;;
    none)
      die "Сначала установите Telemt как службу или Docker-контейнер"
      ;;
  esac
}

migrate_service_to_docker() {
  native_installed || die "Служба Telemt не найдена"
  [ -f "$NATIVE_CONFIG" ] || die "Не найден $NATIVE_CONFIG"

  install_base_deps
  mkdir -p "$WORK_DIR"
  cp "$NATIVE_CONFIG" "$WORK_DIR/config.toml"
  ensure_docker_api_config "$WORK_DIR/config.toml"

  local source_mode branch_mode="stable"
  source_mode=$(choose_docker_source)
  if [ "$source_mode" = "pull" ]; then
    pull_docker_image
  else
    branch_mode=$(choose_branch_mode)
    build_docker_image "$branch_mode"
  fi

  systemctl stop "$NATIVE_SERVICE" >/dev/null 2>&1 || true
  systemctl disable "$NATIVE_SERVICE" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${NATIVE_SERVICE}.service"
  systemctl daemon-reload

  start_docker_stack
  if panel_installed; then
    sync_panel_config docker
    systemctl restart "$PANEL_SERVICE" >/dev/null 2>&1 || true
  fi
  auto_cleanup
  show_links
}

migrate_docker_to_service() {
  docker_installed || die "Docker-версия Telemt не найдена"
  [ -f "$WORK_DIR/config.toml" ] || die "Не найден $WORK_DIR/config.toml"

  install_base_deps
  local branch_mode
  branch_mode=$(choose_branch_mode)
  build_native_binary "$branch_mode"
  ensure_native_user
  mkdir -p "$NATIVE_DIR"
  cp "$WORK_DIR/config.toml" "$NATIVE_CONFIG"
  ensure_native_api_config
  chown -R "$NATIVE_USER:$NATIVE_USER" "$NATIVE_DIR"
  chmod 600 "$NATIVE_CONFIG"
  make_native_service_file

  stop_and_remove_docker_stack

  systemctl daemon-reload
  systemctl enable --now "$NATIVE_SERVICE"

  if panel_installed; then
    sync_panel_config service
    systemctl restart "$PANEL_SERVICE" >/dev/null 2>&1 || true
  fi
  auto_cleanup
  show_links
}

remove_everything() {
  local confirm
  confirm=$(ask "Подтвердите полное удаление (yes/no)" "no")
  [ "$confirm" = "yes" ] || { say "Отменено"; return 0; }

  stop_and_remove_docker_stack
  docker rmi "$DOCKER_IMAGE" >/dev/null 2>&1 || true

  systemctl stop "$PANEL_SERVICE" >/dev/null 2>&1 || true
  systemctl disable "$PANEL_SERVICE" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${PANEL_SERVICE}.service"
  rm -rf "$PANEL_DIR"
  rm -f "$PANEL_BINARY"

  systemctl stop "$NATIVE_SERVICE" >/dev/null 2>&1 || true
  systemctl disable "$NATIVE_SERVICE" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${NATIVE_SERVICE}.service"
  rm -rf "$NATIVE_DIR"
  rm -f "$NATIVE_BINARY"
  userdel -r "$NATIVE_USER" >/dev/null 2>&1 || true

  rm -rf "$WORK_DIR"
  systemctl daemon-reload
  auto_cleanup
  say "✅ Всё, что связано с Telemt, удалено"
}

safe_cleanup() {
  auto_cleanup
  say "✅ Мусор очищен. Конфиги, ключи и ссылки сохранены"
}

new_install_menu() {
  say ""
  say "1) Служба + панель"
  say "2) Только служба"
  say "3) Docker + панель"
  say "4) Только Docker"
  local ch
  ch=$(ask "Выберите пункт" "1")
  case "$ch" in
    1) install_new_service yes ;;
    2) install_new_service no ;;
    3) install_new_docker yes ;;
    4) install_new_docker no ;;
    *) warn "Неверный выбор" ;;
  esac
}

main_menu() {
  install_base_deps
  say "═════════════════════════════════════════════════════"
  say " 🛠️  Telemt Manager"
  say "═════════════════════════════════════════════════════"
  say "1) Новая установка"
  say "2) Установить / обновить / починить панель"
  say "3) Обновить существующий Telemt"
  say "4) Миграция service → Docker"
  say "5) Миграция Docker → service"
  say "6) Показать статус и ссылки"
  say "7) Удалить всё, что связано с Telemt"
  say "8) Очистить мусор (ключи/ссылки не удаляются)"
  say "0) Выход"
  local ch
  ch=$(ask "Выберите пункт" "6")
  case "$ch" in
    1) new_install_menu ;;
    2) repair_or_update_panel ;;
    3) update_existing_telemt ;;
    4) migrate_service_to_docker ;;
    5) migrate_docker_to_service ;;
    6) show_links ;;
    7) remove_everything ;;
    8) safe_cleanup ;;
    0) exit 0 ;;
    *) warn "Неверный выбор" ;;
  esac
}

main_menu
