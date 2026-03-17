#!/usr/bin/env bash
set -Eeuo pipefail

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

DOCKER_REMOTE_IMAGE="ghcr.io/telemt/telemt:latest"
DOCKER_LOCAL_IMAGE="telemt:managed"
DOCKER_CONTAINER="telemt_proxy"
DOCKER_COMPOSE_FILE="${WORK_DIR}/docker-compose.yml"
DOCKER_CONFIG="${WORK_DIR}/config.toml"
API_PORT="9091"
PANEL_PORT="8080"

TTY_INPUT="/dev/tty"
[ -r "$TTY_INPUT" ] || TTY_INPUT="/dev/stdin"

say() { printf '🔹 %s\n' "$*"; }
ok() { printf '✅ %s\n' "$*"; }
warn() { printf '⚠️ %s\n' "$*" >&2; }
die() { printf '❌ %s\n' "$*" >&2; exit 1; }

pause() {
  printf '\nНажмите Enter, чтобы вернуться в меню...' >"$TTY_INPUT"
  read -r _ <"$TTY_INPUT" || true
}

ask() {
  local prompt="$1"
  local default="${2-}"
  local answer
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$prompt" "$default" >"$TTY_INPUT"
  else
    printf '%s: ' "$prompt" >"$TTY_INPUT"
  fi
  IFS= read -r answer <"$TTY_INPUT" || answer=""
  if [ -z "$answer" ]; then
    printf '%s' "$default"
  else
    printf '%s' "$answer"
  fi
}

menu_choice() {
  local title="$1"; shift
  local default="$1"; shift
  local idx=1
  printf '\n%s\n' "$title" >"$TTY_INPUT"
  for item in "$@"; do
    printf '%d) %s\n' "$idx" "$item" >"$TTY_INPUT"
    idx=$((idx+1))
  done
  ask "Выберите пункт" "$default"
}

need_root() {
  [ "$(id -u)" -eq 0 ] || die "Запускайте этот скрипт от root"
}

ensure_apt() {
  command -v apt-get >/dev/null 2>&1 || die "Нужен apt-get (Debian/Ubuntu)"
}

pkg_installed() {
  dpkg -s "$1" >/dev/null 2>&1
}

install_base_deps() {
  ensure_apt
  local pkgs=()
  local p
  for p in ca-certificates curl git gzip grep openssl python3 sed tar coreutils util-linux passwd systemd xxd; do
    pkg_installed "$p" || pkgs+=("$p")
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
  if [ "${#pkgs[@]}" -gt 0 ]; then
    say "Устанавливаем зависимости: ${pkgs[*]}"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -yqq "${pkgs[@]}"
  fi
  command -v awk >/dev/null 2>&1 || die "awk не найден после установки"
}

arch_for_panel() {
  case "$(uname -m)" in
    x86_64) printf 'x86_64' ;;
    aarch64|arm64) printf 'aarch64' ;;
    *) die "Неподдерживаемая архитектура: $(uname -m)" ;;
  esac
}

arch_for_telemt_release() {
  case "$(uname -m)" in
    x86_64) printf 'x86_64' ;;
    aarch64|arm64) printf 'aarch64' ;;
    *) printf '%s' "$(uname -m)" ;;
  esac
}

libc_flavor() {
  if ldd --version 2>&1 | grep -iq musl; then
    printf 'musl'
  else
    printf 'gnu'
  fi
}

latest_tag_any() {
  git ls-remote --tags --refs https://github.com/telemt/telemt.git \
    | awk -F/ '{print $NF}' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -V \
    | tail -n1
}

latest_stable_release_tag() {
  local tag=""
  tag="$(curl -fsSL https://api.github.com/repos/telemt/telemt/releases/latest 2>/dev/null | python3 - <<'PY'
import json,sys
try:
    data=json.load(sys.stdin)
    print(data.get('tag_name',''))
except Exception:
    print('')
PY
)"
  if [ -z "$tag" ]; then
    local url
    url="$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/telemt/telemt/releases/latest 2>/dev/null || true)"
    tag="$(printf '%s' "$url" | sed -n 's#^.*/tag/\([^/?#]*\).*$#\1#p')"
  fi
  printf '%s' "$tag"
}

choose_release_channel() {
  local c
  c="$(menu_choice 'Какую ветку Telemt использовать?' '1' 'LTS / Stable release' 'Последняя release/tag')"
  case "$c" in
    1) printf 'stable' ;;
    2) printf 'latest' ;;
    *) printf 'stable' ;;
  esac
}

resolve_telemt_tag() {
  local channel="${1:-stable}"
  local tag=""
  if [ "$channel" = "stable" ]; then
    tag="$(latest_stable_release_tag || true)"
    [ -n "$tag" ] || tag="$(latest_tag_any || true)"
  else
    tag="$(latest_tag_any || true)"
  fi
  [ -n "$tag" ] || die "Не удалось определить версию Telemt"
  printf '%s' "$tag"
}

generate_secret() {
  openssl rand -hex 16
}

get_ext_ip() {
  local ip=""
  ip="$(curl -4fsSL --max-time 8 ifconfig.me 2>/dev/null || true)"
  if [ -z "$ip" ]; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  fi
  printf '%s' "$ip"
}

read_tls_domain_from_config() {
  local cfg="$1"
  [ -f "$cfg" ] || return 0
  awk -F'"' '/tls_domain[[:space:]]*=/{print $2; exit}' "$cfg"
}

read_secret_from_config() {
  local cfg="$1"
  [ -f "$cfg" ] || return 0
  awk -F'"' '/^[[:space:]]*hello[[:space:]]*=/{print $2; exit}' "$cfg"
}

write_native_config() {
  local cfg="$1" domain="$2" secret="$3"
  mkdir -p "$(dirname "$cfg")"
  cat >"$cfg" <<EOF2
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
listen = "127.0.0.1:${API_PORT}"
whitelist = ["127.0.0.1/32"]

[censorship]
tls_domain = "${domain}"

[access.users]
hello = "${secret}"
EOF2
}

write_docker_config() {
  local cfg="$1" domain="$2" secret="$3"
  mkdir -p "$(dirname "$cfg")"
  cat >"$cfg" <<EOF2
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
listen = "0.0.0.0:${API_PORT}"
whitelist = ["127.0.0.0/8", "172.16.0.0/12"]

[censorship]
tls_domain = "${domain}"

[access.users]
hello = "${secret}"
EOF2
}

patch_docker_api_config() {
  local cfg="$1"
  [ -f "$cfg" ] || return 0
  python3 - "$cfg" "$API_PORT" <<'PY'
from pathlib import Path
import sys,re
p=Path(sys.argv[1])
port=sys.argv[2]
text=p.read_text()
block=f'''[server.api]
enabled = true
listen = "0.0.0.0:{port}"
whitelist = ["127.0.0.0/8", "172.16.0.0/12"]'''
if re.search(r'(?m)^\[server\.api\]\s*$', text):
    text=re.sub(r'(?ms)^\[server\.api\]\s*$.*?(?=^\[|\Z)', block+"\n\n", text, count=1)
else:
    if not text.endswith("\n"):
        text += "\n"
    text += "\n"+block+"\n"
p.write_text(text)
PY
}

write_docker_compose() {
  mkdir -p "$WORK_DIR"
  cat >"$DOCKER_COMPOSE_FILE" <<EOF2
services:
  telemt:
    image: ${DOCKER_LOCAL_IMAGE}
    container_name: ${DOCKER_CONTAINER}
    restart: unless-stopped
    ports:
      - "443:443"
      - "127.0.0.1:${API_PORT}:${API_PORT}"
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

service_mode_installed() {
  [ -f "/etc/systemd/system/${NATIVE_SERVICE}.service" ] || [ -f "$NATIVE_CONFIG" ] || [ -x "$NATIVE_BINARY" ]
}

service_active() {
  systemctl is-active --quiet "$NATIVE_SERVICE" 2>/dev/null
}

docker_exists() {
  command -v docker >/dev/null 2>&1
}

docker_daemon_ok() {
  docker info >/dev/null 2>&1
}

docker_container_exists() {
  docker_exists && docker_daemon_ok && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$DOCKER_CONTAINER"
}

docker_container_running() {
  docker_exists && docker_daemon_ok && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$DOCKER_CONTAINER"
}

docker_mode_installed() {
  [ -f "$DOCKER_CONFIG" ] || [ -f "$DOCKER_COMPOSE_FILE" ] || docker_container_exists
}

panel_exists() {
  [ -x "$PANEL_BINARY" ] || [ -f "/etc/systemd/system/${PANEL_SERVICE}.service" ] || [ -f "$PANEL_CONFIG" ]
}

panel_active() {
  systemctl is-active --quiet "$PANEL_SERVICE" 2>/dev/null
}

docker_socket_fix_needed() {
  journalctl -u docker -n 80 --no-pager 2>/dev/null | grep -q 'failed to load listeners: no sockets found via socket activation'
}

apply_docker_service_override() {
  mkdir -p /etc/systemd/system/docker.service.d
  cat >/etc/systemd/system/docker.service.d/override.conf <<'EOF2'
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd -H unix:///var/run/docker.sock --containerd=/run/containerd/containerd.sock
EOF2
}

ensure_docker_repo() {
  install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.asc ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi
  . /etc/os-release
  local codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  [ -n "$codename" ] || die "Не удалось определить кодовое имя Ubuntu"
  cat >/etc/apt/sources.list.d/docker.list <<EOF2
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable
EOF2
}

install_docker_packages() {
  say "Подготавливаем Docker и Compose v2"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -yqq ca-certificates curl gnupg lsb-release >/dev/null
  ensure_docker_repo
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -yqq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
  systemctl enable --now containerd.service docker.service >/dev/null 2>&1 || true
}

ensure_docker() {
  install_base_deps

  if ! docker_exists; then
    install_docker_packages
  fi

  docker_exists || die "Docker не установлен"

  if ! docker compose version >/dev/null 2>&1; then
    install_docker_packages
  fi

  systemctl daemon-reload || true
  systemctl reset-failed docker.service docker.socket >/dev/null 2>&1 || true

  if systemctl list-unit-files 2>/dev/null | grep -q '^docker\.socket'; then
    systemctl stop docker.socket >/dev/null 2>&1 || true
    systemctl disable docker.socket >/dev/null 2>&1 || true
  fi

  rm -f /run/docker.sock /var/run/docker.sock >/dev/null 2>&1 || true

  systemctl enable docker.service >/dev/null 2>&1 || true
  systemctl start docker.service >/dev/null 2>&1 || true
  sleep 2

  if ! docker_daemon_ok; then
    if docker_socket_fix_needed || journalctl -u docker -n 80 --no-pager 2>/dev/null | grep -q 'socket activation'; then
      warn "Чиним сломанную socket activation Docker"
      systemctl stop docker.service docker.socket >/dev/null 2>&1 || true
      systemctl disable docker.socket >/dev/null 2>&1 || true
      apply_docker_service_override
      systemctl daemon-reload
      systemctl reset-failed docker.service docker.socket >/dev/null 2>&1 || true
      rm -f /run/docker.sock /var/run/docker.sock >/dev/null 2>&1 || true
      systemctl enable docker.service >/dev/null 2>&1 || true
      systemctl start docker.service >/dev/null 2>&1 || true
      sleep 2
    fi
  fi

  docker_daemon_ok || {
    journalctl -u docker -n 120 --no-pager || true
    die "Docker daemon не поднялся"
  }

  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 недоступен"
  ok "Docker и Compose v2 готовы"
}

compose() {
  docker compose -f "$DOCKER_COMPOSE_FILE" "$@"
}

ensure_native_user() {
  if ! id -u "$NATIVE_USER" >/dev/null 2>&1; then
    useradd -d "$NATIVE_HOME" -m -r -U "$NATIVE_USER"
  fi
  mkdir -p "$NATIVE_HOME" "$NATIVE_DIR"
  chown -R "$NATIVE_USER:$NATIVE_USER" "$NATIVE_HOME" "$NATIVE_DIR" || true
}

download_telemt_binary() {
  local tag="$1"
  local arch libc url tmpdir
  arch="$(arch_for_telemt_release)"
  libc="$(libc_flavor)"
  url="https://github.com/telemt/telemt/releases/download/${tag}/telemt-${arch}-linux-${libc}.tar.gz"
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN
  curl -fsSL "$url" -o "${tmpdir}/telemt.tar.gz"
  tar -xzf "${tmpdir}/telemt.tar.gz" -C "$tmpdir"
  [ -f "${tmpdir}/telemt" ] || die "Не найден бинарник telemt в архиве"
  install -m 0755 "${tmpdir}/telemt" "$NATIVE_BINARY"
}

clone_checkout_telemt() {
  local channel="$1"
  local tag
  tag="$(resolve_telemt_tag "$channel")"
  rm -rf "$BUILD_DIR"
  git clone https://github.com/telemt/telemt.git "$BUILD_DIR" >/dev/null 2>&1
  cd "$BUILD_DIR"
  git checkout "$tag" >/dev/null 2>&1 || git checkout main >/dev/null 2>&1
}

build_docker_image_from_source() {
  local channel="$1"
  clone_checkout_telemt "$channel"
  docker build -t "$DOCKER_LOCAL_IMAGE" "$BUILD_DIR"
  rm -rf "$BUILD_DIR"
}

pull_docker_image() {
  docker pull "$DOCKER_REMOTE_IMAGE"
  docker tag "$DOCKER_REMOTE_IMAGE" "$DOCKER_LOCAL_IMAGE"
}

wait_for_systemd_active() {
  local unit="$1" timeout="${2:-15}" i
  for ((i=0; i<timeout; i++)); do
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_container_running() {
  local name="$1" timeout="${2:-20}" i
  for ((i=0; i<timeout; i++)); do
    if docker_container_running; then
      return 0
    fi
    sleep 1
  done
  return 1
}

create_native_service() {
  cat >/etc/systemd/system/${NATIVE_SERVICE}.service <<EOF2
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
  systemctl daemon-reload
  systemctl enable "$NATIVE_SERVICE" >/dev/null 2>&1 || true
  if service_active; then
    systemctl restart "$NATIVE_SERVICE"
  else
    systemctl start "$NATIVE_SERVICE"
  fi
  wait_for_systemd_active "$NATIVE_SERVICE" 20 || {
    journalctl -u "$NATIVE_SERVICE" -n 80 --no-pager || true
    die "Служба Telemt не перешла в active"
  }
}

install_or_update_service() {
  local channel="$1" domain="$2" secret="$3" tag
  ensure_native_user
  tag="$(resolve_telemt_tag "$channel")"
  say "Скачиваем Telemt tag ${tag}"
  download_telemt_binary "$tag"
  write_native_config "$NATIVE_CONFIG" "$domain" "$secret"
  chown "$NATIVE_USER:$NATIVE_USER" "$NATIVE_CONFIG" || true
  chmod 600 "$NATIVE_CONFIG"
  create_native_service
  ok "Telemt как служба установлен/обновлён"
}

start_docker_stack() {
  ensure_docker
  write_docker_compose
  mkdir -p "$WORK_DIR"
  cd "$WORK_DIR"
  compose down --remove-orphans >/dev/null 2>&1 || true
  docker ps -a --format '{{.Names}}' | grep -E "(^${DOCKER_CONTAINER}$|^telemt$)" | xargs -r docker rm -f >/dev/null 2>&1 || true
  compose up -d
  wait_for_container_running "$DOCKER_CONTAINER" 25 || die "Контейнер Telemt не перешёл в running"
}

install_or_update_docker() {
  local mode="$1" channel="${2:-stable}" domain="$3" secret="$4"
  mkdir -p "$WORK_DIR"
  write_docker_config "$DOCKER_CONFIG" "$domain" "$secret"
  if [ "$mode" = "build" ]; then
    build_docker_image_from_source "$channel"
  else
    pull_docker_image
  fi
  start_docker_stack
  ok "Telemt как Docker установлен/обновлён"
}

panel_download_binary() {
  local arch tarball tmpdir latest
  arch="$(arch_for_panel)"
  latest="$(curl -fsSL https://api.github.com/repos/amirotin/telemt_panel/releases/latest | python3 - <<'PY'
import json,sys
print(json.load(sys.stdin).get('tag_name',''))
PY
)"
  [ -n "$latest" ] || die "Не удалось определить latest release telemt_panel"
  tarball="telemt-panel-${arch}-linux-gnu.tar.gz"
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN
  curl -fsSL "https://github.com/amirotin/telemt_panel/releases/download/${latest}/${tarball}" -o "${tmpdir}/${tarball}"
  tar -xzf "${tmpdir}/${tarball}" -C "$tmpdir"
  install -m 0755 "${tmpdir}/telemt-panel-${arch}-linux" "$PANEL_BINARY"
}

panel_hash_password() {
  local password="$1"
  printf '%s' "$password" | "$PANEL_BINARY" hash-password
}

panel_write_service() {
  cat >/etc/systemd/system/${PANEL_SERVICE}.service <<EOF2
[Unit]
Description=Telemt Panel
After=network.target

[Service]
Type=simple
ExecStart=${PANEL_BINARY} --config ${PANEL_CONFIG}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF2
  systemctl daemon-reload
  systemctl enable "$PANEL_SERVICE" >/dev/null 2>&1 || true
}

panel_set_auth() {
  local username="$1" password="$2"
  local hash secret
  hash="$(panel_hash_password "$password")"
  secret="$(openssl rand -hex 32)"
  mkdir -p "$PANEL_DIR"
  python3 - "$PANEL_CONFIG" "$username" "$hash" "$secret" <<'PY'
from pathlib import Path
import sys,re
p=Path(sys.argv[1])
username,pw_hash,jwt_secret=sys.argv[2:]
text=p.read_text() if p.exists() else 'listen = "0.0.0.0:8080"\n'
auth_block=f'''[auth]
username = "{username}"
password_hash = "{pw_hash}"
jwt_secret = "{jwt_secret}"
session_ttl = "24h"'''
if re.search(r'(?m)^\[auth\]\s*$', text):
    text=re.sub(r'(?ms)^\[auth\]\s*$.*?(?=^\[|\Z)', auth_block+"\n\n", text, count=1)
else:
    if not text.endswith("\n"):
        text += "\n"
    text += "\n" + auth_block + "\n"
if not re.search(r'(?m)^listen\s*=', text):
    text='listen = "0.0.0.0:8080"\n\n'+text
p.write_text(text)
PY
  chmod 600 "$PANEL_CONFIG"
}

panel_sync_mode() {
  local mode="$1"
  mkdir -p "$PANEL_DIR"
  python3 - "$PANEL_CONFIG" "$mode" "$API_PORT" "$NATIVE_BINARY" "$NATIVE_SERVICE" <<'PY'
from pathlib import Path
import sys,re
p=Path(sys.argv[1])
mode=sys.argv[2]
api_port=sys.argv[3]
bin_path=sys.argv[4]
svc=sys.argv[5]
text=p.read_text() if p.exists() else 'listen = "0.0.0.0:8080"\n'
url=f'http://127.0.0.1:{api_port}'
if mode == 'docker':
    telemt=f'''[telemt]
url = "{url}"
auth_header = ""
github_repo = "telemt/telemt"'''
else:
    telemt=f'''[telemt]
url = "{url}"
auth_header = ""
binary_path = "{bin_path}"
service_name = "{svc}"
github_repo = "telemt/telemt"'''
panel='''[panel]
binary_path = "/usr/local/bin/telemt-panel"
service_name = "telemt-panel"
github_repo = "amirotin/telemt_panel"'''
if re.search(r'(?m)^\[telemt\]\s*$', text):
    text=re.sub(r'(?ms)^\[telemt\]\s*$.*?(?=^\[|\Z)', telemt+"\n\n", text, count=1)
else:
    if not text.endswith("\n"):
        text += "\n"
    text += "\n" + telemt + "\n"
if re.search(r'(?m)^\[panel\]\s*$', text):
    text=re.sub(r'(?ms)^\[panel\]\s*$.*?(?=^\[|\Z)', panel+"\n\n", text, count=1)
else:
    if not text.endswith("\n"):
        text += "\n"
    text += "\n" + panel + "\n"
if not re.search(r'(?m)^listen\s*=', text):
    text='listen = "0.0.0.0:8080"\n\n' + text
p.write_text(text)
PY
  chmod 600 "$PANEL_CONFIG"
}

determine_current_mode() {
  if service_active; then
    printf 'service'
  elif docker_container_running; then
    printf 'docker'
  elif service_mode_installed; then
    printf 'service'
  elif docker_mode_installed; then
    printf 'docker'
  else
    printf 'none'
  fi
}

install_or_update_panel() {
  install_base_deps
  panel_download_binary
  panel_write_service

  local mode username password
  mode="$(determine_current_mode)"
  if [ ! -f "$PANEL_CONFIG" ]; then
    username="$(ask 'Логин панели' 'admin')"
    while true; do
      password="$(ask 'Пароль панели')"
      [ -n "$password" ] && break
      warn "Пароль не должен быть пустым"
    done
    panel_set_auth "$username" "$password"
  fi

  case "$mode" in
    docker) panel_sync_mode docker ;;
    service) panel_sync_mode service ;;
    none)
      warn "Telemt ещё не установлен. Панель поставлена, но не будет подключена, пока не появится Telemt."
      panel_sync_mode service
      ;;
  esac

  if panel_active; then
    systemctl restart "$PANEL_SERVICE"
  else
    systemctl start "$PANEL_SERVICE"
  fi
  wait_for_systemd_active "$PANEL_SERVICE" 20 || {
    journalctl -u "$PANEL_SERVICE" -n 80 --no-pager || true
    die "Панель не перешла в active"
  }
  ok "Панель установлена/обновлена/починена"
}

reset_panel_credentials() {
  panel_exists || die "Панель не установлена"
  local username password
  username="$(ask 'Новый логин панели' 'admin')"
  while true; do
    password="$(ask 'Новый пароль панели')"
    [ -n "$password" ] && break
    warn "Пароль не должен быть пустым"
  done
  panel_set_auth "$username" "$password"
  systemctl restart "$PANEL_SERVICE" >/dev/null 2>&1 || true
  wait_for_systemd_active "$PANEL_SERVICE" 20 || true
  ok "Логин/пароль панели обновлены"
}

remove_panel() {
  systemctl stop "$PANEL_SERVICE" >/dev/null 2>&1 || true
  systemctl disable "$PANEL_SERVICE" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${PANEL_SERVICE}.service" "$PANEL_BINARY"
  rm -rf "$PANEL_DIR"
  systemctl daemon-reload || true
  ok "Панель удалена"
}

show_links() {
  local mode domain secret ip hex
  mode="$(determine_current_mode)"

  printf '\n📊 Статус Telemt\n'
  if service_mode_installed; then
    printf '• Service mode: установлен\n'
    printf '  └─ состояние: %s\n' "$(systemctl is-active "$NATIVE_SERVICE" 2>/dev/null || echo inactive)"
  else
    printf '• Service mode: не найден\n'
  fi

  if docker_mode_installed; then
    printf '• Docker mode: установлен\n'
    if docker_exists && docker_daemon_ok; then
      printf '  └─ состояние: %s\n' "$(docker_container_running && echo running || echo stopped)"
    elif docker_exists; then
      printf '  └─ состояние: daemon down\n'
    else
      printf '  └─ состояние: docker не установлен\n'
    fi
  else
    printf '• Docker mode: не найден\n'
  fi

  if panel_exists; then
    printf '• Panel: установлена\n'
    printf '  └─ состояние: %s\n' "$(systemctl is-active "$PANEL_SERVICE" 2>/dev/null || echo inactive)"
  else
    printf '• Panel: не найдена\n'
  fi

  case "$mode" in
    service)
      domain="$(read_tls_domain_from_config "$NATIVE_CONFIG")"
      secret="$(read_secret_from_config "$NATIVE_CONFIG")"
      printf '\n📄 Активный конфиг: %s\n' "$NATIVE_CONFIG"
      ;;
    docker)
      domain="$(read_tls_domain_from_config "$DOCKER_CONFIG")"
      secret="$(read_secret_from_config "$DOCKER_CONFIG")"
      printf '\n📄 Активный конфиг: %s\n' "$DOCKER_CONFIG"
      ;;
    *)
      domain=""
      secret=""
      printf '\n⚠️ Активный режим не определён\n'
      ;;
  esac

  [ -n "$domain" ] && printf '🌐 Домен маскировки: %s\n' "$domain"
  ip="$(get_ext_ip)"
  if [ -n "$ip" ] && [ -n "$domain" ] && [ -n "$secret" ]; then
    hex="$(printf '%s' "$domain" | xxd -p -c 256)"
    printf '🔗 TELEGRAM: tg://proxy?server=%s&port=443&secret=ee%s%s\n' "$ip" "$secret" "$hex"
  fi
  if [ -n "$ip" ]; then
    printf '🌐 ПАНЕЛЬ:   http://%s:%s\n' "$ip" "$PANEL_PORT"
  fi
}

auto_cleanup() {
  say "Автоочистка мусора"
  rm -rf "$BUILD_DIR" >/dev/null 2>&1 || true
  if docker_exists && docker_daemon_ok; then
    docker builder prune -f >/dev/null 2>&1 || true
    docker image prune -f >/dev/null 2>&1 || true
  fi
  ok "Мусор очищен. Конфиги, ключи и ссылки сохранены"
}

purge_service_mode() {
  systemctl stop "$NATIVE_SERVICE" >/dev/null 2>&1 || true
  systemctl disable "$NATIVE_SERVICE" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${NATIVE_SERVICE}.service"
  rm -f "$NATIVE_BINARY"
  rm -rf "$NATIVE_DIR"
  systemctl daemon-reload || true
}

purge_docker_mode() {
  if docker_exists && docker_daemon_ok; then
    cd "$WORK_DIR" >/dev/null 2>&1 || true
    [ -f "$DOCKER_COMPOSE_FILE" ] && compose down --remove-orphans >/dev/null 2>&1 || true
    docker rm -f "$DOCKER_CONTAINER" >/dev/null 2>&1 || true
    docker image rm -f "$DOCKER_LOCAL_IMAGE" >/dev/null 2>&1 || true
    docker image rm -f "$DOCKER_REMOTE_IMAGE" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
}

remove_service_only() {
  purge_service_mode
  if panel_exists && docker_container_running; then
    panel_sync_mode docker
    systemctl restart "$PANEL_SERVICE" >/dev/null 2>&1 || true
  fi
  ok "Служба Telemt удалена"
}

remove_docker_only() {
  purge_docker_mode
  if panel_exists && service_active; then
    panel_sync_mode service
    systemctl restart "$PANEL_SERVICE" >/dev/null 2>&1 || true
  fi
  ok "Docker-режим Telemt удалён"
}

remove_all_telemt() {
  remove_panel || true
  purge_service_mode || true
  purge_docker_mode || true
  ok "Всё, что связано с Telemt, удалено"
}

new_install_menu() {
  local c mode channel domain secret
  c="$(menu_choice 'Новая установка' '1' 'Служба + панель' 'Только служба' 'Docker + панель' 'Только Docker')"
  case "$c" in
    1|2)
      channel="$(choose_release_channel)"
      domain="$(ask 'Домен маскировки' 'google.com')"
      secret="$(generate_secret)"
      install_or_update_service "$channel" "$domain" "$secret"
      purge_docker_mode >/dev/null 2>&1 || true
      if [ "$c" = "1" ]; then
        install_or_update_panel
        panel_sync_mode service
        systemctl restart "$PANEL_SERVICE" >/dev/null 2>&1 || true
      fi
      auto_cleanup
      ;;
    3|4)
      mode="$(menu_choice 'Как получить Docker-образ Telemt?' '1' 'Docker pull (ghcr.io/telemt/telemt:latest)' 'Сборка из исходников')"
      channel='stable'
      if [ "$mode" = '2' ]; then
        channel="$(choose_release_channel)"
      fi
      domain="$(ask 'Домен маскировки' 'google.com')"
      secret="$(generate_secret)"
      install_or_update_docker "$([ "$mode" = '2' ] && echo build || echo pull)" "$channel" "$domain" "$secret"
      purge_service_mode >/dev/null 2>&1 || true
      if [ "$c" = '3' ]; then
        install_or_update_panel
        panel_sync_mode docker
        systemctl restart "$PANEL_SERVICE" >/dev/null 2>&1 || true
      fi
      auto_cleanup
      ;;
  esac
}

panel_menu() {
  local c
  c="$(menu_choice 'Панель' '1' 'Установить / обновить / починить' 'Сбросить логин / пароль' 'Удалить панель')"
  case "$c" in
    1) install_or_update_panel ;;
    2) reset_panel_credentials ;;
    3) remove_panel ;;
  esac
}

update_menu() {
  local c channel mode domain secret
  c="$(menu_choice 'Обновить существующий Telemt' '1' 'Обновить службу' 'Обновить Docker')"
  case "$c" in
    1)
      [ -f "$NATIVE_CONFIG" ] || die "Не найден ${NATIVE_CONFIG}"
      domain="$(read_tls_domain_from_config "$NATIVE_CONFIG")"
      secret="$(read_secret_from_config "$NATIVE_CONFIG")"
      channel="$(choose_release_channel)"
      install_or_update_service "$channel" "$domain" "$secret"
      if panel_exists; then panel_sync_mode service; systemctl restart "$PANEL_SERVICE" >/dev/null 2>&1 || true; fi
      auto_cleanup
      ;;
    2)
      [ -f "$DOCKER_CONFIG" ] || die "Не найден ${DOCKER_CONFIG}"
      domain="$(read_tls_domain_from_config "$DOCKER_CONFIG")"
      secret="$(read_secret_from_config "$DOCKER_CONFIG")"
      mode="$(menu_choice 'Как обновить Docker Telemt?' '1' 'Docker pull' 'Сборка из исходников')"
      channel='stable'
      if [ "$mode" = '2' ]; then
        channel="$(choose_release_channel)"
      fi
      install_or_update_docker "$([ "$mode" = '2' ] && echo build || echo pull)" "$channel" "$domain" "$secret"
      if panel_exists; then panel_sync_mode docker; systemctl restart "$PANEL_SERVICE" >/dev/null 2>&1 || true; fi
      auto_cleanup
      ;;
  esac
}

migrate_service_to_docker() {
  [ -f "$NATIVE_CONFIG" ] || die "Не найден ${NATIVE_CONFIG}"
  local mode channel domain secret
  mode="$(menu_choice 'Как получить Docker-образ Telemt?' '1' 'Docker pull (ghcr.io/telemt/telemt:latest)' 'Сборка из исходников')"
  channel='stable'
  if [ "$mode" = '2' ]; then
    channel="$(choose_release_channel)"
  fi
  domain="$(read_tls_domain_from_config "$NATIVE_CONFIG")"
  secret="$(read_secret_from_config "$NATIVE_CONFIG")"
  install_or_update_docker "$([ "$mode" = '2' ] && echo build || echo pull)" "$channel" "$domain" "$secret"
  if panel_exists; then panel_sync_mode docker; systemctl restart "$PANEL_SERVICE" >/dev/null 2>&1 || true; fi
  purge_service_mode
  auto_cleanup
  ok "Миграция service → Docker завершена"
}

migrate_docker_to_service() {
  [ -f "$DOCKER_CONFIG" ] || die "Не найден ${DOCKER_CONFIG}"
  local channel domain secret
  domain="$(read_tls_domain_from_config "$DOCKER_CONFIG")"
  secret="$(read_secret_from_config "$DOCKER_CONFIG")"
  channel="$(choose_release_channel)"
  install_or_update_service "$channel" "$domain" "$secret"
  if panel_exists; then panel_sync_mode service; systemctl restart "$PANEL_SERVICE" >/dev/null 2>&1 || true; fi
  purge_docker_mode
  auto_cleanup
  ok "Миграция Docker → service завершена"
}

delete_menu() {
  local c confirm
  c="$(menu_choice 'Удаление Telemt / панели' '1' 'Удалить только службу Telemt' 'Удалить только Docker Telemt' 'Удалить только панель' 'Удалить всё')"
  case "$c" in
    1) remove_service_only ;;
    2) remove_docker_only ;;
    3) remove_panel ;;
    4)
      confirm="$(ask 'Подтвердите удаление всего (да/нет)' 'нет')"
      case "$confirm" in
        да|Да|YES|yes|y|Y) remove_all_telemt ;;
        *) warn 'Удаление отменено' ;;
      esac
      ;;
  esac
}

main_menu() {
  while true; do
    clear || true
    cat <<'EOF2'
═════════════════════════════════════════════════════
 🛠️  Telemt Manager
═════════════════════════════════════════════════════
1) Новая установка
2) Установить / обновить / починить панель
3) Обновить существующий Telemt
4) Миграция service → Docker
5) Миграция Docker → service
6) Показать статус и ссылки
7) Удаление Telemt / панели
8) Очистить мусор (ключи/ссылки не удаляются)
0) Выход
EOF2
    case "$(ask 'Выберите пункт' '6')" in
      1) new_install_menu; pause ;;
      2) panel_menu; pause ;;
      3) update_menu; pause ;;
      4) migrate_service_to_docker; pause ;;
      5) migrate_docker_to_service; pause ;;
      6) show_links; pause ;;
      7) delete_menu; pause ;;
      8) auto_cleanup; pause ;;
      0) exit 0 ;;
      *) warn 'Неверный пункт'; pause ;;
    esac
  done
}

need_root
install_base_deps
main_menu
