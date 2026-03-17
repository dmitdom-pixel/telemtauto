#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Telemt Manager
# - Native service install/update/migrate
# - Docker install/update/migrate
# - Panel install/update/repair
# - Full removal
# - Safe cleanup
# ============================================================

WORK_DIR="${HOME}/telemt-proxy"
BUILD_DIR="${WORK_DIR}/build_telemt"

NATIVE_USER="telemt"
NATIVE_GROUP="telemt"
NATIVE_HOME="/opt/telemt"
NATIVE_BIN="/bin/telemt"
NATIVE_CFG_DIR="/etc/telemt"
NATIVE_CFG="${NATIVE_CFG_DIR}/telemt.toml"
NATIVE_SERVICE="telemt"

PANEL_BIN="/usr/local/bin/telemt-panel"
PANEL_CFG_DIR="/etc/telemt-panel"
PANEL_CFG="${PANEL_CFG_DIR}/config.toml"
PANEL_SERVICE_FILE="/etc/systemd/system/telemt-panel.service"
PANEL_SERVICE_NAME="telemt-panel"

DOCKER_IMAGE="ghcr.io/telemt/telemt:latest"
DOCKER_CONTAINER="telemt_proxy"
DOCKER_COMPOSE_FILE="${WORK_DIR}/docker-compose.yml"
DOCKER_CFG="${WORK_DIR}/config.toml"

TELEMT_REPO="https://github.com/telemt/telemt.git"
PANEL_RELEASE_API="https://api.github.com/repos/amirotin/telemt_panel/releases/latest"

TTY_INPUT="/dev/tty"
[ -r "$TTY_INPUT" ] || TTY_INPUT="/dev/stdin"

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

# -----------------------------
# Helpers
# -----------------------------
log()  { echo "[$(date +'%H:%M:%S')] $*"; }
warn() { echo "⚠️  $*" >&2; }
die()  { echo "❌ $*" >&2; exit 1; }

run_root() {
    if [ -n "$SUDO" ]; then
        $SUDO "$@"
    else
        "$@"
    fi
}

ask() {
    local prompt="$1"
    local default="${2-}"
    local answer=""
    if [ -n "$default" ]; then
        IFS= read -r -p "$prompt [$default]: " answer <"$TTY_INPUT" || true
        printf '%s' "${answer:-$default}"
    else
        IFS= read -r -p "$prompt: " answer <"$TTY_INPUT" || true
        printf '%s' "$answer"
    fi
}

ask_secret() {
    local prompt="$1"
    local answer=""
    IFS= read -r -s -p "$prompt: " answer <"$TTY_INPUT" || true
    echo
    printf '%s' "$answer"
}

confirm() {
    local prompt="$1"
    local default="${2:-N}"
    local hint="[y/N]"
    local answer=""
    [ "$default" = "Y" ] && hint="[Y/n]"
    IFS= read -r -p "$prompt $hint: " answer <"$TTY_INPUT" || true
    answer="${answer:-$default}"
    case "$answer" in
        y|Y|yes|YES|д|Д) return 0 ;;
        *) return 1 ;;
    esac
}

cfg_cat() {
    local cfg="$1"
    if [ -r "$cfg" ]; then
        cat "$cfg"
    else
        run_root cat "$cfg" 2>/dev/null || true
    fi
}

compose() {
    if run_root docker compose version >/dev/null 2>&1; then
        run_root docker compose -f "$DOCKER_COMPOSE_FILE" "$@"
    elif command -v docker-compose >/dev/null 2>&1; then
        run_root docker-compose -f "$DOCKER_COMPOSE_FILE" "$@"
    else
        die "Не найден docker compose / docker-compose"
    fi
}

cleanup_trap() {
    :
}
trap cleanup_trap EXIT

# -----------------------------
# Requirements / detect
# -----------------------------
require_apt() {
    command -v apt-get >/dev/null 2>&1 || die "Скрипт рассчитан на Debian/Ubuntu (нужен apt-get)."
}

install_base_deps() {
    require_apt

    local pkgs=()
    for p in curl git tar gzip awk sed grep coreutils ca-certificates openssl python3 ldd; do
        command -v "$p" >/dev/null 2>&1 || true
    done

    command -v git >/dev/null 2>&1 || pkgs+=(git)
    command -v curl >/dev/null 2>&1 || pkgs+=(curl)
    command -v openssl >/dev/null 2>&1 || pkgs+=(openssl)
    command -v python3 >/dev/null 2>&1 || pkgs+=(python3)
    command -v tar >/dev/null 2>&1 || pkgs+=(tar)
    command -v hexdump >/dev/null 2>&1 || pkgs+=(bsdextrautils)
    command -v install >/dev/null 2>&1 || pkgs+=(coreutils)
    command -v ss >/dev/null 2>&1 || pkgs+=(iproute2)

    if [ "${#pkgs[@]}" -gt 0 ]; then
        log "Устанавливаю зависимости: ${pkgs[*]}"
        run_root apt-get update -qq
        run_root apt-get install -yqq "${pkgs[@]}"
    fi
}

ensure_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        log "Docker не найден, ставлю через get.docker.com"
        curl -fsSL https://get.docker.com | sh
    fi

    if ! run_root docker info >/dev/null 2>&1; then
        run_root systemctl enable --now docker >/dev/null 2>&1 || true
    fi

    if ! run_root docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
        log "Ставлю docker-compose-plugin"
        run_root apt-get update -qq
        run_root apt-get install -yqq docker-compose-plugin || true
    fi

    run_root docker info >/dev/null 2>&1 || die "Docker установлен, но daemon недоступен."
}

ensure_rust_toolchain() {
    if ! command -v cargo >/dev/null 2>&1; then
        log "Ставлю Rust toolchain"
        run_root apt-get update -qq
        run_root apt-get install -yqq build-essential pkg-config libssl-dev
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    fi

    if [ -f "$HOME/.cargo/env" ]; then
        # shellcheck source=/dev/null
        . "$HOME/.cargo/env"
    elif [ -f "/root/.cargo/env" ] && [ "$(id -u)" -eq 0 ]; then
        # shellcheck source=/dev/null
        . "/root/.cargo/env"
    fi

    command -v cargo >/dev/null 2>&1 || die "Cargo/Rust не установлен."
}

native_service_exists() {
    systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "${NATIVE_SERVICE}.service"
}

native_is_running() {
    systemctl is-active --quiet "$NATIVE_SERVICE" 2>/dev/null
}

docker_is_present() {
    [ -f "$DOCKER_COMPOSE_FILE" ] || run_root docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$DOCKER_CONTAINER"
}

docker_is_running() {
    run_root docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$DOCKER_CONTAINER"
}

panel_is_installed() {
    [ -x "$PANEL_BIN" ] || [ -f "$PANEL_SERVICE_FILE" ] || [ -f "$PANEL_CFG" ]
}

choose_target_mode() {
    local native_present=0 docker_present=0
    native_service_exists && native_present=1
    docker_is_present && docker_present=1

    if [ "$native_present" -eq 1 ] && [ "$docker_present" -eq 0 ]; then
        echo "native"
        return
    fi
    if [ "$native_present" -eq 0 ] && [ "$docker_present" -eq 1 ]; then
        echo "docker"
        return
    fi
    if [ "$native_present" -eq 1 ] && [ "$docker_present" -eq 1 ]; then
        echo
        echo "Найдено и native, и docker."
        echo "1) Native service"
        echo "2) Docker"
        local ch
        ch="$(ask "Выберите цель" "1")"
        [ "$ch" = "2" ] && echo "docker" || echo "native"
        return
    fi

    echo "none"
}

choose_native_method() {
    echo
    echo "Как установить/обновить native Telemt?"
    echo "1) Скачать официальный release-бинарник (рекомендовано)"
    echo "2) Собрать из исходников по последнему tag"
    echo "3) Собрать из исходников из main"
    local ch
    ch="$(ask "Выберите способ" "1")"
    case "$ch" in
        2) echo "source-tag" ;;
        3) echo "source-main" ;;
        *) echo "release" ;;
    esac
}

choose_docker_method() {
    echo
    echo "Как установить/обновить Docker Telemt?"
    echo "1) docker pull latest image"
    echo "2) Собрать image из исходников по последнему tag"
    echo "3) Собрать image из исходников из main"
    local ch
    ch="$(ask "Выберите способ" "1")"
    case "$ch" in
        2) echo "build-tag" ;;
        3) echo "build-main" ;;
        *) echo "pull" ;;
    esac
}

ask_domain_and_secret() {
    local domain secret
    domain="$(ask "Домен маскировки (tls_domain)" "google.com")"
    secret="$(ask "Секрет для пользователя hello (32 hex, Enter = сгенерировать)" "")"
    if [ -z "$secret" ]; then
        secret="$(openssl rand -hex 16)"
        log "Сгенерирован secret: $secret"
    fi
    echo "${domain}|${secret}"
}

# -----------------------------
# Telemt source / build / release
# -----------------------------
clone_telemt_repo() {
    local ref_mode="$1"

    rm -rf "$BUILD_DIR"
    mkdir -p "$WORK_DIR"

    log "Клонирую Telemt repo"
    git clone "$TELEMT_REPO" "$BUILD_DIR" >/dev/null 2>&1

    cd "$BUILD_DIR" || exit 1

    if [ "$ref_mode" = "source-main" ] || [ "$ref_mode" = "build-main" ] || [ "$ref_mode" = "main" ]; then
        git checkout main >/dev/null 2>&1
        log "Checkout: main"
    else
        local tag
        tag="$(git tag --sort=-v:refname | grep -E '^[0-9]+(\.[0-9]+)+$' | head -n1 || true)"
        [ -z "$tag" ] && tag="$(git tag --sort=-v:refname | head -n1 || true)"
        [ -n "$tag" ] || die "Не удалось определить git tag для сборки."
        git checkout "$tag" >/dev/null 2>&1
        log "Checkout: $tag"
    fi
}

install_native_release() {
    local tmp arch libc url
    tmp="$(mktemp -d)"
    arch="$(uname -m)"
    libc="gnu"
    ldd --version 2>&1 | grep -iq musl && libc="musl"

    url="https://github.com/telemt/telemt/releases/latest/download/telemt-${arch}-linux-${libc}.tar.gz"

    log "Скачиваю официальный Telemt release"
    curl -fsSL "$url" | tar -xz -C "$tmp"
    [ -f "$tmp/telemt" ] || die "В архиве Telemt не найден бинарник telemt"

    run_root install -m 0755 "$tmp/telemt" "$NATIVE_BIN"
    rm -rf "$tmp"
}

build_native_from_source() {
    local ref_mode="$1"
    ensure_rust_toolchain
    clone_telemt_repo "$ref_mode"

    log "Собираю Telemt из исходников"
    cargo build --release

    [ -f "$BUILD_DIR/target/release/telemt" ] || die "Сборка Telemt не создала target/release/telemt"
    run_root install -m 0755 "$BUILD_DIR/target/release/telemt" "$NATIVE_BIN"
}

build_docker_image_from_source() {
    local ref_mode="$1"
    ensure_docker
    clone_telemt_repo "$ref_mode"

    log "Собираю Docker image Telemt"
    run_root docker build -t "$DOCKER_IMAGE" "$BUILD_DIR"
}

pull_docker_image() {
    ensure_docker
    log "Тяну Docker image $DOCKER_IMAGE"
    run_root docker pull "$DOCKER_IMAGE"
}

# -----------------------------
# Config templates / patchers
# -----------------------------
write_new_native_config() {
    local domain="$1"
    local secret="$2"

    run_root mkdir -p "$NATIVE_CFG_DIR"
    run_root tee "$NATIVE_CFG" >/dev/null <<EOF
[general]
use_middle_proxy = true
log_level = "normal"

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"

[server]
port = 443

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32"]
minimal_runtime_enabled = false
minimal_runtime_cache_ttl_ms = 1000

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain = "$domain"
mask = true
tls_emulation = true
tls_front_dir = "tlsfront"

[access.users]
hello = "$secret"
EOF
}

write_new_docker_config() {
    local domain="$1"
    local secret="$2"

    mkdir -p "$WORK_DIR"
    cat > "$DOCKER_CFG" <<EOF
[general]
use_middle_proxy = true
log_level = "normal"

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"

[server]
port = 443

[server.api]
enabled = true
listen = "0.0.0.0:9091"
whitelist = ["127.0.0.0/8", "172.16.0.0/12", "10.0.0.0/8", "192.168.0.0/16"]
minimal_runtime_enabled = false
minimal_runtime_cache_ttl_ms = 1000

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain = "$domain"
mask = true
tls_emulation = true
tls_front_dir = "tlsfront"

[access.users]
hello = "$secret"
EOF
}

upsert_server_api_block() {
    local cfg="$1"
    local listen="$2"
    local whitelist_json="$3"

    python3 - "$cfg" "$listen" "$whitelist_json" <<'PY'
from pathlib import Path
import sys, json

cfg = Path(sys.argv[1])
listen = sys.argv[2]
whitelist = json.loads(sys.argv[3])

text = cfg.read_text() if cfg.exists() else ""
lines = text.splitlines()

block = [
    "[server.api]",
    "enabled = true",
    f'listen = "{listen}"',
    f'whitelist = {json.dumps(whitelist)}',
    "minimal_runtime_enabled = false",
    "minimal_runtime_cache_ttl_ms = 1000",
]

out = []
in_api = False
done = False

for line in lines:
    s = line.strip()
    if s == "[server.api]":
        if not done:
            out.extend(block)
            done = True
        in_api = True
        continue

    if in_api and s.startswith("[") and s != "[server.api]":
        in_api = False
        out.append(line)
        continue

    if not in_api:
        out.append(line)

if not done:
    if out and out[-1] != "":
        out.append("")
    out.extend(block)

cfg.write_text("\n".join(out).rstrip() + "\n")
PY
}

ensure_native_api_config() {
    [ -f "$NATIVE_CFG" ] || die "Не найден native config: $NATIVE_CFG"
    upsert_server_api_block "$NATIVE_CFG" "127.0.0.1:9091" '["127.0.0.1/32"]'
}

ensure_docker_api_config() {
    [ -f "$DOCKER_CFG" ] || die "Не найден docker config: $DOCKER_CFG"
    upsert_server_api_block "$DOCKER_CFG" "0.0.0.0:9091" '["127.0.0.0/8", "172.16.0.0/12", "10.0.0.0/8", "192.168.0.0/16"]'
}

write_docker_compose_file() {
    mkdir -p "$WORK_DIR"
    cat > "$DOCKER_COMPOSE_FILE" <<EOF
services:
  telemt:
    image: ${DOCKER_IMAGE}
    container_name: ${DOCKER_CONTAINER}
    restart: unless-stopped
    ports:
      - "443:443"
      - "127.0.0.1:9091:9091"
    volumes:
      - ./config.toml:/app/config.toml:ro
    read_only: true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
EOF
}

# -----------------------------
# Native runtime
# -----------------------------
ensure_native_user_and_paths() {
    if ! id "$NATIVE_USER" >/dev/null 2>&1; then
        log "Создаю пользователя $NATIVE_USER"
        run_root useradd -d "$NATIVE_HOME" -m -r -U "$NATIVE_USER"
    fi

    run_root mkdir -p "$NATIVE_HOME" "$NATIVE_CFG_DIR"
    run_root chown -R "${NATIVE_USER}:${NATIVE_GROUP}" "$NATIVE_HOME"
    run_root chown -R "${NATIVE_USER}:${NATIVE_GROUP}" "$NATIVE_CFG_DIR"
    run_root chmod 750 "$NATIVE_CFG_DIR"
}

fix_native_permissions() {
    ensure_native_user_and_paths
    [ -f "$NATIVE_CFG" ] && run_root chown "${NATIVE_USER}:${NATIVE_GROUP}" "$NATIVE_CFG"
    [ -f "$NATIVE_CFG" ] && run_root chmod 640 "$NATIVE_CFG"
}

install_native_service_file() {
    run_root tee "/etc/systemd/system/${NATIVE_SERVICE}.service" >/dev/null <<EOF
[Unit]
Description=Telemt
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${NATIVE_USER}
Group=${NATIVE_GROUP}
WorkingDirectory=${NATIVE_HOME}
ExecStart=${NATIVE_BIN} ${NATIVE_CFG}
Restart=on-failure
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
}

start_native() {
    fix_native_permissions
    install_native_service_file
    run_root systemctl daemon-reload
    run_root systemctl enable --now "$NATIVE_SERVICE"
}

restart_native_if_present() {
    if native_service_exists; then
        run_root systemctl restart "$NATIVE_SERVICE"
    fi
}

stop_native_if_present() {
    if native_service_exists; then
        run_root systemctl stop "$NATIVE_SERVICE" 2>/dev/null || true
        run_root systemctl disable "$NATIVE_SERVICE" 2>/dev/null || true
    fi
}

# -----------------------------
# Docker runtime
# -----------------------------
docker_up() {
    compose up -d
}

docker_recreate() {
    compose up -d --force-recreate
}

docker_down_if_present() {
    if [ -f "$DOCKER_COMPOSE_FILE" ]; then
        compose down 2>/dev/null || true
    else
        run_root docker rm -f "$DOCKER_CONTAINER" 2>/dev/null || true
    fi
}

# -----------------------------
# Panel install / config / service
# -----------------------------
install_panel_binary_latest() {
    local arch latest tarball binary_name tmp
    arch="$(uname -m)"

    case "$arch" in
        x86_64|aarch64) ;;
        *) die "Неподдерживаемая архитектура для panel release: $arch" ;;
    esac

    latest="$(curl -fsSL "$PANEL_RELEASE_API" | grep '"tag_name"' | cut -d'"' -f4 | head -n1)"
    [ -n "$latest" ] || die "Не удалось определить последний release telemt_panel"

    tarball="telemt-panel-${arch}-linux-gnu.tar.gz"
    binary_name="telemt-panel-${arch}-linux"
    tmp="$(mktemp -d)"

    log "Скачиваю telemt-panel $latest"
    curl -fsSL "https://github.com/amirotin/telemt_panel/releases/download/${latest}/${tarball}" -o "${tmp}/${tarball}"
    tar -xzf "${tmp}/${tarball}" -C "$tmp"

    [ -f "${tmp}/${binary_name}" ] || die "В архиве панели не найден бинарник ${binary_name}"
    run_root install -m 0755 "${tmp}/${binary_name}" "$PANEL_BIN"
    rm -rf "$tmp"
}

create_panel_service_file() {
    run_root tee "$PANEL_SERVICE_FILE" >/dev/null <<EOF
[Unit]
Description=Telemt Panel
After=network.target

[Service]
Type=simple
ExecStart=${PANEL_BIN} --config ${PANEL_CFG}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
}

hash_panel_password() {
    local password="$1"
    printf '%s' "$password" | "$PANEL_BIN" hash-password
}

create_panel_config_fresh() {
    local mode="$1"
    local admin_user admin_pass admin_pass2 pass_hash jwt_secret

    mkdir -p "$PANEL_CFG_DIR"

    admin_user="$(ask "Логин администратора панели" "admin")"

    while true; do
        admin_pass="$(ask_secret "Пароль администратора панели")"
        [ -n "$admin_pass" ] || { warn "Пароль не должен быть пустым"; continue; }
        admin_pass2="$(ask_secret "Повторите пароль")"
        [ "$admin_pass" = "$admin_pass2" ] && break
        warn "Пароли не совпали, повторите."
    done

    pass_hash="$(hash_panel_password "$admin_pass")"
    jwt_secret="$(openssl rand -hex 32)"

    run_root mkdir -p "$PANEL_CFG_DIR"

    if [ "$mode" = "native" ]; then
        run_root tee "$PANEL_CFG" >/dev/null <<EOF
listen = "0.0.0.0:8080"

[telemt]
url = "http://127.0.0.1:9091"
auth_header = ""
binary_path = "/bin/telemt"
service_name = "telemt"

[auth]
username = "$admin_user"
password_hash = "$pass_hash"
jwt_secret = "$jwt_secret"
session_ttl = "24h"
EOF
    else
        run_root tee "$PANEL_CFG" >/dev/null <<EOF
listen = "0.0.0.0:8080"

[telemt]
url = "http://127.0.0.1:9091"
auth_header = ""

[auth]
username = "$admin_user"
password_hash = "$pass_hash"
jwt_secret = "$jwt_secret"
session_ttl = "24h"
EOF
    fi

    run_root chmod 600 "$PANEL_CFG"
}

sync_panel_telemt_section() {
    local mode="$1"

    run_root python3 - "$PANEL_CFG" "$mode" <<'PY'
from pathlib import Path
import sys

cfg = Path(sys.argv[1])
mode = sys.argv[2]

text = cfg.read_text() if cfg.exists() else ""
lines = text.splitlines()

if mode == "native":
    telemt_block = [
        "[telemt]",
        'url = "http://127.0.0.1:9091"',
        'auth_header = ""',
        'binary_path = "/bin/telemt"',
        'service_name = "telemt"',
    ]
else:
    telemt_block = [
        "[telemt]",
        'url = "http://127.0.0.1:9091"',
        'auth_header = ""',
    ]

out = []
in_telemt = False
done = False

for line in lines:
    s = line.strip()

    if s == "[telemt]":
        if not done:
            out.extend(telemt_block)
            done = True
        in_telemt = True
        continue

    if in_telemt and s.startswith("[") and s != "[telemt]":
        in_telemt = False
        out.append(line)
        continue

    if not in_telemt:
        out.append(line)

if not done:
    if out and out[-1] != "":
        out.append("")
    out.extend(telemt_block)

if not any(line.strip().startswith("listen = ") for line in out):
    out.insert(0, 'listen = "0.0.0.0:8080"')

cfg.write_text("\n".join(out).rstrip() + "\n")
PY

    run_root chmod 600 "$PANEL_CFG"
}

install_or_update_panel_for_mode() {
    local mode="$1"

    install_panel_binary_latest

    if [ ! -f "$PANEL_CFG" ]; then
        create_panel_config_fresh "$mode"
    else
        sync_panel_telemt_section "$mode"
    fi

    create_panel_service_file
    run_root systemctl daemon-reload
    run_root systemctl enable --now "$PANEL_SERVICE_NAME"
}

restart_panel_if_present() {
    if panel_is_installed; then
        run_root systemctl restart "$PANEL_SERVICE_NAME" 2>/dev/null || true
    fi
}

# -----------------------------
# Status / links
# -----------------------------
get_external_ip() {
    curl -fsS --max-time 8 -4 ifconfig.me 2>/dev/null || true
}

print_telemt_link_from_cfg() {
    local cfg="$1"
    [ -f "$cfg" ] || return 1

    local domain secret hex ip
    domain="$(cfg_cat "$cfg" | awk -F'"' '/^tls_domain[[:space:]]*=/{print $2; exit}')"
    if [ -z "$domain" ]; then
        domain="$(cfg_cat "$cfg" | awk '
            BEGIN{in_c=0}
            /^\[censorship\]/{in_c=1; next}
            in_c && /^tls_domain[[:space:]]*=/{gsub(/"/,"",$3); print $3; exit}
        ')"
    fi

    secret="$(cfg_cat "$cfg" | awk '
        BEGIN{in_u=0}
        /^\[access\.users\]/{in_u=1; next}
        in_u && /^\[/{in_u=0}
        in_u && /^[[:space:]]*[A-Za-z0-9_.-]+[[:space:]]*=/ {
            gsub(/"/, "", $3)
            print $3
            exit
        }
    ')"

    [ -n "$domain" ] || return 1
    [ -n "$secret" ] || return 1

    hex="$(echo -n "$domain" | hexdump -v -e '/1 "%02x"')"
    ip="$(get_external_ip)"

    echo "═════════════════════════════════════════════════════"
    if [ -n "$ip" ]; then
        echo "🔗 TELEGRAM: tg://proxy?server=${ip}&port=443&secret=ee${secret}${hex}"
        echo "🌐 PANEL:    http://${ip}:8080"
    else
        echo "🔐 tls_domain: ${domain}"
        echo "🔐 secret:    ${secret}"
        echo "🌐 PANEL:     http://<ВАШ_IP>:8080"
    fi
    echo "═════════════════════════════════════════════════════"
}

telemt_api_probe() {
    curl -fsS --max-time 5 http://127.0.0.1:9091/v1/users 2>/dev/null || true
}

show_status() {
    echo
    echo "═════════════════════════════════════════════════════"
    echo "               ТЕКУЩЕЕ СОСТОЯНИЕ"
    echo "═════════════════════════════════════════════════════"

    if native_service_exists; then
        echo "Native unit:   есть"
        if native_is_running; then
            echo "Native status: запущен"
        else
            echo "Native status: остановлен"
        fi
        echo "Native bin:    ${NATIVE_BIN}"
        echo "Native cfg:    ${NATIVE_CFG}"
    else
        echo "Native unit:   нет"
    fi

    if docker_is_present; then
        echo "Docker setup:  есть"
        if docker_is_running; then
            echo "Docker status: запущен"
        else
            echo "Docker status: остановлен"
        fi
        echo "Docker dir:    ${WORK_DIR}"
        echo "Container:     ${DOCKER_CONTAINER}"
    else
        echo "Docker setup:  нет"
    fi

    if panel_is_installed; then
        echo "Panel:         установлена"
        if systemctl is-active --quiet "$PANEL_SERVICE_NAME" 2>/dev/null; then
            echo "Panel status:  запущена"
        else
            echo "Panel status:  остановлена"
        fi
        echo "Panel cfg:     ${PANEL_CFG}"
    else
        echo "Panel:         нет"
    fi

    local probe
    probe="$(telemt_api_probe)"
    if [ -n "$probe" ]; then
        echo
        echo "API probe (127.0.0.1:9091/v1/users):"
        echo "$probe"
    else
        echo
        echo "API probe: нет ответа"
    fi

    echo
    if docker_is_present; then
        print_telemt_link_from_cfg "$DOCKER_CFG" || true
    elif native_service_exists; then
        print_telemt_link_from_cfg "$NATIVE_CFG" || true
    fi
}

# -----------------------------
# Cleanup / remove
# -----------------------------
safe_cleanup() {
    echo
    log "Безопасная очистка мусора"
    rm -rf "$BUILD_DIR" 2>/dev/null || true
    run_root docker builder prune -f >/dev/null 2>&1 || true
    run_root docker image prune -f >/dev/null 2>&1 || true
    log "Очистка завершена"
}

remove_all() {
    echo
    echo "🗑️  Будет удалено:"
    echo " - native Telemt service, binary, config"
    echo " - docker Telemt container/image/workdir"
    echo " - telemt-panel service, binary, config"
    echo " - пользователь ${NATIVE_USER} и ${NATIVE_HOME}"
    echo
    confirm "Подтвердить полное удаление всего, что связано с Telemt?" "N" || {
        echo "Отменено."
        return 0
    }

    docker_down_if_present
    run_root docker rm -f "$DOCKER_CONTAINER" 2>/dev/null || true
    run_root docker rmi "$DOCKER_IMAGE" 2>/dev/null || true

    if native_service_exists; then
        run_root systemctl stop "$NATIVE_SERVICE" 2>/dev/null || true
        run_root systemctl disable "$NATIVE_SERVICE" 2>/dev/null || true
    fi
    run_root rm -f "/etc/systemd/system/${NATIVE_SERVICE}.service"

    if panel_is_installed; then
        run_root systemctl stop "$PANEL_SERVICE_NAME" 2>/dev/null || true
        run_root systemctl disable "$PANEL_SERVICE_NAME" 2>/dev/null || true
    fi
    run_root rm -f "$PANEL_SERVICE_FILE"

    run_root rm -f "$NATIVE_BIN" "$PANEL_BIN"
    run_root rm -rf "$NATIVE_CFG_DIR" "$PANEL_CFG_DIR" "$NATIVE_HOME" "$WORK_DIR"

    if id "$NATIVE_USER" >/dev/null 2>&1; then
        run_root userdel -r "$NATIVE_USER" 2>/dev/null || true
    fi

    run_root systemctl daemon-reload
    safe_cleanup
    log "Всё удалено"
}

# -----------------------------
# Install flows
# -----------------------------
install_native_flow() {
    local with_panel="$1"
    local method domain secret pair

    install_base_deps

    method="$(choose_native_method)"
    pair="$(ask_domain_and_secret)"
    domain="${pair%%|*}"
    secret="${pair##*|}"

    case "$method" in
        release)     install_native_release ;;
        source-tag)  build_native_from_source "source-tag" ;;
        source-main) build_native_from_source "source-main" ;;
        *) die "Неизвестный native method: $method" ;;
    esac

    ensure_native_user_and_paths
    write_new_native_config "$domain" "$secret"
    ensure_native_api_config
    start_native

    if [ "$with_panel" = "yes" ]; then
        install_or_update_panel_for_mode "native"
    fi

    safe_cleanup
    show_status
}

install_docker_flow() {
    local with_panel="$1"
    local method domain secret pair

    install_base_deps
    ensure_docker

    method="$(choose_docker_method)"
    pair="$(ask_domain_and_secret)"
    domain="${pair%%|*}"
    secret="${pair##*|}"

    write_new_docker_config "$domain" "$secret"
    ensure_docker_api_config
    write_docker_compose_file

    case "$method" in
        pull)       pull_docker_image ;;
        build-tag)  build_docker_image_from_source "build-tag" ;;
        build-main) build_docker_image_from_source "build-main" ;;
        *) die "Неизвестный docker method: $method" ;;
    esac

    docker_up

    if [ "$with_panel" = "yes" ]; then
        install_or_update_panel_for_mode "docker"
    fi

    safe_cleanup
    show_status
}

# -----------------------------
# Panel attach / repair
# -----------------------------
install_or_repair_panel_for_existing() {
    install_base_deps

    local target
    target="$(choose_target_mode)"

    case "$target" in
        native)
            [ -f "$NATIVE_CFG" ] || die "Не найден native config: $NATIVE_CFG"
            ensure_native_api_config
            restart_native_if_present
            install_or_update_panel_for_mode "native"
            ;;
        docker)
            [ -f "$DOCKER_CFG" ] || die "Не найден docker config: $DOCKER_CFG"
            ensure_docker
            ensure_docker_api_config
            write_docker_compose_file
            docker_recreate
            install_or_update_panel_for_mode "docker"
            ;;
        *)
            die "Не найден установленный Telemt ни в native, ни в docker."
            ;;
    esac

    safe_cleanup
    show_status
}

# -----------------------------
# Update flows
# -----------------------------
update_native_flow() {
    local method
    install_base_deps

    [ -f "$NATIVE_CFG" ] || die "Native config не найден: $NATIVE_CFG"

    method="$(choose_native_method)"
    case "$method" in
        release)     install_native_release ;;
        source-tag)  build_native_from_source "source-tag" ;;
        source-main) build_native_from_source "source-main" ;;
        *) die "Неизвестный native method: $method" ;;
    esac

    ensure_native_api_config
    start_native

    if panel_is_installed; then
        sync_panel_telemt_section "native"
        restart_panel_if_present
    fi

    safe_cleanup
    show_status
}

update_docker_flow() {
    local method
    install_base_deps
    ensure_docker

    [ -f "$DOCKER_CFG" ] || die "Docker config не найден: $DOCKER_CFG"
    write_docker_compose_file
    ensure_docker_api_config

    method="$(choose_docker_method)"
    case "$method" in
        pull)       pull_docker_image ;;
        build-tag)  build_docker_image_from_source "build-tag" ;;
        build-main) build_docker_image_from_source "build-main" ;;
        *) die "Неизвестный docker method: $method" ;;
    esac

    docker_recreate

    if panel_is_installed; then
        sync_panel_telemt_section "docker"
        restart_panel_if_present
    fi

    safe_cleanup
    show_status
}

update_existing_flow() {
    local target
    target="$(choose_target_mode)"

    case "$target" in
        native) update_native_flow ;;
        docker) update_docker_flow ;;
        *) die "Нет ни native, ни docker установки для обновления." ;;
    esac
}

# -----------------------------
# Migration flows
# -----------------------------
maybe_keep_or_install_panel() {
    if panel_is_installed; then
        echo "yes"
        return
    fi

    if confirm "Панель не установлена. Установить её в целевом режиме?" "Y"; then
        echo "yes"
    else
        echo "no"
    fi
}

migrate_native_to_docker() {
    install_base_deps
    ensure_docker

    [ -f "$NATIVE_CFG" ] || die "Не найден native config: $NATIVE_CFG"

    local method with_panel
    method="$(choose_docker_method)"
    with_panel="$(maybe_keep_or_install_panel)"

    mkdir -p "$WORK_DIR"
    run_root cp "$NATIVE_CFG" "$DOCKER_CFG"
    run_root chown "$(id -u)":"$(id -g)" "$DOCKER_CFG" 2>/dev/null || true

    ensure_docker_api_config
    write_docker_compose_file

    case "$method" in
        pull)       pull_docker_image ;;
        build-tag)  build_docker_image_from_source "build-tag" ;;
        build-main) build_docker_image_from_source "build-main" ;;
        *) die "Неизвестный docker method: $method" ;;
    esac

    stop_native_if_present
    docker_up

    if [ "$with_panel" = "yes" ]; then
        install_or_update_panel_for_mode "docker"
    fi

    safe_cleanup
    show_status
}

migrate_docker_to_native() {
    install_base_deps

    [ -f "$DOCKER_CFG" ] || die "Не найден docker config: $DOCKER_CFG"

    local method with_panel
    method="$(choose_native_method)"
    with_panel="$(maybe_keep_or_install_panel)"

    case "$method" in
        release)     install_native_release ;;
        source-tag)  build_native_from_source "source-tag" ;;
        source-main) build_native_from_source "source-main" ;;
        *) die "Неизвестный native method: $method" ;;
    esac

    ensure_native_user_and_paths
    run_root mkdir -p "$NATIVE_CFG_DIR"
    run_root cp "$DOCKER_CFG" "$NATIVE_CFG"
    ensure_native_api_config

    docker_down_if_present
    start_native

    if [ "$with_panel" = "yes" ]; then
        install_or_update_panel_for_mode "native"
    fi

    safe_cleanup
    show_status
}

# -----------------------------
# Menus
# -----------------------------
menu_new_install() {
    echo
    echo "Новая установка"
    echo "1) Native service"
    echo "2) Docker container"
    local ch with_panel
    ch="$(ask "Выберите тип установки" "1")"

    if confirm "Установить вместе с панелью?" "Y"; then
        with_panel="yes"
    else
        with_panel="no"
    fi

    case "$ch" in
        2) install_docker_flow "$with_panel" ;;
        *) install_native_flow "$with_panel" ;;
    esac
}

menu_main() {
    clear || true
    echo "═════════════════════════════════════════════════════"
    echo " 🛠️  Telemt Manager"
    echo "═════════════════════════════════════════════════════"
    echo "1) Новая установка"
    echo "2) Установить / обновить / починить панель"
    echo "3) Обновить существующий Telemt"
    echo "4) Миграция service → Docker"
    echo "5) Миграция Docker → service"
    echo "6) Показать статус и ссылки"
    echo "7) Удалить всё, что связано с Telemt"
    echo "8) Очистить мусор (ключи/ссылки не удаляются)"
    echo "0) Выход"
    echo
}

# -----------------------------
# Main loop
# -----------------------------
main() {
    install_base_deps

    while true; do
        menu_main
        local choice
        choice="$(ask "Выберите пункт" "6")"

        case "$choice" in
            1) menu_new_install ;;
            2) install_or_repair_panel_for_existing ;;
            3) update_existing_flow ;;
            4) migrate_native_to_docker ;;
            5) migrate_docker_to_native ;;
            6) show_status ;;
            7) remove_all ;;
            8) safe_cleanup ;;
            0) exit 0 ;;
            *) warn "Неверный выбор" ;;
        esac

        echo
        read -r -p "Нажмите Enter, чтобы вернуться в меню..." <"$TTY_INPUT" || true
    done
}

main "$@"
