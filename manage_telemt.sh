#!/bin/bash

# Telemt Proxy + Panel — Управление
# Исправленная версия:
# - интерактивный ввод всегда читается из /dev/tty
# - исправлены проверки панели
# - исправлена запись конфигов в /etc
# - немного повышена устойчивость

WORK_DIR="$HOME/telemt-proxy"
NATIVE_CONFIG="/etc/telemt/config.toml"
NATIVE_BINARY="/usr/bin/telemt"
NATIVE_SERVICE="telemt"

TTY_INPUT="/dev/tty"
[ -r "$TTY_INPUT" ] || TTY_INPUT="/dev/stdin"

ask() {
    local prompt="$1"
    local answer
    IFS= read -r -p "$prompt" answer <"$TTY_INPUT"
    printf '%s' "$answer"
}

cfg_cat() {
    local cfg="$1"
    if [ -r "$cfg" ]; then
        cat "$cfg"
    else
        sudo cat "$cfg" 2>/dev/null
    fi
}

install_deps() {
    local pkgs=""

    command -v git >/dev/null 2>&1 || pkgs="$pkgs git"
    command -v curl >/dev/null 2>&1 || pkgs="$pkgs curl"
    command -v openssl >/dev/null 2>&1 || pkgs="$pkgs openssl"
    command -v hexdump >/dev/null 2>&1 || pkgs="$pkgs bsdextrautils"

    if [ -n "$pkgs" ]; then
        echo "📦 Устанавливаем:$pkgs"
        sudo apt-get update -qq && sudo apt-get install -yqq $pkgs
    fi

    if ! command -v docker >/dev/null 2>&1; then
        curl -fsSL https://get.docker.com | sudo sh
    fi

    if sudo docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE="sudo docker compose"
    else
        DOCKER_COMPOSE="sudo docker-compose"
    fi
}

is_docker_running() {
    sudo docker ps --filter "name=telemt_proxy" --filter "status=running" -q | grep -q .
}

is_native_running() {
    systemctl is-active --quiet "$NATIVE_SERVICE" 2>/dev/null
}

is_panel_installed() {
    [ -f "/etc/telemt-panel/config.toml" ]
}

print_link() {
    local cfg="$1"
    [ -f "$cfg" ] || { echo "❌ Конфиг не найден: $cfg"; return 1; }

    local domain secret hex ip
    domain=$(cfg_cat "$cfg" | awk -F'"' '/^tls_domain[[:space:]]*=/{print $2; exit}')
    secret=$(cfg_cat "$cfg" | awk -F'"' '/^(main_user|hello)[[:space:]]*=/{print $2; exit}')

    if [ -z "$domain" ] || [ -z "$secret" ]; then
        echo "❌ Не удалось прочитать tls_domain/main_user из $cfg"
        return 1
    fi

    hex=$(echo -n "$domain" | hexdump -v -e '/1 "%02x"')
    ip=$(curl -fsS --max-time 10 -4 ifconfig.me 2>/dev/null)

    if [ -z "$ip" ]; then
        echo "⚠️ Не удалось определить внешний IP"
        echo "═════════════════════════════════════════════════════"
        echo "🌐 ПАНЕЛЬ:   http://<ВАШ_IP>:8080"
        echo "🔐 Домен:    $domain"
        echo "═════════════════════════════════════════════════════"
        return 0
    fi

    echo "═════════════════════════════════════════════════════"
    echo "🔗 TELEGRAM: tg://proxy?server=$ip&port=443&secret=ee${secret}${hex}"
    echo "🌐 ПАНЕЛЬ:   http://$ip:8080"
    echo "═════════════════════════════════════════════════════"
}

auto_cleanup() {
    echo "🧹 Авто-очистка..."
    rm -rf "$WORK_DIR/build_telemt" 2>/dev/null || true
    sudo docker builder prune -f 2>/dev/null || true
    sudo docker image prune -f 2>/dev/null || true
}

choose_branch() {
    local ch
    echo
    echo "Какую версию установить?" >&2
    echo "  1) LTS       — стабильная, рекомендованная" >&2
    echo "  2) Последнюю — самая свежая (может быть нестабильной)" >&2
    ch=$(ask "Выберите (1 или 2): ")

    if [ "$ch" = "1" ]; then
        echo "✅ Выбрана: LTS (стабильная)" >&2
        echo "LTS"
    else
        echo "✅ Выбрана: Последняя (latest)" >&2
        echo "latest"
    fi
}

choose_build_method() {
    local bm
    echo
    echo "Как получить образ Telemt в Docker?" >&2
    echo "  1) Собрать локально из исходников (docker build)" >&2
    echo "  2) Скачать готовый образ (docker pull)" >&2
    bm=$(ask "Выберите (1 или 2): ")

    if [ "$bm" = "1" ]; then
        echo "✅ Выбрано: Сборка локально" >&2
        echo "build"
    else
        echo "✅ Выбрано: Скачивание готового образа" >&2
        echo "pull"
    fi
}

clone_checkout_telemt() {
    local branch="$1"
    rm -rf build_telemt
    git clone https://github.com/telemt/telemt.git build_telemt
    cd build_telemt || exit 1

    local tag=""
    if [ "$branch" = "LTS" ]; then
        tag=$(git tag --sort=-v:refname | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
    else
        tag=$(git tag --sort=-v:refname | head -n1)
    fi

    if [ -n "$tag" ]; then
        git checkout "$tag"
    else
        git checkout main
    fi
}

install_deps

clear
echo "═════════════════════════════════════════════════════"
echo " 🛠️ Telemt Proxy + Panel — Управление"
echo "═════════════════════════════════════════════════════"
echo "У вас уже установлен Telemt?"
echo "  1) Да"
echo "  2) Нет"
echo "  3) Удалить ВСЁ полностью"
echo "  4) Очистить мусор (безопасно)"

main_choice=$(ask "Выберите (1-4): ")

case "$main_choice" in
1)
    if is_docker_running; then
        echo "Обнаружен Docker-режим"
        echo "1) Пересобрать"
        echo "2) Pull"
        echo "3) Панель / обновить"
        echo "4) Ссылка"
        echo "5) Удалить Docker"
        echo "6) Миграция в службу"

        act=$(ask "Выберите (1-6): ")

        mkdir -p "$WORK_DIR"
        cd "$WORK_DIR" || exit 1

        case "$act" in
        1)
            branch=$(choose_branch)
            clone_checkout_telemt "$branch"
            sudo docker build -t ghcr.io/telemt/telemt:latest .
            cd "$WORK_DIR" || exit 1
            $DOCKER_COMPOSE down && $DOCKER_COMPOSE up -d
            auto_cleanup
            print_link "$WORK_DIR/config.toml"
            ;;
        2)
            sudo docker pull ghcr.io/telemt/telemt:latest
            $DOCKER_COMPOSE down && $DOCKER_COMPOSE up -d
            auto_cleanup
            print_link "$WORK_DIR/config.toml"
            ;;
        3)
            if is_panel_installed; then
                echo "Обновляем панель..."
            else
                echo "Устанавливаем панель..."
            fi
            curl -fsSL https://raw.githubusercontent.com/amirotin/telemt_panel/main/install.sh | bash
            print_link "$WORK_DIR/config.toml"
            ;;
        4)
            print_link "$WORK_DIR/config.toml"
            ;;
        5)
            $DOCKER_COMPOSE down
            sudo docker rmi ghcr.io/telemt/telemt:latest 2>/dev/null || true
            rm -f "$WORK_DIR/docker-compose.yml" "$WORK_DIR/config.toml"
            echo "Docker-версия удалена"
            ;;
        6)
            branch=$(choose_branch)
            echo "Миграция Docker → Служба..."

            $DOCKER_COMPOSE down
            sudo docker rmi ghcr.io/telemt/telemt:latest 2>/dev/null || true

            sudo mkdir -p /etc/telemt
            sudo cp "$WORK_DIR/config.toml" "$NATIVE_CONFIG"
            sudo chmod 600 "$NATIVE_CONFIG"

            if ! command -v cargo >/dev/null 2>&1; then
                curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
                . "$HOME/.cargo/env"
            else
                [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
            fi

            clone_checkout_telemt "$branch"
            cargo build --release
            sudo cp target/release/telemt "$NATIVE_BINARY"
            sudo chmod +x "$NATIVE_BINARY"

            cd "$WORK_DIR" || exit 1
            rm -rf build_telemt

            sudo tee "/etc/systemd/system/$NATIVE_SERVICE.service" >/dev/null <<SERV
[Unit]
Description=Telemt Proxy
After=network.target

[Service]
Type=simple
User=root
ExecStart=$NATIVE_BINARY $NATIVE_CONFIG
Restart=on-failure
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
SERV

            sudo systemctl daemon-reload
            sudo systemctl enable --now "$NATIVE_SERVICE"

            if ! is_panel_installed; then
                curl -fsSL https://raw.githubusercontent.com/amirotin/telemt_panel/main/install.sh | bash
            fi

            auto_cleanup
            print_link "$NATIVE_CONFIG"
            ;;
        *)
            echo "Неверный выбор"
            ;;
        esac

    elif is_native_running; then
        echo "Обнаружен Native-режим (служба)"
        echo
        echo "  1) Установить / обновить панель"
        echo "  2) Удалить службу"
        echo "  3) Показать ссылку"
        echo "  4) Миграция обратно в Docker"

        native_act=$(ask "Выберите (1-4): ")

        case "$native_act" in
        1)
            if is_panel_installed; then
                echo "Обновляем панель..."
            else
                echo "Устанавливаем панель..."
            fi
            curl -fsSL https://raw.githubusercontent.com/amirotin/telemt_panel/main/install.sh | bash
            print_link "$NATIVE_CONFIG"
            ;;
        2)
            sudo systemctl stop "$NATIVE_SERVICE" 2>/dev/null || true
            sudo systemctl disable "$NATIVE_SERVICE" 2>/dev/null || true
            sudo rm -f "/etc/systemd/system/$NATIVE_SERVICE.service"
            sudo systemctl daemon-reload
            echo "Служба удалена"
            ;;
        3)
            print_link "$NATIVE_CONFIG"
            ;;
        4)
            branch=$(choose_branch)
            method=$(choose_build_method)

            echo "Миграция Native → Docker..."
            sudo systemctl stop "$NATIVE_SERVICE" 2>/dev/null || true
            sudo systemctl disable "$NATIVE_SERVICE" 2>/dev/null || true
            sudo rm -f "/etc/systemd/system/$NATIVE_SERVICE.service"
            sudo systemctl daemon-reload

            mkdir -p "$WORK_DIR"
            sudo cp "$NATIVE_CONFIG" "$WORK_DIR/config.toml"
            sudo chmod 644 "$WORK_DIR/config.toml"

            cat > "$WORK_DIR/docker-compose.yml" <<'DC'
version: '3.8'
services:
  telemt:
    image: ghcr.io/telemt/telemt:latest
    container_name: telemt_proxy
    restart: unless-stopped
    ports:
      - "443:443"
      - "127.0.0.1:9091:9091"
    volumes:
      - ./config.toml:/app/config.toml:ro
DC

            if [ "$method" = "build" ]; then
                cd "$WORK_DIR" || exit 1
                clone_checkout_telemt "$branch"
                sudo docker build -t ghcr.io/telemt/telemt:latest .
                cd "$WORK_DIR" || exit 1
                rm -rf build_telemt
            else
                sudo docker pull ghcr.io/telemt/telemt:latest
            fi

            cd "$WORK_DIR" || exit 1
            $DOCKER_COMPOSE up -d
            auto_cleanup
            print_link "$WORK_DIR/config.toml"

            echo
            echo "⚠️ ВАЖНОЕ ПРЕДУПРЕЖДЕНИЕ"
            echo "После перехода на Docker обновление Telemt через веб-панель НЕ БУДЕТ РАБОТАТЬ,"
            echo "потому что панель умеет обновлять только нативную версию (службу)."
            echo
            echo "Обновляйте Telemt только через этот скрипт (пункты 1 и 2 в Docker-режиме)."
            ;;
        *)
            echo "Неверный выбор"
            ;;
        esac
    else
        echo "❌ Telemt не запущен"
    fi
    ;;

2)
    echo "Новая установка"
    echo "Выберите тип:"
    echo "1) Служба + панель"
    echo "2) Только служба"
    echo "3) Docker (сборка) + панель"
    echo "4) Docker (pull) + панель"
    echo "5) Docker (сборка) без панели"
    echo "6) Docker (pull) без панели"

    install_type=$(ask "Выберите (1-6): ")
    branch=$(choose_branch)

    DOMAIN=$(ask "Домен маскировки (по умолчанию google.com): ")
    [ -z "$DOMAIN" ] && DOMAIN="google.com"
    SECRET=$(openssl rand -hex 16)

    case "$install_type" in
    1|2)
        if ! command -v cargo >/dev/null 2>&1; then
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
            . "$HOME/.cargo/env"
        else
            [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
        fi

        clone_checkout_telemt "$branch"
        cargo build --release
        sudo cp target/release/telemt "$NATIVE_BINARY"
        sudo chmod +x "$NATIVE_BINARY"
        cd .. || exit 1
        rm -rf build_telemt

        sudo mkdir -p /etc/telemt
        sudo tee "$NATIVE_CONFIG" >/dev/null <<CONF
tls_domain = "$DOMAIN"
main_user = "$SECRET"
CONF
        sudo chmod 600 "$NATIVE_CONFIG"

        sudo tee "/etc/systemd/system/$NATIVE_SERVICE.service" >/dev/null <<SERV
[Unit]
Description=Telemt Proxy
After=network.target

[Service]
Type=simple
User=root
ExecStart=$NATIVE_BINARY $NATIVE_CONFIG
Restart=on-failure
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
SERV

        sudo systemctl daemon-reload
        sudo systemctl enable --now "$NATIVE_SERVICE"

        if [ "$install_type" = "1" ]; then
            curl -fsSL https://raw.githubusercontent.com/amirotin/telemt_panel/main/install.sh | bash
        fi

        print_link "$NATIVE_CONFIG"
        ;;
    3|4|5|6)
        mkdir -p "$WORK_DIR"
        cd "$WORK_DIR" || exit 1

        cat > config.toml <<CONF
tls_domain = "$DOMAIN"
main_user = "$SECRET"
CONF

        if [ "$install_type" = "3" ] || [ "$install_type" = "5" ]; then
            clone_checkout_telemt "$branch"
            sudo docker build -t ghcr.io/telemt/telemt:latest .
            cd "$WORK_DIR" || exit 1
            rm -rf build_telemt
        else
            sudo docker pull ghcr.io/telemt/telemt:latest
        fi

        cat > docker-compose.yml <<'DC'
version: '3.8'
services:
  telemt:
    image: ghcr.io/telemt/telemt:latest
    container_name: telemt_proxy
    restart: unless-stopped
    ports:
      - "443:443"
      - "127.0.0.1:9091:9091"
    volumes:
      - ./config.toml:/app/config.toml:ro
DC

        $DOCKER_COMPOSE up -d
        auto_cleanup

        if [ "$install_type" = "3" ] || [ "$install_type" = "4" ]; then
            curl -fsSL https://raw.githubusercontent.com/amirotin/telemt_panel/main/install.sh | bash
        fi

        print_link "$WORK_DIR/config.toml"
        ;;
    *)
        echo "Неверный выбор"
        ;;
    esac
    ;;

3)
    echo "🗑️ ПОЛНОЕ УДАЛЕНИЕ ВСЕГО"
    confirm=$(ask "Подтвердите удаление всего (да/нет): ")

    if [[ "$confirm" =~ ^([дД]|[dD]|[yY]) ]]; then
        $DOCKER_COMPOSE down 2>/dev/null || true
        sudo docker rmi ghcr.io/telemt/telemt:latest 2>/dev/null || true
        sudo systemctl stop "$NATIVE_SERVICE" 2>/dev/null || true
        sudo systemctl disable "$NATIVE_SERVICE" 2>/dev/null || true
        sudo rm -rf /etc/telemt /etc/telemt-panel "$WORK_DIR" "$NATIVE_BINARY" "/etc/systemd/system/$NATIVE_SERVICE.service"
        sudo systemctl daemon-reload
        echo "✅ Всё удалено"
    else
        echo "Удаление отменено"
    fi
    ;;

4)
    echo "🧹 Безопасная очистка мусора (ключи остаются)"
    rm -rf "$WORK_DIR/build_telemt" 2>/dev/null || true
    sudo docker builder prune -f 2>/dev/null || true
    sudo docker image prune -f 2>/dev/null || true
    echo "✅ Очистка завершена"
    ;;

*)
    echo "Неверный выбор"
    ;;
esac

echo "Готово!"
