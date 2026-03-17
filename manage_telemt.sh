#!/usr/bin/env bash
set -Eeuo pipefail

WORK_DIR="${HOME}/telemt-proxy"
BUILD_DIR="${WORK_DIR}/build_telemt"
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
PANEL_DEFAULT_PORT="8080"
TTY_INPUT="/dev/tty"
[[ -r "$TTY_INPUT" ]] || TTY_INPUT="/dev/stdin"

say() { printf '%s\n' "$*"; }
say_err() { printf '%s\n' "$*" >&2; }
warn() { printf '⚠️  %s\n' "$*" >&2; }
die() { printf '❌ %s\n' "$*" >&2; return 1; }
line() { printf '═════════════════════════════════════════════════════\n'; }

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
  local prompt="$1"
  local answer
  read -r -s -p "$prompt: " answer < "$TTY_INPUT"
  printf '\n' >&2
  printf '%s' "$answer"
}

pause_menu() {
  printf '\n' >&2
  read -r -p "Нажмите Enter, чтобы вернуться в меню..." _ < "$TTY_INPUT" || true
}

confirm() {
  local msg="$1"
  local ans
  ans=$(ask "$msg (да/нет)" "нет")
  [[ "$ans" =~ ^([дД][аА]?|[yY][eE]?[sS]?)$ ]]
}

install_base_deps() {
  local pkgs=()
  local p

  export DEBIAN_FRONTEND=noninteractive

  for p in ca-certificates curl git grep gzip openssl passwd python3 sed tar util-linux coreutils systemd; do
    dpkg -s "$p" >/dev/null 2>&1 || pkgs+=("$p")
  done

  if ! command -v awk >/dev/null 2>&1; then
    if apt-cache show mawk >/dev/null 2>&1; then
      pkgs+=("mawk")
    elif apt-cache show gawk >/dev/null 2>&1; then
      pkgs+=("gawk")
    fi
  fi

  if [ ${#pkgs[@]} -gt 0 ]; then
    say "📦 Устанавливаем зависимости: ${pkgs[*]}"
    apt-get update -qq
    apt-get install -yqq "${pkgs[@]}"
  fi

  command -v python3 >/dev/null 2>&1 || die "python3 не найден"
  command -v awk >/dev/null 2>&1 || die "awk не найден"
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

ensure_rust() {
  if command -v cargo >/dev/null 2>&1; then
    return 0
  fi
  say "🦀 Устанавливаем Rust"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  # shellcheck disable=SC1090
  source "$HOME/.cargo/env"
  command -v cargo >/dev/null 2>&1 || die "cargo не найден после установки Rust"
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return 0
  fi

  say "🐳 Подготавливаем Docker и Compose v2"
  export DEBIAN_FRONTEND=noninteractive

  # Сначала пробуем официальный install script — обычно это самый безболезненный путь.
  if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh || true
  fi

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return 0
  fi

  # Fallback: добавляем Docker repo и ставим пакеты.
  apt-get update -qq
  apt-get install -yqq ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi

  local distro codename repo_line
  distro="$(. /etc/os-release && echo "${ID}")"
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}")"
  [[ -n "$codename" ]] || die "Не удалось определить кодовое имя дистрибутива"

  repo_line="deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${distro} ${codename} stable"
  printf '%s\n' "$repo_line" > /etc/apt/sources.list.d/docker.list

  apt-get update -qq
  apt-get install -yqq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || \
  apt-get install -yqq docker-compose-plugin || true

  command -v docker >/dev/null 2>&1 || die "Docker не установлен"
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 не установлен"
}

compose() {
  docker compose "$@"
}

service_exists() {
  systemctl list-unit-files | grep -q "^${NATIVE_SERVICE}\.service"
}

service_active() {
  systemctl is-active --quiet "$NATIVE_SERVICE" 2>/dev/null
}

docker_mode_exists() {
  [[ -f "${WORK_DIR}/docker-compose.yml" || -f "${WORK_DIR}/config.toml" ]] && return 0
  command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' | grep -qx "$DOCKER_CONTAINER"
}

docker_mode_active() {
  command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' | grep -qx "$DOCKER_CONTAINER"
}

panel_exists() {
  [[ -f "$PANEL_BINARY" || -f "$PANEL_CONFIG" || -f "/etc/systemd/system/${PANEL_SERVICE}.service" ]]
}

panel_active() {
  systemctl is-active --quiet "$PANEL_SERVICE" 2>/dev/null
}

get_external_ip() {
  local ip
  ip=$(curl -fsS --max-time 5 -4 ifconfig.me 2>/dev/null || true)
  [[ -n "$ip" ]] || ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  printf '%s' "$ip"
}

python_edit_config() {
  local script="$1"
  shift
  python3 - "$@" <<PY
$script
PY
}

write_base_telemt_config() {
  local cfg="$1"
  local domain="$2"
  local secret="$3"
  mkdir -p "$(dirname "$cfg")"
  cat > "$cfg" <<EOF_CFG
tls_domain = "$domain"

[access.users]
main_user = "$secret"
EOF_CFG
}

patch_telemt_api() {
  local cfg="$1"
  local mode="$2"
  python3 - "$cfg" "$mode" <<'PY'
from pathlib import Path
import sys
cfg = Path(sys.argv[1])
mode = sys.argv[2]
text = cfg.read_text(encoding='utf-8', errors='ignore') if cfg.exists() else ''
if mode == 'native':
    block = [
        '[server.api]',
        'enabled = true',
        'listen = "127.0.0.1:9091"',
        'whitelist = ["127.0.0.0/8"]',
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
    if out and out[-1] != '':
        out.append('')
    out.extend(block)
cfg.write_text('\n'.join(out).rstrip() + '\n', encoding='utf-8')
PY
}

get_domain_from_config() {
  local cfg="$1"
  python3 - "$cfg" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
text = p.read_text(encoding='utf-8', errors='ignore') if p.exists() else ''
m = re.search(r'^tls_domain\s*=\s*"([^"]+)"', text, re.M)
print(m.group(1) if m else '')
PY
}

get_secret_from_config() {
  local cfg="$1"
  python3 - "$cfg" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
text = p.read_text(encoding='utf-8', errors='ignore') if p.exists() else ''
patterns = [
    r'^main_user\s*=\s*"([0-9a-fA-F]{32})"',
    r'^hello\s*=\s*"([0-9a-fA-F]{32})"',
]
for pat in patterns:
    m = re.search(pat, text, re.M)
    if m:
        print(m.group(1))
        break
else:
    m = re.search(r'^\s*main_user\s*=\s*"([^"]+)"', text, re.M)
    print(m.group(1) if m else '')
PY
}

print_links_for_config() {
  local cfg="$1"
  [[ -f "$cfg" ]] || { warn "Конфиг не найден: $cfg"; return 0; }
  local domain secret ip hex
  domain=$(get_domain_from_config "$cfg")
  secret=$(get_secret_from_config "$cfg")
  ip=$(get_external_ip)
  line
  say "📄 Конфиг: $cfg"
  if [[ -n "$domain" && -n "$secret" && -n "$ip" ]]; then
    hex=$(printf '%s' "$domain" | hexdump -v -e '/1 "%02x"')
    say "🔗 TELEGRAM: tg://proxy?server=${ip}&port=443&secret=ee${secret}${hex}"
  else
    warn "Не удалось собрать Telegram-ссылку"
  fi
  if panel_exists && [[ -n "$ip" ]]; then
    say "🌐 ПАНЕЛЬ:   http://${ip}:${PANEL_DEFAULT_PORT}"
  fi
  line
}

choose_branch_mode() {
  say_err ""
  say_err "Какую версию Telemt использовать?"
  say_err "1) Stable / LTS"
  say_err "2) Latest"
  local a
  a=$(ask "Выберите пункт" "1")
  case "$a" in
    1) printf 'stable' ;;
    2) printf 'latest' ;;
    *) warn "Неверный выбор, беру Stable / LTS"; printf 'stable' ;;
  esac
}

choose_docker_source() {
  say_err ""
  say_err "Как получить Docker-образ Telemt?"
  say_err "1) Docker pull (${DOCKER_IMAGE_REMOTE})"
  say_err "2) Сборка из исходников"
  local a
  a=$(ask "Выберите пункт" "1")
  case "$a" in
    1) printf 'pull' ;;
    2) printf 'build' ;;
    *) warn "Неверный выбор, беру Docker pull"; printf 'pull' ;;
  esac
}

clone_checkout_telemt() {
  local branch_mode="$1"
  rm -rf "$BUILD_DIR"
  mkdir -p "$WORK_DIR"
  git clone https://github.com/telemt/telemt.git "$BUILD_DIR"
  cd "$BUILD_DIR" || exit 1
  local tag=""
  if [[ "$branch_mode" == "stable" ]]; then
    tag=$(git tag --sort=-v:refname | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true)
  else
    tag=$(git tag --sort=-v:refname | head -n1 || true)
  fi
  if [[ -n "$tag" ]]; then
    git checkout "$tag"
  else
    git checkout main
  fi
}

build_native_binary() {
  local branch_mode="$1"
  install_base_deps
  ensure_build_packages
  ensure_rust
  # shellcheck disable=SC1090
  [[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
  clone_checkout_telemt "$branch_mode"
  cargo build --release
  install -m 0755 "$BUILD_DIR/target/release/telemt" "$NATIVE_BINARY"
}

build_docker_image_local() {
  local branch_mode="$1"
  install_base_deps
  ensure_docker
  clone_checkout_telemt "$branch_mode"
  docker build -t "$DOCKER_IMAGE_LOCAL" "$BUILD_DIR"
}

write_native_service_unit() {
  cat > "/etc/systemd/system/${NATIVE_SERVICE}.service" <<EOF_UNIT
[Unit]
Description=Telemt Proxy
After=network.target

[Service]
Type=simple
User=root
ExecStart=${NATIVE_BINARY} ${NATIVE_CONFIG}
Restart=on-failure
RestartSec=2
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF_UNIT
  systemctl daemon-reload
}

start_native_service() {
  write_native_service_unit
  systemctl enable --now "$NATIVE_SERVICE"
}

stop_native_service() {
  systemctl stop "$NATIVE_SERVICE" 2>/dev/null || true
  systemctl disable "$NATIVE_SERVICE" 2>/dev/null || true
}

write_docker_compose() {
  local image_ref="$1"
  mkdir -p "$WORK_DIR"
  cat > "$WORK_DIR/docker-compose.yml" <<EOF_DC
services:
  telemt:
    image: ${image_ref}
    container_name: ${DOCKER_CONTAINER}
    restart: unless-stopped
    ports:
      - "443:443"
      - "127.0.0.1:9091:9091"
      - "127.0.0.1:9090:9090"
    working_dir: /run/telemt
    volumes:
      - ./config.toml:/run/telemt/config.toml:ro
    tmpfs:
      - /run/telemt:rw,mode=1777,size=16m
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

start_docker_stack() {
  local image_ref="$1"
  ensure_docker
  write_docker_compose "$image_ref"
  cd "$WORK_DIR" || exit 1
  compose down --remove-orphans || true
  docker rm -f "$DOCKER_CONTAINER" >/dev/null 2>&1 || true
  compose up -d
}

stop_docker_stack() {
  if [[ -f "$WORK_DIR/docker-compose.yml" ]]; then
    (cd "$WORK_DIR" && compose down --remove-orphans) || true
  fi
  command -v docker >/dev/null 2>&1 && docker rm -f "$DOCKER_CONTAINER" >/dev/null 2>&1 || true
}

RESOLVED_DOCKER_IMAGE=""
resolve_docker_image() {
  local source_mode="$1"
  local branch_mode="$2"
  if [[ "$source_mode" == "pull" ]]; then
    ensure_docker
    docker pull "$DOCKER_IMAGE_REMOTE"
    RESOLVED_DOCKER_IMAGE="$DOCKER_IMAGE_REMOTE"
  else
    build_docker_image_local "$branch_mode"
    RESOLVED_DOCKER_IMAGE="$DOCKER_IMAGE_LOCAL"
  fi
}

install_panel_binary() {
  install_base_deps
  local arch gh_arch latest api_url tmpdir tar_name bin_name
  arch="$(uname -m)"
  case "$arch" in
    x86_64) gh_arch="x86_64"; bin_name="telemt-panel-x86_64-linux" ;;
    aarch64) gh_arch="aarch64"; bin_name="telemt-panel-aarch64-linux" ;;
    *) die "Неподдерживаемая архитектура для панели: $arch" ;;
  esac
  api_url="https://api.github.com/repos/amirotin/telemt_panel/releases/latest"
  latest="$(curl -fsSL "$api_url" | python3 -c 'import sys,json; print(json.load(sys.stdin)["tag_name"])')"
  [[ -n "$latest" ]] || die "Не удалось определить релиз панели"
  tar_name="telemt-panel-${gh_arch}-linux-gnu.tar.gz"
  tmpdir="$(mktemp -d)"
  curl -fsSL "https://github.com/amirotin/telemt_panel/releases/download/${latest}/${tar_name}" -o "$tmpdir/$tar_name"
  tar -xzf "$tmpdir/$tar_name" -C "$tmpdir"
  install -m 0755 "$tmpdir/$bin_name" "$PANEL_BINARY"
  rm -rf "$tmpdir"
}

write_panel_service_unit() {
  mkdir -p "$PANEL_DIR"
  cat > "/etc/systemd/system/${PANEL_SERVICE}.service" <<EOF_UNIT
[Unit]
Description=Telemt Panel
After=network.target

[Service]
Type=simple
ExecStart=${PANEL_BINARY} --config ${PANEL_CONFIG}
Restart=on-failure
RestartSec=2
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF_UNIT
  systemctl daemon-reload
}

create_panel_config_if_missing() {
  local telemt_auth="${1:-}"
  mkdir -p "$PANEL_DIR"
  if [[ -f "$PANEL_CONFIG" ]]; then
    return 0
  fi
  local admin_user admin_pass admin_pass2 pass_hash jwt_secret
  admin_user=$(ask "Логин администратора панели" "admin")
  while true; do
    admin_pass=$(ask_secret "Пароль администратора панели")
    admin_pass2=$(ask_secret "Повторите пароль администратора панели")
    [[ "$admin_pass" == "$admin_pass2" ]] && break
    warn "Пароли не совпадают"
  done
  pass_hash=$(printf '%s' "$admin_pass" | "$PANEL_BINARY" hash-password)
  jwt_secret=$(openssl rand -hex 32)
  cat > "$PANEL_CONFIG" <<EOF_CFG
listen = "0.0.0.0:${PANEL_DEFAULT_PORT}"

[telemt]
url = "http://127.0.0.1:9091"
auth_header = "${telemt_auth}"

[panel]
binary_path = "${PANEL_BINARY}"
service_name = "${PANEL_SERVICE}"

[auth]
username = "${admin_user}"
password_hash = "${pass_hash}"
jwt_secret = "${jwt_secret}"
session_ttl = "24h"
EOF_CFG
  chmod 600 "$PANEL_CONFIG"
}

sync_panel_config() {
  local mode="$1"
  local auth_override="${2-__KEEP__}"
  [[ -f "$PANEL_CONFIG" ]] || return 0
  python3 - "$PANEL_CONFIG" "$mode" "$auth_override" "$NATIVE_BINARY" "$NATIVE_SERVICE" "$PANEL_BINARY" "$PANEL_SERVICE" <<'PY'
from pathlib import Path
import sys
cfg = Path(sys.argv[1])
mode = sys.argv[2]
auth_override = sys.argv[3]
native_binary, native_service, panel_binary, panel_service = sys.argv[4:8]
text = cfg.read_text(encoding='utf-8', errors='ignore')
lines = text.splitlines()
cur_auth = ''
in_telemt = False
for line in lines:
    s = line.strip()
    if s == '[telemt]':
        in_telemt = True
        continue
    if in_telemt and s.startswith('[') and s != '[telemt]':
        in_telemt = False
    if in_telemt and s.startswith('auth_header ='):
        cur_auth = s.split('=',1)[1].strip().strip('"')
        break
new_auth = cur_auth if auth_override == '__KEEP__' else auth_override

out = []
in_telemt = False
in_panel = False
saw_telemt = False
saw_panel = False
telemt_fields = set()
panel_fields = set()
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
        if 'url' not in telemt_fields:
            out.append('url = "http://127.0.0.1:9091"')
        if 'auth_header' not in telemt_fields:
            out.append(f'auth_header = "{new_auth}"')
        if mode == 'native':
            if 'binary_path' not in telemt_fields:
                out.append(f'binary_path = "{native_binary}"')
            if 'service_name' not in telemt_fields:
                out.append(f'service_name = "{native_service}"')
        in_telemt = False
        out.append(line)
        continue
    if in_panel and s.startswith('[') and s != '[panel]':
        if 'binary_path' not in panel_fields:
            out.append(f'binary_path = "{panel_binary}"')
        if 'service_name' not in panel_fields:
            out.append(f'service_name = "{panel_service}"')
        in_panel = False
        out.append(line)
        continue
    if in_telemt:
        if s.startswith('url ='):
            out.append('url = "http://127.0.0.1:9091"')
            telemt_fields.add('url')
            continue
        if s.startswith('auth_header ='):
            out.append(f'auth_header = "{new_auth}"')
            telemt_fields.add('auth_header')
            continue
        if s.startswith('binary_path ='):
            if mode == 'native':
                out.append(f'binary_path = "{native_binary}"')
                telemt_fields.add('binary_path')
            continue
        if s.startswith('service_name ='):
            if mode == 'native':
                out.append(f'service_name = "{native_service}"')
                telemt_fields.add('service_name')
            continue
        out.append(line)
        continue
    if in_panel:
        if s.startswith('binary_path ='):
            out.append(f'binary_path = "{panel_binary}"')
            panel_fields.add('binary_path')
            continue
        if s.startswith('service_name ='):
            out.append(f'service_name = "{panel_service}"')
            panel_fields.add('service_name')
            continue
        out.append(line)
        continue
    out.append(line)
if in_telemt:
    if 'url' not in telemt_fields:
        out.append('url = "http://127.0.0.1:9091"')
    if 'auth_header' not in telemt_fields:
        out.append(f'auth_header = "{new_auth}"')
    if mode == 'native':
        if 'binary_path' not in telemt_fields:
            out.append(f'binary_path = "{native_binary}"')
        if 'service_name' not in telemt_fields:
            out.append(f'service_name = "{native_service}"')
if in_panel:
    if 'binary_path' not in panel_fields:
        out.append(f'binary_path = "{panel_binary}"')
    if 'service_name' not in panel_fields:
        out.append(f'service_name = "{panel_service}"')
if not saw_telemt:
    out.extend(['', '[telemt]', 'url = "http://127.0.0.1:9091"', f'auth_header = "{new_auth}"'])
    if mode == 'native':
        out.extend([f'binary_path = "{native_binary}"', f'service_name = "{native_service}"'])
if not saw_panel:
    out.extend(['', '[panel]', f'binary_path = "{panel_binary}"', f'service_name = "{panel_service}"'])
cfg.write_text('\n'.join(out).rstrip() + '\n', encoding='utf-8')
PY
  chmod 600 "$PANEL_CONFIG"
}

start_panel_service() {
  write_panel_service_unit
  systemctl enable --now "$PANEL_SERVICE"
}

install_or_repair_panel() {
  install_base_deps
  install_panel_binary
  mkdir -p "$PANEL_DIR"
  local mode=""
  if service_exists || [[ -f "$NATIVE_CONFIG" ]]; then
    mode="native"
  elif docker_mode_exists; then
    mode="docker"
  else
    die "Сначала установите Telemt (службой или Docker)"
  fi
  create_panel_config_if_missing ""
  sync_panel_config "$mode"
  start_panel_service
  say "✅ Панель установлена / обновлена / починена"
}

delete_panel() {
  systemctl stop "$PANEL_SERVICE" 2>/dev/null || true
  systemctl disable "$PANEL_SERVICE" 2>/dev/null || true
  rm -f "/etc/systemd/system/${PANEL_SERVICE}.service"
  rm -f "$PANEL_BINARY"
  rm -rf "$PANEL_DIR"
  systemctl daemon-reload
  say "✅ Панель удалена"
}

show_status_links() {
  line
  say "📊 Статус Telemt"
  if service_exists; then
    say "• Service unit: установлен"
    if service_active; then say "  └─ состояние: active"; else say "  └─ состояние: inactive"; fi
  else
    say "• Service unit: нет"
  fi
  if docker_mode_exists; then
    say "• Docker mode: найден"
    if docker_mode_active; then say "  └─ состояние: running"; else say "  └─ состояние: stopped"; fi
  else
    say "• Docker mode: нет"
  fi
  if panel_exists; then
    say "• Panel: установлена"
    if panel_active; then say "  └─ состояние: active"; else say "  └─ состояние: inactive"; fi
  else
    say "• Panel: нет"
  fi
  line
  [[ -f "$NATIVE_CONFIG" ]] && print_links_for_config "$NATIVE_CONFIG"
  [[ -f "${WORK_DIR}/config.toml" ]] && print_links_for_config "${WORK_DIR}/config.toml"
}

auto_cleanup() {
  say "🧹 Автоочистка мусора"
  rm -rf "$BUILD_DIR" 2>/dev/null || true
  if command -v docker >/dev/null 2>&1; then
    docker builder prune -f >/dev/null 2>&1 || true
    docker image prune -f >/dev/null 2>&1 || true
  fi
}

cleanup_junk_only() {
  auto_cleanup
  say "✅ Мусор очищен. Конфиги, ключи и ссылки сохранены"
}

install_native_mode() {
  local with_panel="$1"
  local branch_mode domain secret
  branch_mode=$(choose_branch_mode)
  domain=$(ask "Домен маскировки" "google.com")
  secret=$(openssl rand -hex 16)

  install_base_deps
  build_native_binary "$branch_mode"
  mkdir -p "$NATIVE_DIR"
  write_base_telemt_config "$NATIVE_CONFIG" "$domain" "$secret"
  patch_telemt_api "$NATIVE_CONFIG" native
  start_native_service

  if [[ "$with_panel" == "yes" ]]; then
    install_or_repair_panel
    sync_panel_config native ""
    systemctl restart "$PANEL_SERVICE" 2>/dev/null || true
  fi

  auto_cleanup
  say "✅ Служба Telemt установлена"
  print_links_for_config "$NATIVE_CONFIG"
}

install_docker_mode() {
  local with_panel="$1"
  local source_mode branch_mode domain secret image_ref
  source_mode=$(choose_docker_source)
  branch_mode="stable"
  if [[ "$source_mode" == "build" ]]; then
    branch_mode=$(choose_branch_mode)
  fi
  domain=$(ask "Домен маскировки" "google.com")
  secret=$(openssl rand -hex 16)

  mkdir -p "$WORK_DIR"
  write_base_telemt_config "$WORK_DIR/config.toml" "$domain" "$secret"
  patch_telemt_api "$WORK_DIR/config.toml" docker
  resolve_docker_image "$source_mode" "$branch_mode"
  image_ref="$RESOLVED_DOCKER_IMAGE"
  start_docker_stack "$image_ref"

  if [[ "$with_panel" == "yes" ]]; then
    install_or_repair_panel
    sync_panel_config docker ""
    systemctl restart "$PANEL_SERVICE" 2>/dev/null || true
  fi

  auto_cleanup
  say "✅ Docker-режим Telemt установлен"
  print_links_for_config "$WORK_DIR/config.toml"
}

update_native_mode() {
  if [[ ! -f "$NATIVE_CONFIG" ]]; then
    die "Native-конфиг не найден"
  fi
  local branch_mode
  branch_mode=$(choose_branch_mode)
  build_native_binary "$branch_mode"
  patch_telemt_api "$NATIVE_CONFIG" native
  start_native_service
  if panel_exists; then
    sync_panel_config native ""
    systemctl restart "$PANEL_SERVICE" 2>/dev/null || true
  fi
  auto_cleanup
  say "✅ Служба Telemt обновлена"
}

update_docker_mode() {
  if [[ ! -f "$WORK_DIR/config.toml" ]]; then
    die "Docker-конфиг не найден"
  fi
  local source_mode branch_mode image_ref
  source_mode=$(choose_docker_source)
  branch_mode="stable"
  if [[ "$source_mode" == "build" ]]; then
    branch_mode=$(choose_branch_mode)
  fi
  patch_telemt_api "$WORK_DIR/config.toml" docker
  resolve_docker_image "$source_mode" "$branch_mode"
  image_ref="$RESOLVED_DOCKER_IMAGE"
  start_docker_stack "$image_ref"
  if panel_exists; then
    sync_panel_config docker ""
    systemctl restart "$PANEL_SERVICE" 2>/dev/null || true
  fi
  auto_cleanup
  say "✅ Docker-режим Telemt обновлён"
}

migrate_service_to_docker() {
  [[ -f "$NATIVE_CONFIG" ]] || die "Не найден native-конфиг: $NATIVE_CONFIG"
  local source_mode branch_mode image_ref
  source_mode=$(choose_docker_source)
  branch_mode="stable"
  if [[ "$source_mode" == "build" ]]; then
    branch_mode=$(choose_branch_mode)
  fi
  mkdir -p "$WORK_DIR"
  cp "$NATIVE_CONFIG" "$WORK_DIR/config.toml"
  patch_telemt_api "$WORK_DIR/config.toml" docker
  resolve_docker_image "$source_mode" "$branch_mode"
  image_ref="$RESOLVED_DOCKER_IMAGE"
  stop_native_service
  start_docker_stack "$image_ref"
  if panel_exists; then
    sync_panel_config docker ""
    systemctl restart "$PANEL_SERVICE" 2>/dev/null || true
  fi
  auto_cleanup
  say "✅ Выполнена миграция service → Docker"
  print_links_for_config "$WORK_DIR/config.toml"
}

migrate_docker_to_service() {
  [[ -f "$WORK_DIR/config.toml" ]] || die "Не найден docker-конфиг: ${WORK_DIR}/config.toml"
  local branch_mode
  branch_mode=$(choose_branch_mode)
  build_native_binary "$branch_mode"
  mkdir -p "$NATIVE_DIR"
  cp "$WORK_DIR/config.toml" "$NATIVE_CONFIG"
  patch_telemt_api "$NATIVE_CONFIG" native
  stop_docker_stack
  start_native_service
  if panel_exists; then
    sync_panel_config native ""
    systemctl restart "$PANEL_SERVICE" 2>/dev/null || true
  fi
  auto_cleanup
  say "✅ Выполнена миграция Docker → service"
  print_links_for_config "$NATIVE_CONFIG"
}

remove_all_telemt() {
  if ! confirm "Удалить всё, что связано с Telemt"; then
    say "Отменено"
    return 0
  fi
  stop_docker_stack
  stop_native_service
  delete_panel >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${NATIVE_SERVICE}.service"
  systemctl daemon-reload || true
  rm -f "$NATIVE_BINARY"
  rm -rf "$NATIVE_DIR" "$WORK_DIR"
  if command -v docker >/dev/null 2>&1; then
    docker image rm -f "$DOCKER_IMAGE_LOCAL" >/dev/null 2>&1 || true
    docker image rm -f "$DOCKER_IMAGE_REMOTE" >/dev/null 2>&1 || true
  fi
  say "✅ Всё, что связано с Telemt, удалено"
}

panel_menu() {
  while true; do
    say ""
    say "Панель"
    say "1) Установить / обновить / починить"
    say "2) Удалить панель"
    say "0) Назад"
    case "$(ask 'Выберите пункт' '1')" in
      1) install_or_repair_panel; auto_cleanup; pause_menu; return 0 ;;
      2) delete_panel; pause_menu; return 0 ;;
      0) return 0 ;;
      *) warn "Неверный выбор" ;;
    esac
  done
}

new_install_menu() {
  while true; do
    say ""
    say "Новая установка"
    say "1) Служба + панель"
    say "2) Только служба"
    say "3) Docker + панель"
    say "4) Только Docker"
    say "0) Назад"
    case "$(ask 'Выберите пункт' '1')" in
      1) install_native_mode yes; pause_menu; return 0 ;;
      2) install_native_mode no; pause_menu; return 0 ;;
      3) install_docker_mode yes; pause_menu; return 0 ;;
      4) install_docker_mode no; pause_menu; return 0 ;;
      0) return 0 ;;
      *) warn "Неверный выбор" ;;
    esac
  done
}

update_menu() {
  while true; do
    say ""
    say "Обновление Telemt"
    say "1) Обновить службу"
    say "2) Обновить Docker"
    say "0) Назад"
    case "$(ask 'Выберите пункт' '1')" in
      1) update_native_mode; pause_menu; return 0 ;;
      2) update_docker_mode; pause_menu; return 0 ;;
      0) return 0 ;;
      *) warn "Неверный выбор" ;;
    esac
  done
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
    case "$(ask 'Выберите пункт' '6')" in
      1) new_install_menu ;;
      2) panel_menu ;;
      3) update_menu ;;
      4) migrate_service_to_docker; pause_menu ;;
      5) migrate_docker_to_service; pause_menu ;;
      6) show_status_links; pause_menu ;;
      7) remove_all_telemt; pause_menu ;;
      8) cleanup_junk_only; pause_menu ;;
      0) break ;;
      *) warn "Неверный выбор"; pause_menu ;;
    esac
  done
}

main() {
  require_root
  install_base_deps
  main_menu
}

main "$@"
