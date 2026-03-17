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
DOCKER_IMAGE="ghcr.io/telemt/telemt:latest"
DOCKER_CONTAINER="telemt_proxy"
DOCKER_COMPOSE_FILE="${WORK_DIR}/docker-compose.yml"
DOCKER_CONFIG="${WORK_DIR}/config.toml"
TTY_INPUT="/dev/tty"
[ -r "$TTY_INPUT" ] || TTY_INPUT="/dev/stdin"

say(){ printf ' %s\n' "$*"; }
ok(){ printf '✅ %s\n' "$*"; }
warn(){ printf '⚠️ %s\n' "$*" >&2; }
die(){ printf '❌ %s\n' "$*" >&2; exit 1; }
pause(){ printf '\nНажмите Enter, чтобы вернуться в меню...' >"$TTY_INPUT"; read -r _ <"$TTY_INPUT" || true; }
need_root(){ [ "$(id -u)" -eq 0 ] || die "Запускайте этот скрипт от root"; }

ask(){
  local prompt="$1" default="${2-}" answer
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$prompt" "$default" >"$TTY_INPUT"
  else
    printf '%s: ' "$prompt" >"$TTY_INPUT"
  fi
  IFS= read -r answer <"$TTY_INPUT" || answer=""
  [ -n "$answer" ] && printf '%s' "$answer" || printf '%s' "$default"
}

menu_choice(){
  local title="$1" default="$2"; shift 2
  local i=1 item
  printf '\n%s\n' "$title" >"$TTY_INPUT"
  for item in "$@"; do
    printf '%d) %s\n' "$i" "$item" >"$TTY_INPUT"
    i=$((i+1))
  done
  ask "Выберите пункт" "$default"
}

pkg_installed(){ dpkg -s "$1" >/dev/null 2>&1; }
install_base_deps(){
  local pkgs=() p
  for p in ca-certificates curl git gzip grep openssl python3 sed tar coreutils util-linux passwd systemd xxd mawk; do
    pkg_installed "$p" || pkgs+=("$p")
  done
  if [ ${#pkgs[@]} -gt 0 ]; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -yqq "${pkgs[@]}"
  fi
}

latest_tag_any(){
  git ls-remote --tags --refs https://github.com/telemt/telemt.git \
    | awk -F/ '{print $NF}' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -V \
    | tail -n1
}

latest_stable_release_tag(){
  local tag=""
  tag="$({ curl -fsSL https://api.github.com/repos/telemt/telemt/releases/latest 2>/dev/null || true; } | python3 -c 'import sys,json
try:
 d=json.load(sys.stdin); print(d.get("tag_name", ""))
except Exception:
 print("")')"
  if [ -z "$tag" ]; then
    local url
    url="$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/telemt/telemt/releases/latest 2>/dev/null || true)"
    tag="$(printf '%s' "$url" | sed -n 's#^.*/tag/\([^/?#]*\).*$#\1#p')"
  fi
  printf '%s' "$tag"
}

resolve_telemt_tag(){
  local channel="$1" tag=""
  if [ "$channel" = "stable" ]; then
    tag="$(latest_stable_release_tag || true)"
    [ -n "$tag" ] || tag="$(latest_tag_any || true)"
  else
    tag="$(latest_tag_any || true)"
  fi
  [ -n "$tag" ] || die "Не удалось определить версию Telemt"
  printf '%s' "$tag"
}

choose_release_channel(){
  local c
  c="$(menu_choice 'Какую ветку Telemt использовать?' '1' 'LTS / Stable release' 'Последняя release/tag')"
  case "$c" in
    2) printf 'latest' ;;
    *) printf 'stable' ;;
  esac
}

get_ext_ip(){
  local ip=""
  ip="$(curl -4fsSL --max-time 8 ifconfig.me 2>/dev/null || true)"
  if [ -z "$ip" ]; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  fi
  printf '%s' "$ip"
}

read_tls_domain(){ local cfg="$1"; [ -f "$cfg" ] && awk -F'"' '/tls_domain[[:space:]]*=/{print $2; exit}' "$cfg" || true; }
read_secret(){ local cfg="$1"; [ -f "$cfg" ] && awk -F'"' '/^[[:space:]]*(hello|main_user)[[:space:]]*=/{print $2; exit}' "$cfg" || true; }

telegram_links(){
  local ip="$1" domain="$2" secret="$3" hex
  [ -n "$ip" ] && [ -n "$domain" ] && [ -n "$secret" ] || return 0
  hex="$(printf '%s' "$domain" | xxd -p -c 256)"
  printf ' TELEGRAM (tg://): tg://proxy?server=%s&port=443&secret=ee%s%s\n' "$ip" "$secret" "$hex"
  printf ' TELEGRAM (t.me): https://t.me/proxy?server=%s&port=443&secret=ee%s%s\n' "$ip" "$secret" "$hex"
}

write_native_config(){
  local cfg="$1" domain="$2" secret="$3"
  mkdir -p "$(dirname "$cfg")"
  cat >"$cfg" <<CFG
users = { ${secret} = "me" }
ad_tag = ""
tls_domain = "${domain}"

auto_update_time = 0
workers = 1
keepalive_secs = 10
listener = "0.0.0.0:443"

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.0/8"]
minimal_runtime_enabled = false
minimal_runtime_cache_ttl_ms = 1000
CFG
  chmod 600 "$cfg"
}

write_docker_config(){
  local cfg="$1" domain="$2" secret="$3"
  mkdir -p "$(dirname "$cfg")"
  cat >"$cfg" <<CFG
users = { ${secret} = "me" }
ad_tag = ""
tls_domain = "${domain}"

auto_update_time = 0
workers = 1
keepalive_secs = 10
listener = "0.0.0.0:443"

[server.api]
enabled = true
listen = "0.0.0.0:9091"
whitelist = ["127.0.0.0/8", "172.16.0.0/12", "10.0.0.0/8", "192.168.0.0/16"]
minimal_runtime_enabled = false
minimal_runtime_cache_ttl_ms = 1000
CFG
  chmod 600 "$cfg"
}

write_docker_compose(){
  mkdir -p "$WORK_DIR"
  cat >"$DOCKER_COMPOSE_FILE" <<'YML'
services:
  telemt:
    image: ghcr.io/telemt/telemt:latest
    container_name: telemt_proxy
    restart: unless-stopped
    ports:
      - "443:443/tcp"
      - "127.0.0.1:9091:9091/tcp"
    volumes:
      - ./config.toml:/run/telemt/config.toml:ro
    command: ["/run/telemt/config.toml"]
YML
}

service_installed(){ [ -x "$NATIVE_BINARY" ] || [ -f "/etc/systemd/system/${NATIVE_SERVICE}.service" ] || [ -f "$NATIVE_CONFIG" ]; }
service_active(){ systemctl is-active --quiet "$NATIVE_SERVICE" 2>/dev/null; }
panel_installed(){ [ -x "$PANEL_BINARY" ] || [ -f "/etc/systemd/system/${PANEL_SERVICE}.service" ] || [ -f "$PANEL_CONFIG" ]; }
panel_active(){ systemctl is-active --quiet "$PANEL_SERVICE" 2>/dev/null; }
docker_installed(){ command -v docker >/dev/null 2>&1; }
docker_daemon_ok(){ docker info >/dev/null 2>&1; }
docker_mode_configured(){ [ -f "$DOCKER_CONFIG" ] || [ -f "$DOCKER_COMPOSE_FILE" ]; }
docker_container_exists(){ docker_installed && docker_daemon_ok && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$DOCKER_CONTAINER"; }
docker_container_running(){ docker_installed && docker_daemon_ok && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$DOCKER_CONTAINER"; }

repair_docker_service(){
  mkdir -p /etc/systemd/system/docker.service.d
  cat >/etc/systemd/system/docker.service.d/override.conf <<'OVR'
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd -H unix:///var/run/docker.sock --containerd=/run/containerd/containerd.sock
OVR
  systemctl daemon-reload
  systemctl reset-failed docker.service docker.socket 2>/dev/null || true
}

ensure_docker_ready(){
  if ! docker_installed; then
    curl -fsSL https://get.docker.com | sh
  fi
  if ! command -v docker >/dev/null 2>&1; then
    die "Docker не установлен"
  fi
  systemctl enable docker.service >/dev/null 2>&1 || true
  systemctl start docker.service >/dev/null 2>&1 || true
  if ! docker_daemon_ok; then
    repair_docker_service
    rm -f /run/docker.sock /var/run/docker.sock
    systemctl start docker.service >/dev/null 2>&1 || true
  fi
  local i
  for i in $(seq 1 20); do
    if docker_daemon_ok; then
      if docker compose version >/dev/null 2>&1; then
        return 0
      fi
    fi
    sleep 1
  done
  systemctl status docker --no-pager -l || true
  die "Docker daemon не поднялся"
}

compose(){ cd "$WORK_DIR" && docker compose "$@"; }

wait_ports_free(){
  local timeout="${1:-30}" i
  for i in $(seq 1 "$timeout"); do
    if ! ss -ltnp | grep -qE ':(443|9091)\b'; then
      return 0
    fi
    sleep 1
  done
  return 1
}

show_port_holders(){
  ss -ltnp | grep -E ':(443|9091)\b' || true
  fuser -v 443/tcp 9091/tcp 2>/dev/null || true
}

stop_service_mode(){
  systemctl stop "$NATIVE_SERVICE" 2>/dev/null || true
  systemctl disable "$NATIVE_SERVICE" 2>/dev/null || true
  systemctl reset-failed "$NATIVE_SERVICE" 2>/dev/null || true
  for _ in $(seq 1 20); do
    systemctl is-active --quiet "$NATIVE_SERVICE" 2>/dev/null || break
    sleep 1
  done
  if pgrep -f '^/bin/telemt ' >/dev/null 2>&1; then
    pkill -TERM -f '^/bin/telemt ' || true
    sleep 2
    pgrep -f '^/bin/telemt ' >/dev/null 2>&1 && pkill -KILL -f '^/bin/telemt ' || true
  fi
  wait_ports_free 20 || { warn "Порты 443/9091 не освободились"; show_port_holders; return 1; }
}

stop_docker_mode(){
  if docker_installed; then
    systemctl start docker.service >/dev/null 2>&1 || true
  fi
  if docker_installed && docker_daemon_ok; then
    [ -f "$DOCKER_COMPOSE_FILE" ] && compose down --remove-orphans >/dev/null 2>&1 || true
    docker rm -f "$DOCKER_CONTAINER" >/dev/null 2>&1 || true
  fi
  wait_ports_free 20 || { warn "Порты 443/9091 не освободились после остановки Docker"; show_port_holders; return 1; }
}

ensure_native_build_deps(){
  local pkgs=(build-essential pkg-config libssl-dev)
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -yqq "${pkgs[@]}"
  if ! command -v cargo >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  fi
  [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
  command -v cargo >/dev/null 2>&1 || die "cargo не найден"
}

clone_telemt_tag(){
  local tag="$1"
  rm -rf "$BUILD_DIR"
  git clone https://github.com/telemt/telemt.git "$BUILD_DIR" >/dev/null 2>&1
  cd "$BUILD_DIR"
  git checkout "$tag" >/dev/null 2>&1 || die "Не удалось checkout ${tag}"
}

install_service(){
  local domain="$1" secret="$2" channel="$3" tag
  tag="$(resolve_telemt_tag "$channel")"
  ensure_native_build_deps
  clone_telemt_tag "$tag"
  cargo build --release >/dev/null
  install -Dm755 "$BUILD_DIR/target/release/telemt" "$NATIVE_BINARY"
  write_native_config "$NATIVE_CONFIG" "$domain" "$secret"
  cat >/etc/systemd/system/${NATIVE_SERVICE}.service <<UNIT
[Unit]
Description=Telemt Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${NATIVE_BINARY} ${NATIVE_CONFIG}
Restart=always
RestartSec=2
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now "$NATIVE_SERVICE" >/dev/null 2>&1 || die "Не удалось запустить telemt.service"
  ok "Служба Telemt установлена (${tag})"
}

sync_panel_config(){
  local mode="$1"
  mkdir -p "$PANEL_DIR"
  if [ ! -f "$PANEL_CONFIG" ]; then
    cat >"$PANEL_CONFIG" <<CFG
listen = "0.0.0.0:8080"
username = "admin"
password = "admin"

[telemt]
url = "http://127.0.0.1:9091"
auth_header = ""
binary_path = "/bin/telemt"
service_name = "telemt"
CFG
  fi
  python3 - "$PANEL_CONFIG" "$mode" <<'PY'
from pathlib import Path
import sys,re
p=Path(sys.argv[1])
mode=sys.argv[2]
text=p.read_text()
if '[telemt]' not in text:
    text += '\n[telemt]\n'
text=re.sub(r'(?m)^url\s*=\s*".*"$', 'url = "http://127.0.0.1:9091"', text)
text=re.sub(r'(?m)^binary_path\s*=\s*".*"$', 'binary_path = "/bin/telemt"', text)
text=re.sub(r'(?m)^service_name\s*=\s*".*"$', 'service_name = "telemt"', text)
if 'url = "http://127.0.0.1:9091"' not in text:
    text += '\nurl = "http://127.0.0.1:9091"\n'
if 'binary_path = "/bin/telemt"' not in text:
    text += 'binary_path = "/bin/telemt"\n'
if 'service_name = "telemt"' not in text:
    text += 'service_name = "telemt"\n'
p.write_text(text)
PY
}

install_or_update_panel(){
  mkdir -p "$PANEL_DIR"
  curl -fsSL https://raw.githubusercontent.com/amirotin/telemt_panel/main/install.sh | bash
  sync_panel_config auto
  systemctl restart "$PANEL_SERVICE" >/dev/null 2>&1 || true
  ok "Панель установлена/обновлена"
}

remove_panel(){
  systemctl stop "$PANEL_SERVICE" 2>/dev/null || true
  systemctl disable "$PANEL_SERVICE" 2>/dev/null || true
  rm -f "/etc/systemd/system/${PANEL_SERVICE}.service" "$PANEL_BINARY"
  rm -rf "$PANEL_DIR"
  systemctl daemon-reload >/dev/null 2>&1 || true
  ok "Панель удалена"
}

install_docker_mode(){
  local domain="$1" secret="$2" method="$3" channel="${4:-stable}" tag=""
  ensure_docker_ready
  mkdir -p "$WORK_DIR"
  write_docker_config "$DOCKER_CONFIG" "$domain" "$secret"
  write_docker_compose
  if [ "$method" = "build" ]; then
    tag="$(resolve_telemt_tag "$channel")"
    clone_telemt_tag "$tag"
    cd "$BUILD_DIR"
    docker build -t "$DOCKER_IMAGE" .
  else
    docker pull "$DOCKER_IMAGE" >/dev/null
  fi
  compose down --remove-orphans >/dev/null 2>&1 || true
  docker rm -f "$DOCKER_CONTAINER" >/dev/null 2>&1 || true
  compose up -d >/dev/null || die "Не удалось поднять Docker Telemt"
  ok "Docker Telemt установлен"
}

new_install(){
  local choice domain secret method channel
  choice="$(menu_choice 'Новая установка' '1' 'Служба + панель' 'Только служба' 'Docker + панель' 'Только Docker')"
  domain="$(ask 'Домен маскировки' 'google.com')"
  secret="$(openssl rand -hex 16)"
  case "$choice" in
    1)
      channel="$(choose_release_channel)"
      install_service "$domain" "$secret" "$channel"
      install_or_update_panel
      ;;
    2)
      channel="$(choose_release_channel)"
      install_service "$domain" "$secret" "$channel"
      ;;
    3)
      method="$(menu_choice 'Как получить Docker-образ Telemt?' '1' 'Docker pull (ghcr.io/telemt/telemt:latest)' 'Сборка из исходников')"
      if [ "$method" = "2" ]; then channel="$(choose_release_channel)"; install_docker_mode "$domain" "$secret" build "$channel"; else install_docker_mode "$domain" "$secret" pull; fi
      install_or_update_panel
      ;;
    4)
      method="$(menu_choice 'Как получить Docker-образ Telemt?' '1' 'Docker pull (ghcr.io/telemt/telemt:latest)' 'Сборка из исходников')"
      if [ "$method" = "2" ]; then channel="$(choose_release_channel)"; install_docker_mode "$domain" "$secret" build "$channel"; else install_docker_mode "$domain" "$secret" pull; fi
      ;;
  esac
}

update_existing(){
  local choice channel method cfg domain secret
  choice="$(menu_choice 'Обновить существующий Telemt' '1' 'Службу' 'Docker')"
  case "$choice" in
    1)
      cfg="$NATIVE_CONFIG"; [ -f "$cfg" ] || die "Не найден native config"
      domain="$(read_tls_domain "$cfg")"; secret="$(read_secret "$cfg")"
      channel="$(choose_release_channel)"
      install_service "$domain" "$secret" "$channel"
      panel_installed && { sync_panel_config auto; systemctl restart "$PANEL_SERVICE" >/dev/null 2>&1 || true; }
      ;;
    2)
      cfg="$DOCKER_CONFIG"; [ -f "$cfg" ] || die "Не найден Docker config"
      domain="$(read_tls_domain "$cfg")"; secret="$(read_secret "$cfg")"
      method="$(menu_choice 'Как обновить Docker Telemt?' '1' 'Docker pull latest image' 'Сборка из исходников')"
      if [ "$method" = "2" ]; then channel="$(choose_release_channel)"; install_docker_mode "$domain" "$secret" build "$channel"; else install_docker_mode "$domain" "$secret" pull; fi
      panel_installed && { sync_panel_config auto; systemctl restart "$PANEL_SERVICE" >/dev/null 2>&1 || true; }
      ;;
  esac
}

migrate_service_to_docker(){
  local cfg domain secret method channel
  cfg="$NATIVE_CONFIG"
  [ -f "$cfg" ] || die "Не найден native config для миграции"
  domain="$(read_tls_domain "$cfg")"
  secret="$(read_secret "$cfg")"
  method="$(menu_choice 'Как получить Docker-образ Telemt?' '1' 'Docker pull (ghcr.io/telemt/telemt:latest)' 'Сборка из исходников')"
  stop_service_mode || die "Не удалось корректно остановить службу Telemt"
  ensure_docker_ready
  write_docker_config "$DOCKER_CONFIG" "$domain" "$secret"
  write_docker_compose
  if [ "$method" = "2" ]; then
    channel="$(choose_release_channel)"
    clone_telemt_tag "$(resolve_telemt_tag "$channel")"
    cd "$BUILD_DIR"
    docker build -t "$DOCKER_IMAGE" .
  else
    docker pull "$DOCKER_IMAGE" >/dev/null
  fi
  compose down --remove-orphans >/dev/null 2>&1 || true
  docker rm -f "$DOCKER_CONTAINER" >/dev/null 2>&1 || true
  wait_ports_free 15 || { show_port_holders; die "Порты 443/9091 заняты перед запуском Docker"; }
  compose up -d || { show_port_holders; die "Не удалось запустить Docker Telemt"; }
  rm -rf "$NATIVE_DIR" "$NATIVE_BINARY"
  rm -f "/etc/systemd/system/${NATIVE_SERVICE}.service"
  systemctl daemon-reload >/dev/null 2>&1 || true
  panel_installed && { sync_panel_config auto; systemctl restart "$PANEL_SERVICE" >/dev/null 2>&1 || true; }
  ok "Миграция service → Docker завершена"
}

migrate_docker_to_service(){
  local cfg domain secret channel
  cfg="$DOCKER_CONFIG"
  [ -f "$cfg" ] || die "Не найден Docker config для миграции"
  domain="$(read_tls_domain "$cfg")"
  secret="$(read_secret "$cfg")"
  stop_docker_mode || die "Не удалось корректно остановить Docker Telemt"
  channel="$(choose_release_channel)"
  install_service "$domain" "$secret" "$channel"
  rm -rf "$WORK_DIR"
  panel_installed && { sync_panel_config auto; systemctl restart "$PANEL_SERVICE" >/dev/null 2>&1 || true; }
  ok "Миграция Docker → service завершена"
}

status_and_links(){
  local ip domain secret active_cfg="" mode=""
  printf '\n📊 Статус Telemt\n'
  if service_installed; then
    printf '• Service mode: установлен\n'
    printf '  └─ состояние: %s\n' "$(systemctl is-active "$NATIVE_SERVICE" 2>/dev/null || echo inactive)"
  else
    printf '• Service mode: не найден\n'
  fi
  if docker_mode_configured || docker_container_exists; then
    local ds="stopped"
    docker_container_running && ds="active"
    printf '• Docker mode: установлен\n'
    printf '  └─ состояние: %s\n' "$ds"
  else
    printf '• Docker mode: не найден\n'
  fi
  if panel_installed; then
    printf '• Panel: установлена\n'
    printf '  └─ состояние: %s\n' "$(systemctl is-active "$PANEL_SERVICE" 2>/dev/null || echo inactive)"
  else
    printf '• Panel: не найдена\n'
  fi
  if service_active; then active_cfg="$NATIVE_CONFIG"; mode="service"; fi
  if docker_container_running; then active_cfg="$DOCKER_CONFIG"; mode="docker"; fi
  if [ -n "$active_cfg" ] && [ -f "$active_cfg" ]; then
    ip="$(get_ext_ip)"; domain="$(read_tls_domain "$active_cfg")"; secret="$(read_secret "$active_cfg")"
    printf '\n📄 Активный конфиг: %s\n' "$active_cfg"
    printf '🌍 Домен маскировки: %s\n' "$domain"
    [ -n "$ip" ] && telegram_links "$ip" "$domain" "$secret"
    panel_installed && printf '🌐 ПАНЕЛЬ: http://%s:8080\n' "$ip"
  elif [ "$mode" = "" ]; then
    printf '\nНет активного режима Telemt\n'
  fi
}

delete_menu(){
  local choice
  choice="$(menu_choice 'Удаление Telemt / панели' '1' 'Удалить только службу' 'Удалить только Docker' 'Удалить только панель' 'Удалить всё')"
  case "$choice" in
    1)
      stop_service_mode || true
      rm -rf "$NATIVE_DIR" "$NATIVE_BINARY"
      rm -f "/etc/systemd/system/${NATIVE_SERVICE}.service"
      systemctl daemon-reload >/dev/null 2>&1 || true
      ok "Служба удалена"
      ;;
    2)
      stop_docker_mode || true
      rm -rf "$WORK_DIR"
      ok "Docker режим удалён"
      ;;
    3) remove_panel ;;
    4)
      stop_service_mode || true
      stop_docker_mode || true
      remove_panel || true
      rm -rf "$NATIVE_DIR" "$NATIVE_BINARY" "$WORK_DIR"
      rm -f "/etc/systemd/system/${NATIVE_SERVICE}.service"
      systemctl daemon-reload >/dev/null 2>&1 || true
      ok "Всё, что связано с Telemt, удалено"
      ;;
  esac
}

auto_cleanup(){
  rm -rf "$BUILD_DIR" >/dev/null 2>&1 || true
  if docker_installed && docker_daemon_ok; then
    docker builder prune -f >/dev/null 2>&1 || true
    docker image prune -f >/dev/null 2>&1 || true
  fi
}

main_menu(){
  while true; do
    printf '\n═════════════════════════════════════════════════════\n' >"$TTY_INPUT"
    printf ' 🛠️  Telemt Manager\n' >"$TTY_INPUT"
    printf '═════════════════════════════════════════════════════\n' >"$TTY_INPUT"
    printf '1) Новая установка\n' >"$TTY_INPUT"
    printf '2) Установить / обновить / починить панель\n' >"$TTY_INPUT"
    printf '3) Обновить существующий Telemt\n' >"$TTY_INPUT"
    printf '4) Миграция service → Docker\n' >"$TTY_INPUT"
    printf '5) Миграция Docker → service\n' >"$TTY_INPUT"
    printf '6) Показать статус и ссылки\n' >"$TTY_INPUT"
    printf '7) Удаление Telemt / панели\n' >"$TTY_INPUT"
    printf '8) Очистить мусор (ключи/ссылки не удаляются)\n' >"$TTY_INPUT"
    printf '0) Выход\n' >"$TTY_INPUT"
    case "$(ask 'Выберите пункт' '6')" in
      1) new_install; auto_cleanup; pause ;;
      2) install_or_update_panel; pause ;;
      3) update_existing; auto_cleanup; pause ;;
      4) migrate_service_to_docker; auto_cleanup; pause ;;
      5) migrate_docker_to_service; auto_cleanup; pause ;;
      6) status_and_links; pause ;;
      7) delete_menu; pause ;;
      8) auto_cleanup; ok 'Мусор очищен'; pause ;;
      0) exit 0 ;;
      *) warn 'Неверный выбор'; pause ;;
    esac
  done
}

need_root
install_base_deps
main_menu
