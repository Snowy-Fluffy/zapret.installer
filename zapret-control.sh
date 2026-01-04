#!/bin/bash

source "/opt/zapret.installer/files/utils.sh"
source "/opt/zapret.installer/files/config.sh"
source "/opt/zapret.installer/files/init.sh"
source "/opt/zapret.installer/files/menu.sh"
source "/opt/zapret.installer/files/service.sh"
source "/opt/zapret.installer/files/install.sh"
source "/opt/zapret.installer/files/strategy.sh"

set -e  

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

if [[ $EUID -ne 0 ]]; then
    exec $SUDO "$0" "$@"
fi
trap fast_exit SIGINT
check_openwrt
check_tput
$TPUT_B
check_fs
detect_init
remote_latest_version
main_menu
