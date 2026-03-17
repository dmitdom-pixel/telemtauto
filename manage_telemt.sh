#!/bin/bash

# Telemt Proxy + Panel — Управление
# Выбор ветки LTS/latest с чётким отображением выбора

WORK_DIR="$HOME/telemt-proxy"
NATIVE_CONFIG="/etc/telemt/config.toml"
NATIVE_BINARY="/usr/bin/telemt"
NATIVE_SERVICE="telemt"

install_deps() {
    local pkgs=""
    command -v git >/dev/null 2>&1 || pkgs="$pkgs git"
    command -v curl >/dev/null 2>&1 || pkgs="$pkgs curl"
    command -v openssl >/dev/null 2>&1 || pkgs="$pkgs openssl"
    command -v hexdump >/dev/null 2>&1 || pkgs="$pkgs bsdmainutils"

    [ -n "$pkgs" ] && {
        echo "📦 Устанавливаем: $pkgs"
        sudo apt-get update -qq && sudo apt-get install -yqq $pkgs
    }

    command -v docker >/dev/null || { curl -fsSL https://get.docker.com | sudo sh; }

    if sudo docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE="sudo docker compose"
    else
        DOCKER_COMPOSE="sudo docker-compose"
    fi
}

is_docker_running() {
    sudo docker ps --filter "name=telemt_proxy" --filter status=running -q | grep -q .
}

is_native_running() {
    [ -f "/etc/systemd/system/$NATIVE_SERVICE.service" ] && systemctl is-active --quiet "$NATIVE_SERVICE" 2>/dev/null
}

is_panel_installed() {
    [ -f "/etc/telemt-panel/config.toml" ]
}

print_link() {
    local cfg="$1"
    [ ! -f "$cfg" ] && { echo "❌ Конфиг не найден"; return 1; }
    local domain secret hex ip
    domain=$(grep '^tls_domain' "$cfg" | cut -d'"' -f2)
    secret=$(grep -E '^(main_user|hello)' "$cfg" | cut -d'"' -f2 | head -n1)
    [ -z "$domain" ] || [ -z "$secret" ] && return 1
    hex=$(echo -n "$domain" | hexdump -v -e '/1 "%02x"')
    ip=$(curl -s -4 ifconfig.me)
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
    echo >&2
    echo "Какую версию установить?" >&2
    echo "  1) LTS      — стабильная, рекомендованная" >&2
    echo "  2) Последнюю — самая свежая (может быть нестабильной)" >&2
    read -r -p "Выберите (1 или 2): " ch <&2 || read -r -p "Выберите (1 или 2): " ch
    if [ "$ch" = "1" ]; then
        echo "✅ Выбрана: LTS (стабильная)" >&2
        echo "LTS"
    else
        echo "✅ Выбрана: Последняя (latest)" >&2
        echo "latest"
    fi
}

choose_build_method() {
    echo >&2
    echo "Как получить образ Telemt в Docker?" >&2
    echo "  1) Собрать локально из исходников (docker build)" >&2
    echo "  2) Скачать готовый образ (docker pull)" >&2
    read -r -p "Выберите (1 или 2): " bm <&2 || read -r -p "Выберите (1 или 2): " bm
    if [ "$bm" = "1" ]; then
        echo "✅ Выбрано: Сборка локально" >&2
        echo "build"
    else
        echo "✅ Выбрано: Скачивание готового образа" >&2
        echo "pull"
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
read -r -p "Выберите (1-4): " main_choice

case $main_choice in
1)
    if is_docker_running; then
        echo "Обнаружен Docker-режим"
        echo "1) Пересобрать   2) Pull   3) Панель/обновить   4) Ссылка   5) Удалить Docker   6) Миграция в службу"
        read -r -p "Выберите (1-6): " act
        cd "$WORK_DIR" 2>/dev/null || mkdir -p "$WORK_DIR" && cd "$WORK_DIR"

        case $act in
        1)
            branch=$(choose_branch)
            rm -rf build_telemt
            git clone https://github.com/telemt/telemt.git build_telemt
            cd build_telemt || exit 1
            if [ "$branch" = "LTS" ]; then
                tag=$(git tag --sort=-v:refname | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
            else
                tag=$(git tag --sort=-v:refname | head -n1)
            fi
            [ -n "$tag" ] && git checkout "$tag" || git checkout main
            sudo docker build -t ghcr.io/telemt/telemt:latest .
            cd "$WORK_DIR"
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
        4) print_link "$WORK_DIR/config.toml" ;;
        5)
            $DOCKER_COMPOSE down
            sudo docker rmi ghcr.io/telemt/telemt:latest 2>/dev/null || true
            rm -f docker-compose.yml config.toml
            echo "Docker-версия удалена"
            ;;
        6)
            branch=$(choose_branch)
            echo "Миграция Docker → Служба..."
            $DOCKER_COMPOSE down
            sudo docker rmi ghcr.io/telemt/telemt:latest 2>/dev/null || true
            sudo mkdir -p /etc/telemt
            sudo cp config.toml "$NATIVE_CONFIG"
            sudo chmod 600 "$NATIVE_CONFIG"
            if ! command -v cargo >/dev/null 2>&1; then
                curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
                . "$HOME/.cargo/env"
            fi
            rm -rf build_telemt
            git clone https://github.com/telemt/telemt.git build_telemt
            cd build_telemt || exit 1
            if [ "$branch" = "LTS" ]; then
                tag=$(git tag --sort=-v:refname | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
            else
                tag=$(git tag --sort=-v:refname | head -n1)
            fi
            [ -n "$tag" ] && git checkout "$tag" || git checkout main
            cargo build --release
            sudo cp target/release/telemt "$NATIVE_BINARY"
            sudo chmod +x "$NATIVE_BINARY"
            cd "$WORK_DIR"
            rm -rf build_telemt

            sudo tee /etc/systemd/system/$NATIVE_SERVICE.service >/dev/null <<SERV
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
            [ ! is_panel_installed ] && curl -fsSL https://raw.githubusercontent.com/amirotin/telemt_panel/main/install.sh | bash
            auto_cleanup
            print_link "$NATIVE_CONFIG"
            ;;
        esac
    elif is_native_running; then
        echo "Обнаружен Native-режим (служба)"
        echo
        echo "  1) Установить / обновить панель"
        echo "  2) Удалить службу"
        echo "  3) Показать ссылку"
        echo "  4) Миграция обратно в Docker"
        read -r -p "Выберите (1-4): " native_act

        case $native_act in
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
            sudo systemctl stop "$NATIVE_SERVICE" 2>/dev/null
            sudo systemctl disable "$NATIVE_SERVICE" 2>/dev/null
            sudo rm -f "/etc/systemd/system/$NATIVE_SERVICE.service"
            echo "Служба удалена"
            ;;
        3) print_link "$NATIVE_CONFIG" ;;
        4)
            branch=$(choose_branch)
            method=$(choose_build_method)

            echo "Миграция Native → Docker..."
            sudo systemctl stop "$NATIVE_SERVICE" 2>/dev/null
            sudo systemctl disable "$NATIVE_SERVICE" 2>/dev/null
            sudo rm -f "/etc/systemd/system/$NATIVE_SERVICE.service"

            mkdir -p "$WORK_DIR"
            sudo cp "$NATIVE_CONFIG" "$WORK_DIR/config.toml"
            sudo chmod 600 "$WORK_DIR/config.toml"

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
                rm -rf build_telemt
                git clone https://github.com/telemt/telemt.git build_telemt
                cd build_telemt || exit 1
                if [ "$branch" = "LTS" ]; then
                    tag=$(git tag --sort=-v:refname | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
                else
                    tag=$(git tag --sort=-v:refname | head -n1)
                fi
                [ -n "$tag" ] && git checkout "$tag" || git checkout main
                sudo docker build -t ghcr.io/telemt/telemt:latest .
                cd "$WORK_DIR"
                rm -rf build_telemt
            else
                sudo docker pull ghcr.io/telemt/telemt:latest
            fi

            cd "$WORK_DIR"
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
    read -r -p "Выберите (1-6): " install_type

    branch=$(choose_branch)

    read -r -p "Домен маскировки (по умолчанию google.com): " DOMAIN
    [ -z "$DOMAIN" ] && DOMAIN="google.com"
    SECRET=$(openssl rand -hex 16)

    case $install_type in
    1|2)
        if ! command -v cargo >/dev/null 2>&1; then
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
            . "$HOME/.cargo/env"
        fi
        rm -rf build_telemt
        git clone https://github.com/telemt/telemt.git build_telemt
        cd build_telemt || exit 1
        if [ "$branch" = "LTS" ]; then
            tag=$(git tag --sort=-v:refname | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
        else
            tag=$(git tag --sort=-v:refname | head -n1)
        fi
        [ -n "$tag" ] && git checkout "$tag" || git checkout main
        cargo build --release
        sudo cp target/release/telemt "$NATIVE_BINARY"
        sudo chmod +x "$NATIVE_BINARY"
        cd ..
        rm -rf build_telemt

        sudo mkdir -p /etc/telemt
        cat > "$NATIVE_CONFIG" <<CONF
tls_domain = "$DOMAIN"
main_user = "$SECRET"
CONF
        sudo chmod 600 "$NATIVE_CONFIG"

        sudo tee /etc/systemd/system/$NATIVE_SERVICE.service >/dev/null <<SERV
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

        [ "$install_type" = "1" ] && curl -fsSL https://raw.githubusercontent.com/amirotin/telemt_panel/main/install.sh | bash
        print_link "$NATIVE_CONFIG"
        ;;
    3|4|5|6)
        mkdir -p "$WORK_DIR"
        cd "$WORK_DIR"
        cat > config.toml <<CONF
tls_domain = "$DOMAIN"
main_user = "$SECRET"
CONF

        if [ "$install_type" = "3" ] || [ "$install_type" = "5" ]; then
            rm -rf build_telemt
            git clone https://github.com/telemt/telemt.git build_telemt
            cd build_telemt || exit 1
            if [ "$branch" = "LTS" ]; then
                tag=$(git tag --sort=-v:refname | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
            else
                tag=$(git tag --sort=-v:refname | head -n1)
            fi
            [ -n "$tag" ] && git checkout "$tag" || git checkout main
            sudo docker build -t ghcr.io/telemt/telemt:latest .
            cd ..
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
    esac
    ;;

3)
    echo "🗑️ ПОЛНОЕ УДАЛЕНИЕ ВСЕГО"
    read -r -p "Подтвердите удаление всего (да/нет): " confirm
    [[ "$confirm" =~ ^[дДyY] ]] && {
        $DOCKER_COMPOSE down 2>/dev/null || true
        sudo docker rmi ghcr.io/telemt/telemt:latest 2>/dev/null || true
        sudo systemctl stop "$NATIVE_SERVICE" 2>/dev/null
        sudo systemctl disable "$NATIVE_SERVICE" 2>/dev/null
        sudo rm -rf /etc/telemt /etc/telemt-panel "$WORK_DIR" "$NATIVE_BINARY" "/etc/systemd/system/$NATIVE_SERVICE.service"
        echo "✅ Всё удалено"
    }
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
