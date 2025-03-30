#!/bin/sh

set -e  

install_dependencies() {
    kernel="$(uname -s)"
    if [ "$kernel" = "Linux" ]; then
        . /etc/os-release

        update_cmd=""
        install_cmd=""
        if [ -n "$ID" ]; then
            case "$ID" in
                arch) update_cmd="$SUDO pacman -Syu --noconfirm"; install_cmd="$SUDO pacman -S --noconfirm git" ;;
                debian|ubuntu|mint) update_cmd="$SUDO DEBIAN_FRONTEND=noninteractive apt update -y"; install_cmd="$SUDO DEBIAN_FRONTEND=noninteractive apt install -y git" ;;
                fedora) update_cmd="$SUDO dnf check-update -y"; install_cmd="$SUDO dnf install -y git" ;;
                void) update_cmd="$SUDO xbps-install -S"; install_cmd="$SUDO xbps-install -y git" ;;
                gentoo) update_cmd="$SUDO emerge --sync --quiet"; install_cmd="$SUDO emerge --ask=n dev-vcs/git" ;;
                opensuse) update_cmd="$SUDO zypper refresh -y"; install_cmd="$SUDO zypper install -y git" ;;
                openwrt) update_cmd="$SUDO opkg update"; install_cmd="$SUDO opkg install -y git bash " ;;
            esac
        fi

        if [ -z "$install_cmd" ] && [ -n "$ID_LIKE" ]; then
            for like in $ID_LIKE; do
                case "$like" in
                    debian) update_cmd="$SUDO DEBIAN_FRONTEND=noninteractive apt update -y"; install_cmd="$SUDO DEBIAN_FRONTEND=noninteractive apt install -y git"; break ;;
                    arch) update_cmd="$SUDO pacman -Syu --noconfirm"; install_cmd="$SUDO pacman -S --noconfirm git"; break ;;
                    fedora) update_cmd="$SUDO dnf check-update -y"; install_cmd="$SUDO dnf install -y git"; break ;;
                    void) update_cmd="$SUDO xbps-install -S"; install_cmd="$SUDO xbps-install -y git"; break ;;
                    gentoo) update_cmd="$SUDO emerge --sync --quiet"; install_cmd="$SUDO emerge --ask=n dev-vcs/git"; break ;;
                    opensuse) update_cmd="$SUDO zypper refresh -y"; install_cmd="$SUDO zypper install -y git"; break ;;
                    openwrt) update_cmd="$SUDO opkg update"; install_cmd="$SUDO opkg install git git-http bash" ; break ;;
                esac
            done
        fi

        if [ -n "$install_cmd" ]; then
            eval "$update_cmd"
            eval "$install_cmd"
        else
            echo "Неизвестная ОС: ${ID} ${ID_LIKE}"; exit 1
        fi
    elif [ "$kernel" = "Darwin" ]; then
        echo "macOS не поддерживается на данный момент." 
        exit 1
    else
        echo "Неизвестная ОС: ${kernel}"
        exit 1
    fi
}

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

