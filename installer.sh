#!/bin/sh

set -e  

install_dependencies() {
    kernel="$(uname -s)"

    if [ "$kernel" = "Linux" ]; then
        [ -f /etc/os-release ] && . /etc/os-release || { echo "Не удалось определить ОС"; exit 1; }

        SUDO="${SUDO:-}"

        find_package_manager() {
            case "$1" in
                arch|artix|cachyos|endeavouros|manjaro|garuda) echo "$SUDO pacman -Syu --noconfirm && $SUDO pacman -S --noconfirm --needed git" ;;
                debian|ubuntu|mint) echo "$SUDO apt update -y && $SUDO apt install -y git" ;;
                fedora|almalinux|rocky|rhel|centos|oracle|redos) echo "if command -v dnf >/dev/null 2>&1; then $SUDO dnf update -y && $SUDO dnf install -y git; else $SUDO yum makecache -y && $SUDO yum install -y git; fi" ;;
                void)      echo "$SUDO xbps-install -S && $SUDO xbps-install -y git" ;;
                gentoo)    echo "$SUDO emerge --sync --quiet && $SUDO emerge --ask=n dev-vcs/git app-shells/bash" ;;
                opensuse)  echo "$SUDO zypper refresh && $SUDO zypper install git" ;;
                openwrt)   echo "$SUDO opkg update && $SUDO opkg install git git-http bash" ;;
                altlinux)  echo "$SUDO apt-get update -y && $SUDO apt-get install -y git bash" ;;
                alpine)    echo "$SUDO apk update && $SUDO apk add git bash" ;;
                *)         echo "" ;;
            esac
        }

        install_cmd="$(find_package_manager "$ID")"
        if [ -z "$install_cmd" ] && [ -n "$ID_LIKE" ]; then
            for like in $ID_LIKE; do
                install_cmd="$(find_package_manager "$like")" && [ -n "$install_cmd" ] && break
            done
        fi

        if [ -n "$install_cmd" ]; then
            eval "$install_cmd"
        else
            echo "Неизвестная ОС: ${ID:-Неизвестно}"
            echo "Установите git и bash самостоятельно."
            sleep 2
        fi
    elif [ "$kernel" = "Darwin" ]; then
        echo "macOS не поддерживается на данный момент."
        exit 1
    else
        echo "Неизвестная ОС: $kernel"
        echo "Установите git и bash самостоятельно."
        sleep 2
    fi
}

if [ "$(awk '$2 == "/" {print $4}' /proc/mounts)" = "ro" ]; then
    echo "Файловая система только для чтения, не могу продолжать."
    exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    if command -v sudo > /dev/null 2>&1; then
        SUDO="sudo"
    elif command -v doas > /dev/null 2>&1; then
        SUDO="doas"
    else
        echo "Скрипт не может быть выполнен не от имени суперпользователя."
        exit 1
    fi
fi

if ! command -v git > /dev/null 2>&1; then
    install_dependencies
fi

if [ ! -d "/opt/zapret.installer" ]; then
    $SUDO git clone https://github.com/Snowy-Fluffy/zapret.installer.git /opt/zapret.installer
else
    cd /opt/zapret.installer || exit
    if ! $SUDO git pull; then
        echo "Ошибка при обновлении. Удаляю репозиторий и клонирую заново..."
        $SUDO rm -rf /opt/zapret.installer
        $SUDO git clone https://github.com/Snowy-Fluffy/zapret.installer.git /opt/zapret.installer
    fi
fi

$SUDO chmod +x /opt/zapret.installer/zapret-control.sh
exec bash /opt/zapret.installer/zapret-control.sh

