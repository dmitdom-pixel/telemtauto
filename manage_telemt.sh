#!/usr/bin/env bash
set -euo pipefail

WORK_DIR="${HOME}/telemt-proxy"
BUILD_DIR="${WORK_DIR}/build_telemt"
NATIVE_USER="telemt"
NATIVE_HOME="/opt/telemt"
NATIVE_DIR="/etc/telemt"
NATIVE_CONFIG="${NATIVE_DIR}/telemt.toml"
NATIVE_BINARY="/bin/telemt"
NATIVE_SERVICE="telemt"
PANEL_DIR="/etc/telemt-panel"
PANEL_CONFIG="${PANEL_DIR}/config.toml"
PANEL_BINARY="/usr/local/bin/telemt-panel"
PANEL_SERVICE="telemt-panel"
DOCKER_IMAGE_REMOTE="ghcr.io/telemt/telemt:latest"
DOCKER_IMAGE_LOCAL="telemt-managed:local"
DOCKER_CONTAINER="telemt_proxy"
TTY_INPUT="/dev/tty"

[[ -r "$TTY_INPUT" ]] || TTY_INPUT="/dev/stdin"

say() { printf '%s\n' "$*"; }
warn() { printf '⚠️  %s\n' "$*" >&2; }
die() { printf '❌ %s\n' "$*" >&2; return 1; }

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Запускайте этот скрипт от root"
}

ask() {
  local prompt="${1:-}"
  local default="${2:-}"
  local answer
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " answer < "$TTY_INPUT"
    printf '%s' "${answer:-$default}"
  else
    read -r -p "$prompt: " answer < "$TTY_INPUT"
    printf '%s' "$answer"
  fi
}

ask_secret() {
  local prompt="${1:-}"
  local answer
  read -r -s -p "$prompt: " answer < "$TTY_INPUT"
  printf '\n' >&2
  printf '%s' "$answer"
}

pause_menu() {
  printf '\n' >&2
  read -r -p "Нажмите Enter, чтобы вернуться в главное меню..." _ < "$TTY_INPUT" || true
}

line() {
  printf '═════════════════════════════════════════════════════\n'
}

install_base_deps() {
  local pkgs=()
  local p

  for p in ca-certificates curl git grep gzip openssl passwd python3 sed tar util-linux; do
    dpkg -s "$p" >/dev/null 2>&1 || pkgs+=("$p")
  done

  if ! command -v awk >/dev/null 2>&1; then
    if apt-cache show mawk >/dev/null 2>&1; then
      pkgs+=("mawk")
    elif apt-cache show gawk >/dev/null 2>&1; then
      pkgs+=("gawk")
    else
      die "Не найден пакет, который предоставляет awk (mawk/gawk)"
    fi
  fi

  if [ ${#pkgs[@]} -gt 0 ]; then
    say "📦 Устанавливаем зависимости: ${pkgs[*]}"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -yqq "${pkgs[@]}"
  fi

  command -v awk >/dev/null 2>&1 || die "awk не найден после установки зависимостей"
}

ensure_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    say "📦 Устанавливаем jq"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -yqq jq
  fi
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    say "🐳 Устанавливаем Docker"
    curl -fsSL https://get.docker.com | sh
  fi

  if ! docker compose version >/dev/null 2>&1; then
    say "📦 Устанавливаем Docker Compose plugin v2"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -yqq docker-compose-plugin
  fi

  docker version >/dev/null 2>&1 || die "Docker установлен, но не работает"
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 не установлен"
}

compose() {
  docker compose "$@"
}

ensure_rust() {
  if command -v cargo >/dev/null 2>&1; then
    return 0
  fi

  say "🦀 Устанавливаем Rust toolchain"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  # shellcheck disable=SC1090
  source "$HOME/.cargo/env"
  command -v cargo >/dev/null 2>&1 || die "cargo не найден после установки Rust"
}

ensure_build_packages() {
  local pkgs=()
  local p
  for p in build-essential pkg-config libssl-dev; do
    dpkg -s "$p" >/dev/null 2>&1 || pkgs+=("$p")
  done
  if [ ${#pkgs[@]} -gt 0 ]; then
    say "📦 Устанавливаем пакеты сборки: ${pkgs[*]}"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -yqq "${pkgs[@]}"
  fi
}

service_exists() {
  systemctl list-unit-files | grep -q "^${NATIVE_SERVICE}\.service"
}

service_active() {
  systemctl is-active --quiet "$NATIVE_SERVICE" 2>/dev/null
}

panel_exists() {
  [[ -f "$PANEL_BINARY" || -f "$PANEL_CONFIG" || -f "/etc/systemd/system/${PANEL_SERVICE}.service" ]]
}

panel_active() {
  systemctl is-active --quiet "$PANEL_SERVICE" 2>/dev/null
}

docker_mode_exists() {
  [[ -f "${WORK_DIR}/docker-compose.yml" || -f "${WORK_DIR}/config.toml" ]] || docker ps -a --format '{{.Names}}' | grep -qx "$DOCKER_CONTAINER"
}

docker_mode_active() {
  docker ps --format '{{.Names}}' | grep -qx "$DOCKER_CONTAINER"
}

get_first_ip() {
  local ip
  ip=$(curl -fsS --max-time 5 -4 ifconfig.me 2>/dev/null || true)
  if [[ -z "$ip" ]]; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  fi
  printf '%s' "$ip"
}

get_domain_from_config() {
  local cfg="$1"
  python3 - "$cfg" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
if not p.exists():
    raise SystemExit(0)
text = p.read_text(encoding='utf-8', errors='ignore')
m = re.search(r'^tls_domain\s*=\s*"([^"]+)"', text, re.M)
print(m.group(1) if m else "")
PY
}

get_secret_from_config() {
  local cfg="$1"
  python3 - "$cfg" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
if not p.exists():
    raise SystemExit(0)
text = p.read_text(encoding='utf-8', errors='ignore')
for m in re.finditer(r'^([A-Za-z0-9_.-]+)\s*=\s*"([0-9a-fA-F]{32})"', text, re.M):
    key, val = m.groups()
    if key not in {"ad_tag"}:
        print(val)
        break
PY
}

print_links_for_config() {
  local cfg="$1"
  [[ -f "$cfg" ]] || { warn "Конфиг не найден: $cfg"; return 0; }

  local domain secret ip hex
  domain=$(get_domain_from_config "$cfg")
  secret=$(get_secret_from_config "$cfg")
  ip=$(get_first_ip)

  line
  if [[ -n "$domain" && -n "$secret" && -n "$ip" ]]; then
    hex=$(printf '%s' "$domain" | hexdump -v -e '/1 "%02x"')
    say "🔗 TELEGRAM: tg://proxy?server=${ip}&port=443&secret=ee${secret}${hex}"
  else
    warn "Не удалось собрать Telegram-ссылку из $cfg"
  fi

  if panel_exists; then
    if [[ -n "$ip" ]]; then
      say "🌐 ПАНЕЛЬ:   http://${ip}:8080"
    else
      say "🌐 ПАНЕЛЬ:   http://<IP_СЕРВЕРА>:8080"
    fi
  fi
  line
}

cleanup_after_actions() {
  say "🧹 Автоочистка мусора"
  rm -rf "$BUILD_DIR" 2>/dev/null || true
  if command -v docker >/dev/null 2>&1; then
    docker builder prune -f >/dev/null 2>&1 || true
    docker image prune -f >/dev/null 2>&1 || true
  fi
  say "✅ Мусор очищен. Конфиги, ключи и ссылки сохранены"
}

choose_from_menu() {
  local title="$1"
  shift
  local options=("$@")
  local idx answer count
  count=${#options[@]}

  printf '\n%s\n' "$title" >&2
  idx=1
  for opt in "${options[@]}"; do
    printf '%d) %s\n' "$idx" "$opt" >&2
    idx=$((idx + 1))
  done

  while true; do
    answer=$(ask "Выберите пункт" "1")
    if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= count )); then
      printf '%s' "$answer"
      return 0
    fi
    warn "Неверный выбор"
  done
}

choose_service_channel() {
  local ch
  ch=$(choose_from_menu "Какую версию службы установить / обновить?" "Stable release (рекомендуется)" "Latest из исходников (main)")
  if [[ "$ch" == "1" ]]; then
    printf 'stable'
  else
    printf 'latest'
  fi
}

choose_docker_source() {
  local ch
  ch=$(choose_from_menu "Как получить Docker-образ Telemt?" "Docker pull (ghcr latest)" "Сборка из исходников")
  if [[ "$ch" == "1" ]]; then
    printf 'pull'
  else
    printf 'build'
  fi
}

choose_build_channel() {
  local ch
  ch=$(choose_from_menu "Какую ветку собрать?" "Stable release tag" "Latest main")
  if [[ "$ch" == "1" ]]; then
    printf 'stable'
  else
    printf 'latest'
  fi
}

choose_existing_mode() {
  local has_service=0 has_docker=0
  service_exists && has_service=1
  docker_mode_exists && has_docker=1

  if (( has_service == 1 && has_docker == 0 )); then
    printf 'service'
    return 0
  fi
  if (( has_service == 0 && has_docker == 1 )); then
    printf 'docker'
    return 0
  fi
  if (( has_service == 0 && has_docker == 0 )); then
    printf 'none'
    return 0
  fi

  local ch
  ch=$(choose_from_menu "Обнаружены и служба, и Docker. К чему привязать операцию?" "Служба" "Docker")
  if [[ "$ch" == "1" ]]; then
    printf 'service'
  else
    printf 'docker'
  fi
}

ensure_native_user() {
  if ! id "$NATIVE_USER" >/dev/null 2>&1; then
    useradd -d "$NATIVE_HOME" -m -r -U "$NATIVE_USER"
  fi
  mkdir -p "$NATIVE_DIR"
  chown -R "$NATIVE_USER:$NATIVE_USER" "$NATIVE_DIR"
}

latest_release_tag() {
  ensure_jq
  curl -fsSL https://api.github.com/repos/telemt/telemt/releases/latest | jq -r '.tag_name'
}

panel_latest_release_tag() {
  ensure_jq
  curl -fsSL https://api.github.com/repos/amirotin/telemt_panel/releases/latest | jq -r '.tag_name'
}

clone_telemt_repo() {
  local channel="$1"
  rm -rf "$BUILD_DIR"
  git clone https://github.com/telemt/telemt.git "$BUILD_DIR" >/dev/null 2>&1
  cd "$BUILD_DIR"
  if [[ "$channel" == "stable" ]]; then
    local tag
    tag=$(git tag --sort=-v:refname | head -n1)
    [[ -n "$tag" ]] || die "Не удалось определить stable tag"
    git checkout "$tag" >/dev/null 2>&1
  else
    git checkout main >/dev/null 2>&1 || true
  fi
}

create_base_telemt_config() {
  local cfg="$1"
  local domain="$2"
  local secret="$3"

  mkdir -p "$(dirname "$cfg")"
  cat > "$cfg" <<EOF_CFG
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
hello = "$secret"
EOF_CFG
}

set_server_api_block() {
  local cfg="$1"
  local mode="$2"
  python3 - "$cfg" "$mode" <<'PY'
from pathlib import Path
import sys
cfg = Path(sys.argv[1])
mode = sys.argv[2]
text = cfg.read_text(encoding='utf-8', errors='ignore') if cfg.exists() else ''
if mode == 'service':
    block = '''[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32"]
minimal_runtime_enabled = false
minimal_runtime_cache_ttl_ms = 1000
'''
else:
    block = '''[server.api]
enabled = true
listen = "0.0.0.0:9090"
whitelist = ["127.0.0.0/8", "172.16.0.0/12"]
minimal_runtime_enabled = false
minimal_runtime_cache_ttl_ms = 1000
'''
lines = text.splitlines()
out = []
in_api = False
seen = False
for line in lines:
    s = line.strip()
    if s == '[server.api]':
        if not seen:
            out.extend(block.strip().splitlines())
            seen = True
        in_api = True
        continue
    if in_api and s.startswith('[') and s != '[server.api]':
        in_api = False
        out.append(line)
        continue
    if not in_api:
        out.append(line)
if not seen:
    if out and out[-1].strip() != '':
        out.append('')
    out.extend(block.strip().splitlines())
cfg.write_text('\n'.join(out).rstrip() + '\n', encoding='utf-8')
PY
}

write_native_service_file() {
  cat > "/etc/systemd/system/${NATIVE_SERVICE}.service" <<EOF_UNIT
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
EOF_UNIT
  systemctl daemon-reload
}

install_service_binary_stable() {
  local archive arch libc_tag tmpdir
  arch=$(uname -m)
  case "$arch" in
    x86_64|aarch64) ;;
    *) die "Неподдерживаемая архитектура: $arch" ;;
  esac
  if ldd --version 2>&1 | grep -qi musl; then
    libc_tag="musl"
  else
    libc_tag="gnu"
  fi
  archive="https://github.com/telemt/telemt/releases/latest/download/telemt-${arch}-linux-${libc_tag}.tar.gz"
  tmpdir=$(mktemp -d)
  curl -fsSL "$archive" -o "$tmpdir/telemt.tar.gz"
  tar -xzf "$tmpdir/telemt.tar.gz" -C "$tmpdir"
  install -m 0755 "$tmpdir/telemt" "$NATIVE_BINARY"
  rm -rf "$tmpdir"
}

install_service_binary_latest() {
  ensure_build_packages
  ensure_rust
  # shellcheck disable=SC1090
  source "$HOME/.cargo/env"
  clone_telemt_repo latest
  cargo build --release
  install -m 0755 "$BUILD_DIR/target/release/telemt" "$NATIVE_BINARY"
}

install_or_update_service_binary() {
  local channel="$1"
  if [[ "$channel" == "stable" ]]; then
    say "⬇️  Устанавливаем стабильный бинарник Telemt"
    install_service_binary_stable
  else
    say "🛠️  Собираем latest Telemt из исходников"
    install_service_binary_latest
  fi
}

install_or_update_service_stack() {
  local with_panel="$1"
  local channel="$2"
  local domain secret

  ensure_native_user
  install_or_update_service_binary "$channel"

  if [[ ! -f "$NATIVE_CONFIG" ]]; then
    domain=$(ask "Домен маскировки" "google.com")
    secret=$(openssl rand -hex 16)
    create_base_telemt_config "$NATIVE_CONFIG" "$domain" "$secret"
  fi

  set_server_api_block "$NATIVE_CONFIG" service
  chown "$NATIVE_USER:$NATIVE_USER" "$NATIVE_CONFIG"
  chmod 600 "$NATIVE_CONFIG"

  write_native_service_file
  systemctl enable --now "$NATIVE_SERVICE"
  sleep 1
  systemctl is-active --quiet "$NATIVE_SERVICE" || die "Служба Telemt не запустилась"

  if [[ "$with_panel" == "yes" ]]; then
    install_or_update_panel_for_mode service keep
  fi

  cleanup_after_actions
  print_links_for_config "$NATIVE_CONFIG"
}

write_docker_compose() {
  local image="$1"
  mkdir -p "$WORK_DIR"
  cat > "${WORK_DIR}/docker-compose.yml" <<EOF_DC
services:
  telemt:
    image: ${image}
    container_name: ${DOCKER_CONTAINER}
    restart: unless-stopped
    ports:
      - "443:443"
      - "127.0.0.1:9091:9090"
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
EOF_DC
}

ensure_docker_config() {
  local cfg="$1"
  local domain secret
  if [[ ! -f "$cfg" ]]; then
    domain=$(ask "Домен маскировки" "google.com")
    secret=$(openssl rand -hex 16)
    create_base_telemt_config "$cfg" "$domain" "$secret"
  fi
  set_server_api_block "$cfg" docker
}

build_docker_image_from_source() {
  local channel="$1"
  ensure_docker
  clone_telemt_repo "$channel"
  docker build -t "$DOCKER_IMAGE_LOCAL" "$BUILD_DIR"
}

stop_native_service_if_present() {
  if service_exists; then
    systemctl stop "$NATIVE_SERVICE" 2>/dev/null || true
    systemctl disable "$NATIVE_SERVICE" 2>/dev/null || true
  fi
}

stop_docker_stack_if_present() {
  if docker_mode_exists; then
    mkdir -p "$WORK_DIR"
    if [[ -f "${WORK_DIR}/docker-compose.yml" ]]; then
      (cd "$WORK_DIR" && compose down --remove-orphans) >/dev/null 2>&1 || true
    fi
    docker rm -f "$DOCKER_CONTAINER" >/dev/null 2>&1 || true
  fi
}

start_docker_stack() {
  local image="$1"
  ensure_docker
  write_docker_compose "$image"
  cd "$WORK_DIR"
  compose down --remove-orphans >/dev/null 2>&1 || true
  docker rm -f "$DOCKER_CONTAINER" >/dev/null 2>&1 || true
  compose up -d
  sleep 1
  docker ps --format '{{.Names}}' | grep -qx "$DOCKER_CONTAINER" || die "Docker-контейнер Telemt не запустился"
}

install_or_update_docker_stack() {
  local with_panel="$1"
  local source_kind="$2"
  local build_channel="${3:-}"
  local image="$DOCKER_IMAGE_REMOTE"

  ensure_docker
  mkdir -p "$WORK_DIR"
  ensure_docker_config "${WORK_DIR}/config.toml"

  if [[ "$source_kind" == "pull" ]]; then
    say "⬇️  Скачиваем Docker-образ Telemt"
    docker pull "$DOCKER_IMAGE_REMOTE"
    image="$DOCKER_IMAGE_REMOTE"
  else
    say "🛠️  Собираем Docker-образ Telemt из исходников"
    build_docker_image_from_source "$build_channel"
    image="$DOCKER_IMAGE_LOCAL"
  fi

  start_docker_stack "$image"

  if [[ "$with_panel" == "yes" ]]; then
    install_or_update_panel_for_mode docker keep
  fi

  cleanup_after_actions
  print_links_for_config "${WORK_DIR}/config.toml"
}

create_panel_placeholder_if_missing() {
  local mode="$1"
  local url="http://127.0.0.1:9091"
  local jwt
  mkdir -p "$PANEL_DIR"
  if [[ ! -f "$PANEL_CONFIG" ]]; then
    jwt=$(openssl rand -hex 32)
    cat > "$PANEL_CONFIG" <<EOF_PC
listen = "0.0.0.0:8080"

[telemt]
url = "$url"
auth_header = ""

[auth]
username = "admin"
password_hash = '
jwt_secret = "$jwt"
session_ttl = "24h"
EOF_PC
    chmod 600 "$PANEL_CONFIG"
  fi
  sync_panel_config "$mode"
}

install_panel_binary_via_official_installer() {
  local tmp
  tmp=$(mktemp)
  curl -fsSL https://raw.githubusercontent.com/amirotin/telemt_panel/main/install.sh -o "$tmp"
  bash "$tmp"
  rm -f "$tmp"
}

prompt_panel_credentials_and_write_config() {
  local mode="$1"
  local reset_creds="$2"
  local listen username password pass_hash jwt telemt_url telemt_auth existing_user existing_jwt existing_listen existing_auth

  listen=$(python3 - "$PANEL_CONFIG" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
text = p.read_text(encoding='utf-8', errors='ignore') if p.exists() else ''
m = re.search(r'^listen\s*=\s*"([^"]+)"', text, re.M)
print(m.group(1) if m else '0.0.0.0:8080')
PY
)
  existing_user=$(python3 - "$PANEL_CONFIG" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
text = p.read_text(encoding='utf-8', errors='ignore') if p.exists() else ''
m = re.search(r'^username\s*=\s*"([^"]+)"', text, re.M)
print(m.group(1) if m else 'admin')
PY
)
  existing_jwt=$(python3 - "$PANEL_CONFIG" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
text = p.read_text(encoding='utf-8', errors='ignore') if p.exists() else ''
m = re.search(r'^jwt_secret\s*=\s*"([^"]+)"', text, re.M)
print(m.group(1) if m else '')
PY
)
  existing_auth=$(python3 - "$PANEL_CONFIG" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
text = p.read_text(encoding='utf-8', errors='ignore') if p.exists() else ''
m = re.search(r'^auth_header\s*=\s*"([^"]*)"', text, re.M)
print(m.group(1) if m else '')
PY
)

  if [[ "$reset_creds" == "reset" || ! -f "$PANEL_CONFIG" ]]; then
    username=$(ask "Логин администратора панели" "$existing_user")
    while true; do
      password=$(ask_secret "Пароль администратора панели")
      [[ -n "$password" ]] && break
      warn "Пароль не может быть пустым"
    done
    jwt=$(openssl rand -hex 32)
    pass_hash=$($PANEL_BINARY hash-password <<< "$password")
  else
    username="$existing_user"
    jwt="${existing_jwt:-$(openssl rand -hex 32)}"
    pass_hash=$(python3 - "$PANEL_CONFIG" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
text = p.read_text(encoding='utf-8', errors='ignore') if p.exists() else ''
m = re.search(r'^password_hash\s*=\s*"([^"]+)"', text, re.M)
print(m.group(1) if m else '')
PY
)
    if [[ -z "$pass_hash" ]]; then
      username=$(ask "Логин администратора панели" "$existing_user")
      while true; do
        password=$(ask_secret "Пароль администратора панели")
        [[ -n "$password" ]] && break
        warn "Пароль не может быть пустым"
      done
      pass_hash=$($PANEL_BINARY hash-password <<< "$password")
      [[ -n "$jwt" ]] || jwt=$(openssl rand -hex 32)
    fi
  fi

  telemt_url="http://127.0.0.1:9091"
  telemt_auth="$existing_auth"

  mkdir -p "$PANEL_DIR"
  cat > "$PANEL_CONFIG" <<EOF_PCFG
listen = "$listen"

[telemt]
url = "$telemt_url"
auth_header = "$telemt_auth"
EOF_PCFG

  if [[ "$mode" == "service" ]]; then
    cat >> "$PANEL_CONFIG" <<EOF_PCFG
binary_path = "$NATIVE_BINARY"
service_name = "$NATIVE_SERVICE"
EOF_PCFG
  fi

  cat >> "$PANEL_CONFIG" <<EOF_PCFG

[auth]
username = "$username"
password_hash = "$pass_hash"
jwt_secret = "$jwt"
session_ttl = "24h"
EOF_PCFG

  chmod 600 "$PANEL_CONFIG"
}

sync_panel_config() {
  local mode="$1"
  python3 - "$PANEL_CONFIG" "$mode" "$NATIVE_BINARY" "$NATIVE_SERVICE" <<'PY'
from pathlib import Path
import sys
cfg = Path(sys.argv[1])
mode = sys.argv[2]
binary_path = sys.argv[3]
service_name = sys.argv[4]
if not cfg.exists():
    raise SystemExit(0)
text = cfg.read_text(encoding='utf-8', errors='ignore')
lines = text.splitlines()
out = []
in_telemt = False
seen = False
for line in lines:
    s = line.strip()
    if s == '[telemt]':
        if not seen:
            out.append('[telemt]')
            out.append('url = "http://127.0.0.1:9091"')
            out.append('auth_header = ""' if 'auth_header' not in text else None)
            if mode == 'service':
                out.append(f'binary_path = "{binary_path}"')
                out.append(f'service_name = "{service_name}"')
            seen = True
        in_telemt = True
        continue
    if in_telemt and s.startswith('[') and s != '[telemt]':
        in_telemt = False
        out.append(line)
        continue
    if not in_telemt:
        out.append(line)
if not seen:
    if out and out[-1] != '':
        out.append('')
    out.append('[telemt]')
    out.append('url = "http://127.0.0.1:9091"')
    out.append('auth_header = ""')
    if mode == 'service':
        out.append(f'binary_path = "{binary_path}"')
        out.append(f'service_name = "{service_name}"')
out = [x for x in out if x is not None]
# ensure telemt block contains auth_header and optional service fields
result = []
in_telemt = False
has_auth = has_bin = has_srv = False
for line in out:
    s = line.strip()
    if s == '[telemt]':
        in_telemt = True
        has_auth = has_bin = has_srv = False
        result.append(line)
        continue
    if in_telemt and s.startswith('[') and s != '[telemt]':
        if not has_auth:
            result.append('auth_header = ""')
        if mode == 'service':
            if not has_bin:
                result.append(f'binary_path = "{binary_path}"')
            if not has_srv:
                result.append(f'service_name = "{service_name}"')
        in_telemt = False
        result.append(line)
        continue
    if in_telemt:
        if s.startswith('url = '):
            result.append('url = "http://127.0.0.1:9091"')
            continue
        if s.startswith('auth_header = '):
            result.append(line)
            has_auth = True
            continue
        if s.startswith('binary_path = '):
            if mode == 'service':
                result.append(f'binary_path = "{binary_path}"')
                has_bin = True
            continue
        if s.startswith('service_name = '):
            if mode == 'service':
                result.append(f'service_name = "{service_name}"')
                has_srv = True
            continue
        result.append(line)
        continue
    result.append(line)
if in_telemt:
    if not has_auth:
        result.append('auth_header = ""')
    if mode == 'service':
        if not has_bin:
            result.append(f'binary_path = "{binary_path}"')
        if not has_srv:
            result.append(f'service_name = "{service_name}"')
cfg.write_text('\n'.join(result).rstrip() + '\n', encoding='utf-8')
PY
}

install_or_update_panel_for_mode() {
  local mode="$1"
  local creds_mode="${2:-keep}"

  create_panel_placeholder_if_missing "$mode"
  install_panel_binary_via_official_installer

  if [[ "$creds_mode" == "reset" || ! -s "$PANEL_CONFIG" ]]; then
    prompt_panel_credentials_and_write_config "$mode" reset
  else
    prompt_panel_credentials_and_write_config "$mode" keep
  fi

  sync_panel_config "$mode"
  systemctl daemon-reload
  systemctl enable --now "$PANEL_SERVICE"
  sleep 1
  systemctl is-active --quiet "$PANEL_SERVICE" || warn "Панель не запустилась, проверьте journalctl -u ${PANEL_SERVICE}"
}

remove_panel_everything() {
  systemctl stop "$PANEL_SERVICE" 2>/dev/null || true
  systemctl disable "$PANEL_SERVICE" 2>/dev/null || true
  rm -f "/etc/systemd/system/${PANEL_SERVICE}.service"
  systemctl daemon-reload
  rm -rf "$PANEL_DIR"
  rm -f "$PANEL_BINARY"
  say "✅ Панель удалена"
}

panel_menu() {
  while true; do
    line
    say "🧩 Управление панелью"
    line
    say "1) Установить / обновить / починить панель"
    say "2) Сбросить логин / пароль панели"
    say "3) Удалить панель"
    say "0) Назад"
    local choice mode
    choice=$(ask "Выберите пункт" "1")
    case "$choice" in
      1)
        mode=$(choose_existing_mode)
        [[ "$mode" != "none" ]] || { warn "Сначала установите Telemt (службу или Docker)"; pause_menu; continue; }
        install_or_update_panel_for_mode "$mode" keep
        cleanup_after_actions
        pause_menu
        ;;
      2)
        mode=$(choose_existing_mode)
        [[ "$mode" != "none" ]] || { warn "Сначала установите Telemt (службу или Docker)"; pause_menu; continue; }
        install_or_update_panel_for_mode "$mode" reset
        cleanup_after_actions
        pause_menu
        ;;
      3)
        remove_panel_everything
        cleanup_after_actions
        pause_menu
        ;;
      0)
        return 0
        ;;
      *)
        warn "Неверный выбор"
        ;;
    esac
  done
}

new_install_menu() {
  while true; do
    line
    say "📦 Новая установка"
    line
    say "1) Служба + панель"
    say "2) Только служба"
    say "3) Docker + панель"
    say "4) Только Docker"
    say "0) Назад"

    local choice channel source_kind build_channel
    choice=$(ask "Выберите пункт" "1")
    case "$choice" in
      1)
        channel=$(choose_service_channel)
        install_or_update_service_stack yes "$channel"
        pause_menu
        return 0
        ;;
      2)
        channel=$(choose_service_channel)
        install_or_update_service_stack no "$channel"
        pause_menu
        return 0
        ;;
      3)
        source_kind=$(choose_docker_source)
        build_channel=""
        if [[ "$source_kind" == "build" ]]; then
          build_channel=$(choose_build_channel)
        fi
        install_or_update_docker_stack yes "$source_kind" "$build_channel"
        pause_menu
        return 0
        ;;
      4)
        source_kind=$(choose_docker_source)
        build_channel=""
        if [[ "$source_kind" == "build" ]]; then
          build_channel=$(choose_build_channel)
        fi
        install_or_update_docker_stack no "$source_kind" "$build_channel"
        pause_menu
        return 0
        ;;
      0)
        return 0
        ;;
      *)
        warn "Неверный выбор"
        ;;
    esac
  done
}

update_existing_telemt_menu() {
  local mode
  mode=$(choose_existing_mode)
  if [[ "$mode" == "none" ]]; then
    warn "Не найден существующий Telemt"
    pause_menu
    return 0
  fi

  if [[ "$mode" == "service" ]]; then
    local channel
    channel=$(choose_service_channel)
    install_or_update_service_stack no "$channel"
  else
    local source_kind build_channel
    source_kind=$(choose_docker_source)
    build_channel=""
    if [[ "$source_kind" == "build" ]]; then
      build_channel=$(choose_build_channel)
    fi
    install_or_update_docker_stack no "$source_kind" "$build_channel"
  fi
  pause_menu
}

migrate_service_to_docker() {
  service_exists || die "Служба Telemt не найдена"
  local source_kind build_channel
  source_kind=$(choose_docker_source)
  build_channel=""
  if [[ "$source_kind" == "build" ]]; then
    build_channel=$(choose_build_channel)
  fi

  mkdir -p "$WORK_DIR"
  if [[ -f "$NATIVE_CONFIG" ]]; then
    cp "$NATIVE_CONFIG" "${WORK_DIR}/config.toml"
  else
    ensure_docker_config "${WORK_DIR}/config.toml"
  fi
  set_server_api_block "${WORK_DIR}/config.toml" docker

  stop_native_service_if_present
  install_or_update_docker_stack no "$source_kind" "$build_channel"
  if panel_exists; then
    install_or_update_panel_for_mode docker keep
  fi
  cleanup_after_actions
  print_links_for_config "${WORK_DIR}/config.toml"
}

migrate_docker_to_service() {
  docker_mode_exists || die "Docker-режим Telemt не найден"
  local channel
  channel=$(choose_service_channel)

  ensure_native_user
  if [[ -f "${WORK_DIR}/config.toml" ]]; then
    cp "${WORK_DIR}/config.toml" "$NATIVE_CONFIG"
  fi
  if [[ ! -f "$NATIVE_CONFIG" ]]; then
    local domain secret
    domain=$(ask "Домен маскировки" "google.com")
    secret=$(openssl rand -hex 16)
    create_base_telemt_config "$NATIVE_CONFIG" "$domain" "$secret"
  fi
  set_server_api_block "$NATIVE_CONFIG" service
  chown "$NATIVE_USER:$NATIVE_USER" "$NATIVE_CONFIG"
  chmod 600 "$NATIVE_CONFIG"

  stop_docker_stack_if_present
  install_or_update_service_stack no "$channel"
  if panel_exists; then
    install_or_update_panel_for_mode service keep
  fi
  cleanup_after_actions
  print_links_for_config "$NATIVE_CONFIG"
}

show_status_and_links() {
  line
  say "📊 Статус Telemt"
  line
  if service_exists; then
    if service_active; then
      say "Служба:       active"
    else
      say "Служба:       installed, but inactive"
    fi
  else
    say "Служба:       not installed"
  fi

  if docker_mode_exists; then
    if docker_mode_active; then
      say "Docker:       active"
    else
      say "Docker:       installed, but inactive"
    fi
  else
    say "Docker:       not installed"
  fi

  if panel_exists; then
    if panel_active; then
      say "Панель:       active"
    else
      say "Панель:       installed, but inactive"
    fi
  else
    say "Панель:       not installed"
  fi

  say "Native config: ${NATIVE_CONFIG}"
  say "Docker config: ${WORK_DIR}/config.toml"
  say "Panel config:  ${PANEL_CONFIG}"
  printf '\n'

  if docker_mode_exists && [[ -f "${WORK_DIR}/config.toml" ]]; then
    say "Docker-ссылки:"
    print_links_for_config "${WORK_DIR}/config.toml"
  elif [[ -f "$NATIVE_CONFIG" ]]; then
    say "Ссылки службы:"
    print_links_for_config "$NATIVE_CONFIG"
  else
    warn "Конфиг Telemt не найден"
  fi

  pause_menu
}

remove_everything() {
  local confirm
  confirm=$(ask "Подтвердите полное удаление Telemt и панели (да/нет)" "нет")
  [[ "$confirm" =~ ^([дД][аА]?|[yY][eE]?[sS]?)$ ]] || { say "Удаление отменено"; pause_menu; return 0; }

  stop_docker_stack_if_present
  docker rmi "$DOCKER_IMAGE_LOCAL" >/dev/null 2>&1 || true
  docker rmi "$DOCKER_IMAGE_REMOTE" >/dev/null 2>&1 || true

  stop_native_service_if_present
  rm -f "/etc/systemd/system/${NATIVE_SERVICE}.service"
  systemctl daemon-reload

  remove_panel_everything

  rm -rf "$WORK_DIR" "$NATIVE_DIR"
  rm -f "$NATIVE_BINARY"
  if id "$NATIVE_USER" >/dev/null 2>&1; then
    userdel -r "$NATIVE_USER" >/dev/null 2>&1 || true
  fi

  cleanup_after_actions
  say "✅ Всё, что связано с Telemt, удалено"
  pause_menu
}

safe_cleanup_only() {
  cleanup_after_actions
  pause_menu
}

main_menu() {
  while true; do
    clear || true
    line
    say " 🛠️  Telemt Manager"
    line
    say "1) Новая установка"
    say "2) Установить / обновить / починить панель"
    say "3) Обновить существующий Telemt"
    say "4) Миграция service → Docker"
    say "5) Миграция Docker → service"
    say "6) Показать статус и ссылки"
    say "7) Удалить всё, что связано с Telemt"
    say "8) Очистить мусор (ключи/ссылки не удаляются)"
    say "0) Выход"

    local choice
    choice=$(ask "Выберите пункт" "6")
    case "$choice" in
      1) new_install_menu ;;
      2) panel_menu ;;
      3) update_existing_telemt_menu ;;
      4) migrate_service_to_docker; pause_menu ;;
      5) migrate_docker_to_service; pause_menu ;;
      6) show_status_and_links ;;
      7) remove_everything ;;
      8) safe_cleanup_only ;;
      0) exit 0 ;;
      *) warn "Неверный выбор"; pause_menu ;;
    esac
  done
}

require_root
install_base_deps
main_menu
