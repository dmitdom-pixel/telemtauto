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
warn() { printf '⚠️  %s\n' "$*" >&2; }
die() { printf '❌ %s\n' "$*" >&2; exit 1; }

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

ask_secret() {
  local prompt="$1"
  local answer
  IFS= read -r -s -p "$prompt: " answer <"$TTY_INPUT"
  printf '\n' >&2
  printf '%s' "$answer"
}

ask_menu() {
  local prompt="$1"
  local answer
  IFS= read -r -p "$prompt: " answer <"$TTY_INPUT"
  printf '%s' "$answer"
}

ask_confirm() {
  local prompt="$1"
  local answer
  IFS= read -r -p "$prompt [y/N]: " answer <"$TTY_INPUT"
  [[ "$answer" =~ ^([yY]|[дД])$ ]]
}

require_file() {
  [ -f "$1" ] || die "Не найден файл: $1"
}

install_base_deps() {
  local pkgs=()
  local p
  for p in git curl openssl ca-certificates python3 tar gzip sed awk grep coreutils util-linux passwd; do
    dpkg -s "$p" >/dev/null 2>&1 || pkgs+=("$p")
  done
  if [ ${#pkgs[@]} -gt 0 ]; then
    say "📦 Устанавливаем зависимости: ${pkgs[*]}"
    apt-get update -qq
    apt-get install -yqq "${pkgs[@]}"
  fi
}

compose() {
  docker compose "$@"
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    say "🐳 Устанавливаем Docker"
    curl -fsSL https://get.docker.com | sh
  fi

  if ! docker compose version >/dev/null 2>&1; then
    say "📦 Устанавливаем Docker Compose plugin v2"
    apt-get update -qq
    apt-get install -yqq docker-compose-plugin
  fi

  docker version >/dev/null 2>&1 || die "Docker установлен, но недоступен"
  docker compose version >/dev/null 2>&1 || die "Не найден Docker Compose v2 (команда docker compose)"
}

ensure_rust() {
  if ! command -v cargo >/dev/null 2>&1; then
    say "🦀 Устанавливаем Rust toolchain"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  fi
  # shellcheck disable=SC1090
  [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
  command -v cargo >/dev/null 2>&1 || die "cargo не найден после установки rustup"
}

choose_source_channel() {
  say "Какую версию брать из исходников?"
  say "  1) Последний стабильный тег"
  say "  2) Ветка main"
  case "$(ask_menu 'Выберите (1-2)')" in
    1) printf 'stable' ;;
    2) printf 'main' ;;
    *) die "Неверный выбор" ;;
  esac
}

clone_telemt_source() {
  local channel="$1"
  rm -rf "$BUILD_DIR"
  mkdir -p "$WORK_DIR"
  git clone https://github.com/telemt/telemt.git "$BUILD_DIR"
  pushd "$BUILD_DIR" >/dev/null
  if [ "$channel" = "stable" ]; then
    local ref
    ref="$(git tag --sort=-v:refname | grep -E '^[0-9]+(\.[0-9]+){2,}$' | head -n1 || true)"
    [ -n "$ref" ] || die "Не удалось определить стабильный тег Telemt"
    say "📌 Checkout stable tag: $ref"
    git checkout "$ref"
  else
    say "📌 Checkout branch: main"
    git checkout main
  fi
  popd >/dev/null
}

build_native_binary() {
  local channel="$1"
  install_base_deps
  ensure_rust
  clone_telemt_source "$channel"
  pushd "$BUILD_DIR" >/dev/null
  cargo build --release
  install -m 0755 target/release/telemt "$NATIVE_BINARY"
  popd >/dev/null
}

build_docker_image() {
  local channel="$1"
  install_base_deps
  ensure_docker
  clone_telemt_source "$channel"
  docker build -t "$DOCKER_IMAGE" "$BUILD_DIR"
}

ensure_native_layout() {
  install_base_deps
  if ! id "$NATIVE_USER" >/dev/null 2>&1; then
    useradd -d "$NATIVE_HOME" -m -r -U "$NATIVE_USER"
  fi
  mkdir -p "$NATIVE_DIR" "$NATIVE_HOME"
  chown -R "$NATIVE_USER:$NATIVE_USER" "$NATIVE_DIR" "$NATIVE_HOME"
}

install_native_service_unit() {
  tee "/etc/systemd/system/$NATIVE_SERVICE.service" >/dev/null <<EOF2
[Unit]
Description=Telemt
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$NATIVE_USER
Group=$NATIVE_USER
WorkingDirectory=$NATIVE_HOME
ExecStart=$NATIVE_BINARY $NATIVE_CONFIG
Restart=on-failure
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF2
  systemctl daemon-reload
}

write_base_telemt_config() {
  local cfg="$1"
  local domain="$2"
  local secret="$3"
  cat > "$cfg" <<EOF2
[general]
use_middle_proxy = false

[general.modes]
classic = false
secure = false
tls = true

[server]
port = 443

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32"]
minimal_runtime_enabled = false
minimal_runtime_cache_ttl_ms = 1000

[censorship]
tls_domain = "$domain"
mask = true
tls_emulation = true
tls_front_dir = "tlsfront"

[access.users]
main_user = "$secret"
EOF2
}

patch_telemt_api() {
  local cfg="$1"
  local mode="$2"
  python3 - "$cfg" "$mode" <<'PY'
from pathlib import Path
import sys
cfg = Path(sys.argv[1])
mode = sys.argv[2]
text = cfg.read_text(encoding='utf-8', errors='ignore')
if mode == 'native':
    block = [
        '[server.api]',
        'enabled = true',
        'listen = "127.0.0.1:9091"',
        'whitelist = ["127.0.0.1/32"]',
        'minimal_runtime_enabled = false',
        'minimal_runtime_cache_ttl_ms = 1000',
    ]
else:
    block = [
        '[server.api]',
        'enabled = true',
        'listen = "0.0.0.0:9091"',
        'whitelist = ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]',
        'minimal_runtime_enabled = false',
        'minimal_runtime_cache_ttl_ms = 1000',
    ]
lines = text.splitlines()
out = []
in_api = False
replaced = False
for line in lines:
    s = line.strip()
    if s == '[server.api]':
        if not replaced:
            out.extend(block)
            replaced = True
        in_api = True
        continue
    if in_api:
        if s.startswith('[') and s != '[server.api]':
            in_api = False
            out.append(line)
        continue
    out.append(line)
if not replaced:
    out.append('')
    out.extend(block)
cfg.write_text('\n'.join(out).rstrip() + '\n', encoding='utf-8')
PY
}

write_docker_compose() {
  mkdir -p "$WORK_DIR"
  cat > "$WORK_DIR/docker-compose.yml" <<EOF2
services:
  telemt:
    image: $DOCKER_IMAGE
    build: .
    container_name: $DOCKER_CONTAINER
    restart: unless-stopped
    ports:
      - "443:443"
      - "127.0.0.1:9091:9091"
      - "127.0.0.1:9090:9090"
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

stop_native_service() {
  systemctl stop "$NATIVE_SERVICE" 2>/dev/null || true
  systemctl disable "$NATIVE_SERVICE" 2>/dev/null || true
}

start_native_service() {
  systemctl daemon-reload
  systemctl enable --now "$NATIVE_SERVICE"
}

start_docker_stack() {
  ensure_docker
  write_docker_compose
  cd "$WORK_DIR" || exit 1
  compose down --remove-orphans || true
  docker rm -f "$DOCKER_CONTAINER" >/dev/null 2>&1 || true
  compose up -d
}

stop_docker_stack() {
  if [ -f "$WORK_DIR/docker-compose.yml" ]; then
    (cd "$WORK_DIR" && compose down --remove-orphans) || true
  fi
  docker rm -f "$DOCKER_CONTAINER" >/dev/null 2>&1 || true
}

install_panel_binary() {
  install_base_deps
  local arch latest tarball binary_name tmpdir
  arch="$(uname -m)"
  case "$arch" in
    x86_64|aarch64) ;;
    *) die "Неподдерживаемая архитектура для telemt-panel: $arch" ;;
  esac
  latest="$(curl -fsSL https://api.github.com/repos/amirotin/telemt_panel/releases/latest | python3 -c 'import sys,json; print(json.load(sys.stdin)["tag_name"])')"
  [ -n "$latest" ] || die "Не удалось определить последний релиз telemt-panel"
  tarball="telemt-panel-$arch-linux-gnu.tar.gz"
  binary_name="telemt-panel-$arch-linux"
  tmpdir="$(mktemp -d)"
  curl -fsSL "https://github.com/amirotin/telemt_panel/releases/download/$latest/$tarball" -o "$tmpdir/$tarball"
  tar -xzf "$tmpdir/$tarball" -C "$tmpdir"
  install -m 0755 "$tmpdir/$binary_name" "$PANEL_BINARY"
  rm -rf "$tmpdir"
}

ensure_panel_service_unit() {
  mkdir -p "$PANEL_DIR"
  tee "/etc/systemd/system/$PANEL_SERVICE.service" >/dev/null <<EOF2
[Unit]
Description=Telemt Panel
After=network.target

[Service]
Type=simple
ExecStart=$PANEL_BINARY --config $PANEL_CONFIG
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF2
  systemctl daemon-reload
}

create_panel_config_if_missing() {
  local telemt_auth="$1"
  if [ -f "$PANEL_CONFIG" ]; then
    return 0
  fi
  local admin_user admin_pass admin_pass2 pass_hash jwt_secret
  admin_user="$(ask 'Логин администратора панели' 'admin')"
  while true; do
    admin_pass="$(ask_secret 'Пароль администратора панели')"
    admin_pass2="$(ask_secret 'Повторите пароль администратора панели')"
    [ "$admin_pass" = "$admin_pass2" ] && break
    warn "Пароли не совпадают, попробуйте ещё раз"
  done
  pass_hash="$(printf '%s' "$admin_pass" | "$PANEL_BINARY" hash-password)"
  jwt_secret="$(openssl rand -hex 32)"
  mkdir -p "$PANEL_DIR"
  cat > "$PANEL_CONFIG" <<EOF2
listen = "0.0.0.0:8080"

[telemt]
url = "http://127.0.0.1:9091"
auth_header = "$telemt_auth"

[panel]
binary_path = "$PANEL_BINARY"
service_name = "$PANEL_SERVICE"

[auth]
username = "$admin_user"
password_hash = "$pass_hash"
jwt_secret = "$jwt_secret"
session_ttl = "24h"
EOF2
  chmod 600 "$PANEL_CONFIG"
}

sync_panel_config() {
  local mode="$1"
  local auth_override="${2-__KEEP__}"
  require_file "$PANEL_CONFIG"
  python3 - "$PANEL_CONFIG" "$mode" "$auth_override" "$NATIVE_BINARY" "$NATIVE_SERVICE" "$PANEL_BINARY" "$PANEL_SERVICE" <<'PY'
from pathlib import Path
import sys
cfg = Path(sys.argv[1])
mode = sys.argv[2]
auth_override = sys.argv[3]
native_binary = sys.argv[4]
native_service = sys.argv[5]
panel_binary = sys.argv[6]
panel_service = sys.argv[7]
text = cfg.read_text(encoding='utf-8', errors='ignore')
lines = text.splitlines()

current_auth = ''
in_telemt = False
for line in lines:
    s = line.strip()
    if s == '[telemt]':
        in_telemt = True
        continue
    if in_telemt and s.startswith('[') and s != '[telemt]':
        in_telemt = False
    if in_telemt and s.startswith('auth_header ='):
        current_auth = s.split('=', 1)[1].strip().strip('"')
        break
new_auth = current_auth if auth_override == '__KEEP__' else auth_override

out = []
in_telemt = False
in_panel = False
saw_telemt = saw_panel = False
telemt_url_done = telemt_auth_done = False
telemt_bin_done = telemt_srv_done = False
panel_bin_done = panel_srv_done = False

for line in lines:
    s = line.strip()

    if s == '[telemt]':
        saw_telemt = True
        in_telemt = True
        in_panel = False
        out.append(line)
        continue

    if s == '[panel]':
        saw_panel = True
        in_panel = True
        in_telemt = False
        out.append(line)
        continue

    if in_telemt and s.startswith('[') and s != '[telemt]':
        if not telemt_url_done:
            out.append('url = "http://127.0.0.1:9091"')
        if not telemt_auth_done:
            out.append(f'auth_header = "{new_auth}"')
        if mode == 'native':
            if not telemt_bin_done:
                out.append(f'binary_path = "{native_binary}"')
            if not telemt_srv_done:
                out.append(f'service_name = "{native_service}"')
        in_telemt = False
        out.append(line)
        continue

    if in_panel and s.startswith('[') and s != '[panel]':
        if not panel_bin_done:
            out.append(f'binary_path = "{panel_binary}"')
        if not panel_srv_done:
            out.append(f'service_name = "{panel_service}"')
        in_panel = False
        out.append(line)
        continue

    if in_telemt:
        if s.startswith('url ='):
            out.append('url = "http://127.0.0.1:9091"')
            telemt_url_done = True
            continue
        if s.startswith('auth_header ='):
            out.append(f'auth_header = "{new_auth}"')
            telemt_auth_done = True
            continue
        if s.startswith('binary_path ='):
            if mode == 'native':
                out.append(f'binary_path = "{native_binary}"')
                telemt_bin_done = True
            continue
        if s.startswith('service_name ='):
            if mode == 'native':
                out.append(f'service_name = "{native_service}"')
                telemt_srv_done = True
            continue
        out.append(line)
        continue

    if in_panel:
        if s.startswith('binary_path ='):
            out.append(f'binary_path = "{panel_binary}"')
            panel_bin_done = True
            continue
        if s.startswith('service_name ='):
            out.append(f'service_name = "{panel_service}"')
            panel_srv_done = True
            continue
        out.append(line)
        continue

    out.append(line)

if in_telemt:
    if not telemt_url_done:
        out.append('url = "http://127.0.0.1:9091"')
    if not telemt_auth_done:
        out.append(f'auth_header = "{new_auth}"')
    if mode == 'native':
        if not telemt_bin_done:
            out.append(f'binary_path = "{native_binary}"')
        if not telemt_srv_done:
            out.append(f'service_name = "{native_service}"')

if in_panel:
    if not panel_bin_done:
        out.append(f'binary_path = "{panel_binary}"')
    if not panel_srv_done:
        out.append(f'service_name = "{panel_service}"')

if not saw_telemt:
    out.extend(['', '[telemt]', 'url = "http://127.0.0.1:9091"', f'auth_header = "{new_auth}"'])
    if mode == 'native':
        out.append(f'binary_path = "{native_binary}"')
        out.append(f'service_name = "{native_service}"')

if not saw_panel:
    out.extend(['', '[panel]', f'binary_path = "{panel_binary}"', f'service_name = "{panel_service}"'])

cfg.write_text('\n'.join(out).rstrip() + '\n', encoding='utf-8')
PY
  chmod 600 "$PANEL_CONFIG"
}

first_user_secret() {
  local cfg="$1"
  python3 - "$cfg" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding='utf-8', errors='ignore')
m = re.search(r'^\s*\[access\.users\]\s*$', text, flags=re.M)
if not m:
    raise SystemExit(0)
rest = text[m.end():]
for line in rest.splitlines():
    s = line.strip()
    if not s or s.startswith('#'):
        continue
    if s.startswith('['):
        break
    m2 = re.match(r'^\s*"?([A-Za-z0-9_.-]+)"?\s*=\s*"([0-9a-fA-F]{32})"\s*$', line)
    if m2:
        print(m2.group(2))
        break
PY
}

tls_domain_from_cfg() {
  local cfg="$1"
  python3 - "$cfg" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding='utf-8', errors='ignore')
m = re.search(r'^\s*tls_domain\s*=\s*"([^"]+)"\s*$', text, flags=re.M)
if m:
    print(m.group(1))
PY
}

wait_for_port() {
  local port="$1"
  local tries="${2:-20}"
  local i
  for i in $(seq 1 "$tries"); do
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":$port$"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

is_native_present() {
  [ -f "$NATIVE_CONFIG" ] || [ -f "/etc/systemd/system/$NATIVE_SERVICE.service" ] || [ -x "$NATIVE_BINARY" ]
}

is_native_running() {
  systemctl is-active --quiet "$NATIVE_SERVICE" 2>/dev/null
}

is_docker_present() {
  [ -f "$WORK_DIR/docker-compose.yml" ] || docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$DOCKER_CONTAINER"
}

is_docker_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$DOCKER_CONTAINER"
}

is_panel_present() {
  [ -x "$PANEL_BINARY" ] || [ -f "$PANEL_CONFIG" ] || [ -f "/etc/systemd/system/$PANEL_SERVICE.service" ]
}

is_panel_running() {
  systemctl is-active --quiet "$PANEL_SERVICE" 2>/dev/null
}

detect_mode() {
  if is_docker_running; then
    printf 'docker'
  elif is_native_running; then
    printf 'native'
  elif is_docker_present && is_native_present; then
    printf 'both'
  elif is_docker_present; then
    printf 'docker'
  elif is_native_present; then
    printf 'native'
  else
    printf 'none'
  fi
}

choose_existing_mode() {
  local mode
  mode="$(detect_mode)"
  case "$mode" in
    native|docker)
      printf '%s' "$mode"
      ;;
    both)
      say 'Обнаружены и служба, и Docker-артефакты.'
      say '  1) Служба'
      say '  2) Docker'
      case "$(ask_menu 'Выберите (1-2)')" in
        1) printf 'native' ;;
        2) printf 'docker' ;;
        *) die 'Неверный выбор' ;;
      esac
      ;;
    none)
      die 'Telemt не найден' ;;
  esac
}

print_links() {
  local cfg mode domain secret ip hex hostip
  mode="$(detect_mode)"
  if [ "$mode" = 'docker' ] && [ -f "$WORK_DIR/config.toml" ]; then
    cfg="$WORK_DIR/config.toml"
  elif [ -f "$NATIVE_CONFIG" ]; then
    cfg="$NATIVE_CONFIG"
  elif [ -f "$WORK_DIR/config.toml" ]; then
    cfg="$WORK_DIR/config.toml"
  else
    warn 'Не удалось определить конфиг Telemt для ссылок'
    return 0
  fi
  domain="$(tls_domain_from_cfg "$cfg")"
  secret="$(first_user_secret "$cfg")"
  ip="$(curl -fsS --max-time 10 -4 ifconfig.me 2>/dev/null || true)"
  hostip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  say '═════════════════════════════════════════════════════'
  if [ -n "$domain" ] && [ -n "$secret" ] && [ -n "$ip" ]; then
    hex="$(printf '%s' "$domain" | od -An -tx1 -v | tr -d ' \n')"
    say "🔗 TELEGRAM: tg://proxy?server=$ip&port=443&secret=ee${secret}${hex}"
  else
    say '🔗 TELEGRAM: не удалось собрать автоматически'
  fi
  if is_panel_present; then
    say "🌐 ПАНЕЛЬ:   http://${hostip:-<IP_СЕРВЕРА>}:8080"
  fi
  say '═════════════════════════════════════════════════════'
}

show_status_and_links() {
  local mode
  mode="$(detect_mode)"
  say '═════════════════════════════════════════════════════'
  say 'Статус Telemt'
  say '═════════════════════════════════════════════════════'
  case "$mode" in
    native) say 'Режим: Служба' ;;
    docker) say 'Режим: Docker' ;;
    both) say 'Режим: Обнаружены и служба, и Docker-артефакты' ;;
    none) say 'Режим: Telemt не найден' ;;
  esac
  say "Служба telemt:       $(systemctl is-active "$NATIVE_SERVICE" 2>/dev/null || echo inactive)"
  say "Панель telemt-panel: $(systemctl is-active "$PANEL_SERVICE" 2>/dev/null || echo inactive)"
  if is_docker_present; then
    say 'Docker контейнер:'
    docker ps -a --filter "name=^/${DOCKER_CONTAINER}$" --format '  {{.Names}}  {{.Status}}  {{.Ports}}' || true
  fi
  print_links
}

auto_cleanup() {
  say '🧹 Авто-очистка мусора...'
  rm -rf "$BUILD_DIR" 2>/dev/null || true
  docker builder prune -f >/dev/null 2>&1 || true
  docker image prune -f >/dev/null 2>&1 || true
}

safe_cleanup_only() {
  auto_cleanup
  say '✅ Очистка завершена'
}

start_or_restart_backend_for_mode() {
  local mode="$1"
  if [ "$mode" = 'native' ]; then
    require_file "$NATIVE_CONFIG"
    patch_telemt_api "$NATIVE_CONFIG" native
    chown "$NATIVE_USER:$NATIVE_USER" "$NATIVE_CONFIG" 2>/dev/null || true
    chmod 640 "$NATIVE_CONFIG" 2>/dev/null || chmod 600 "$NATIVE_CONFIG"
    install_native_service_unit
    start_native_service
  else
    require_file "$WORK_DIR/config.toml"
    patch_telemt_api "$WORK_DIR/config.toml" docker
    start_docker_stack
  fi
  wait_for_port 9091 20 || warn 'Порт 9091 не начал слушаться вовремя'
}

install_or_update_panel_for_mode() {
  local mode="$1"
  local telemt_auth="$2"
  install_panel_binary
  ensure_panel_service_unit
  create_panel_config_if_missing "$telemt_auth"
  sync_panel_config "$mode" "$telemt_auth"
  systemctl enable --now "$PANEL_SERVICE"
}

repair_panel_flow() {
  local mode telemt_auth
  mode="$(choose_existing_mode)"
  start_or_restart_backend_for_mode "$mode"
  telemt_auth="$(ask 'Telemt API auth header для панели (Enter = оставить как есть / пустым)' '')"
  if [ -f "$PANEL_CONFIG" ] && [ -z "$telemt_auth" ]; then
    install_or_update_panel_for_mode "$mode" "$(python3 - "$PANEL_CONFIG" <<'PY'
from pathlib import Path
import re, sys
p=Path(sys.argv[1])
text=p.read_text(encoding='utf-8', errors='ignore') if p.exists() else ''
m=re.search(r'(?ms)^\[telemt\].*?^auth_header\s*=\s*"([^"]*)"', text)
print(m.group(1) if m else '')
PY
)"
  else
    install_or_update_panel_for_mode "$mode" "$telemt_auth"
  fi
  if [ "$mode" = 'docker' ]; then
    warn 'В Docker-режиме панель подходит для управления API и мониторинга. Обновлять сам Telemt лучше через этот скрипт.'
  fi
  auto_cleanup
  print_links
}

install_new_native() {
  local with_panel="$1"
  local channel domain secret telemt_auth
  channel="$(choose_source_channel)"
  domain="$(ask 'Домен маскировки' 'google.com')"
  secret="$(ask 'Секрет Telemt (32 hex, Enter = сгенерировать автоматически)' '')"
  [ -n "$secret" ] || secret="$(openssl rand -hex 16)"

  ensure_native_layout
  build_native_binary "$channel"
  mkdir -p /tmp/telemt-install
  write_base_telemt_config /tmp/telemt-install/telemt.toml "$domain" "$secret"
  patch_telemt_api /tmp/telemt-install/telemt.toml native
  mv /tmp/telemt-install/telemt.toml "$NATIVE_CONFIG"
  chown "$NATIVE_USER:$NATIVE_USER" "$NATIVE_CONFIG"
  chmod 640 "$NATIVE_CONFIG"
  install_native_service_unit
  start_native_service
  wait_for_port 9091 20 || warn 'Порт 9091 не начал слушаться вовремя'

  if [ "$with_panel" = 'yes' ]; then
    telemt_auth="$(ask 'Telemt API auth header для панели (если не используется — оставьте пустым)' '')"
    install_or_update_panel_for_mode native "$telemt_auth"
  fi

  auto_cleanup
  print_links
}

install_new_docker() {
  local method="$1"
  local with_panel="$2"
  local channel domain secret telemt_auth
  install_base_deps
  ensure_docker
  domain="$(ask 'Домен маскировки' 'google.com')"
  secret="$(ask 'Секрет Telemt (32 hex, Enter = сгенерировать автоматически)' '')"
  [ -n "$secret" ] || secret="$(openssl rand -hex 16)"

  mkdir -p "$WORK_DIR"
  write_base_telemt_config "$WORK_DIR/config.toml" "$domain" "$secret"
  patch_telemt_api "$WORK_DIR/config.toml" docker
  write_docker_compose

  if [ "$method" = 'build' ]; then
    channel="$(choose_source_channel)"
    build_docker_image "$channel"
  else
    docker pull "$DOCKER_IMAGE"
  fi

  start_docker_stack
  wait_for_port 9091 20 || warn 'Порт 9091 не начал слушаться вовремя'

  if [ "$with_panel" = 'yes' ]; then
    telemt_auth="$(ask 'Telemt API auth header для панели (если не используется — оставьте пустым)' '')"
    install_or_update_panel_for_mode docker "$telemt_auth"
    warn 'В Docker-режиме обновлять Telemt через веб-панель не стоит — используйте этот скрипт.'
  fi

  auto_cleanup
  print_links
}

update_native() {
  local channel
  require_file "$NATIVE_CONFIG"
  ensure_native_layout
  channel="$(choose_source_channel)"
  build_native_binary "$channel"
  patch_telemt_api "$NATIVE_CONFIG" native
  chown "$NATIVE_USER:$NATIVE_USER" "$NATIVE_CONFIG" 2>/dev/null || true
  chmod 640 "$NATIVE_CONFIG" 2>/dev/null || chmod 600 "$NATIVE_CONFIG"
  install_native_service_unit
  start_native_service
  if is_panel_present; then
    sync_panel_config native
    systemctl restart "$PANEL_SERVICE" || true
  fi
  auto_cleanup
  print_links
}

update_docker() {
  local method="$1"
  local channel
  require_file "$WORK_DIR/config.toml"
  install_base_deps
  ensure_docker
  patch_telemt_api "$WORK_DIR/config.toml" docker
  write_docker_compose
  if [ "$method" = 'build' ]; then
    channel="$(choose_source_channel)"
    build_docker_image "$channel"
  else
    docker pull "$DOCKER_IMAGE"
  fi
  start_docker_stack
  if is_panel_present; then
    sync_panel_config docker
    systemctl restart "$PANEL_SERVICE" || true
  fi
  auto_cleanup
  print_links
}

migrate_native_to_docker() {
  local method="$1"
  local channel
  require_file "$NATIVE_CONFIG"
  install_base_deps
  ensure_docker
  mkdir -p "$WORK_DIR"
  cp "$NATIVE_CONFIG" "$WORK_DIR/config.toml"
  chmod 644 "$WORK_DIR/config.toml" 2>/dev/null || true
  patch_telemt_api "$WORK_DIR/config.toml" docker
  write_docker_compose
  stop_native_service
  if [ "$method" = 'build' ]; then
    channel="$(choose_source_channel)"
    build_docker_image "$channel"
  else
    docker pull "$DOCKER_IMAGE"
  fi
  start_docker_stack
  if is_panel_present; then
    sync_panel_config docker
    systemctl restart "$PANEL_SERVICE" || true
  fi
  auto_cleanup
  print_links
}

migrate_docker_to_native() {
  local channel
  require_file "$WORK_DIR/config.toml"
  ensure_native_layout
  stop_docker_stack
  channel="$(choose_source_channel)"
  build_native_binary "$channel"
  cp "$WORK_DIR/config.toml" "$NATIVE_CONFIG"
  patch_telemt_api "$NATIVE_CONFIG" native
  chown "$NATIVE_USER:$NATIVE_USER" "$NATIVE_CONFIG"
  chmod 640 "$NATIVE_CONFIG"
  install_native_service_unit
  start_native_service
  if is_panel_present; then
    sync_panel_config native
    systemctl restart "$PANEL_SERVICE" || true
  fi
  auto_cleanup
  print_links
}

update_existing_menu() {
  local mode
  mode="$(choose_existing_mode)"
  case "$mode" in
    native)
      say 'Обнаружен режим: служба'
      say '  1) Обновить службу (сборка из исходников)'
      case "$(ask_menu 'Выберите (1)')" in
        1) update_native ;;
        *) die 'Неверный выбор' ;;
      esac
      ;;
    docker)
      say 'Обнаружен режим: Docker'
      say '  1) Обновить Docker (docker pull)'
      say '  2) Обновить Docker (сборка из исходников)'
      case "$(ask_menu 'Выберите (1-2)')" in
        1) update_docker pull ;;
        2) update_docker build ;;
        *) die 'Неверный выбор' ;;
      esac
      ;;
  esac
}

new_install_menu() {
  if [ "$(detect_mode)" != 'none' ]; then
    warn 'Обнаружен уже существующий Telemt. Новая установка может перезаписать текущий режим.'
    ask_confirm 'Продолжить новую установку' || return 0
  fi
  say 'Новая установка:'
  say '  1) Служба + панель'
  say '  2) Только служба'
  say '  3) Docker (docker pull) + панель'
  say '  4) Docker (сборка из исходников) + панель'
  say '  5) Docker (docker pull) без панели'
  say '  6) Docker (сборка из исходников) без панели'
  case "$(ask_menu 'Выберите (1-6)')" in
    1) install_new_native yes ;;
    2) install_new_native no ;;
    3) install_new_docker pull yes ;;
    4) install_new_docker build yes ;;
    5) install_new_docker pull no ;;
    6) install_new_docker build no ;;
    *) die 'Неверный выбор' ;;
  esac
}

remove_all() {
  ask_confirm 'Подтвердите полное удаление Telemt, панели, контейнера, бинарников и конфигов' || {
    say 'Удаление отменено'
    return 0
  }
  stop_docker_stack
  docker image rm "$DOCKER_IMAGE" >/dev/null 2>&1 || true
  systemctl stop "$PANEL_SERVICE" 2>/dev/null || true
  systemctl disable "$PANEL_SERVICE" 2>/dev/null || true
  rm -f "/etc/systemd/system/$PANEL_SERVICE.service"
  rm -rf "$PANEL_DIR"
  rm -f "$PANEL_BINARY"
  stop_native_service
  rm -f "/etc/systemd/system/$NATIVE_SERVICE.service"
  rm -rf "$NATIVE_DIR" "$NATIVE_HOME"
  rm -f "$NATIVE_BINARY"
  if id "$NATIVE_USER" >/dev/null 2>&1; then
    userdel -r "$NATIVE_USER" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
  systemctl daemon-reload
  auto_cleanup
  say '✅ Всё, что связано с Telemt и telemt-panel, удалено'
}

show_main_menu() {
  clear
  say '═════════════════════════════════════════════════════'
  say ' 🛠️  Telemt Manager'
  say '═════════════════════════════════════════════════════'
  say '1) Новая установка'
  say '2) Установить / обновить / починить панель'
  say '3) Обновить существующий Telemt'
  say '4) Миграция service → Docker'
  say '5) Миграция Docker → service'
  say '6) Показать статус и ссылки'
  say '7) Удалить всё, что связано с Telemt'
  say '8) Очистить мусор (ключи/ссылки не удаляются)'
  say '0) Выход'
}

main() {
  install_base_deps
  show_main_menu
  case "$(ask_menu 'Выберите пункт [0-8]')" in
    1) new_install_menu ;;
    2) repair_panel_flow ;;
    3) update_existing_menu ;;
    4)
      case "$(choose_existing_mode)" in
        native)
          say '  1) Docker (docker pull)'
          say '  2) Docker (сборка из исходников)'
          case "$(ask_menu 'Выберите (1-2)')" in
            1) migrate_native_to_docker pull ;;
            2) migrate_native_to_docker build ;;
            *) die 'Неверный выбор' ;;
          esac
          ;;
        docker) die 'Сейчас активен Docker. Для этого режима используйте пункт 5.' ;;
      esac
      ;;
    5)
      case "$(choose_existing_mode)" in
        docker) migrate_docker_to_native ;;
        native) die 'Сейчас активна служба. Для этого режима используйте пункт 4.' ;;
      esac
      ;;
    6) show_status_and_links ;;
    7) remove_all ;;
    8) safe_cleanup_only ;;
    0) say 'Выход' ;;
    *) die 'Неверный выбор' ;;
  esac
}

main "$@"
