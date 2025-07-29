#!/bin/bash



install_dependencies() {
    kernel="$(uname -s)"
    if [ "$kernel" = "Linux" ]; then
        . /etc/os-release
        declare -A command_by_ID=(
            ["arch"]="pacman -S --noconfirm --needed ipset "
            ["artix"]="pacman -S --noconfirm --needed ipset "
            ["cachyos"]="pacman -S --noconfirm --needed ipset "
            ["endeavouros"]="pacman -S --noconfirm --needed ipset "
            ["manjaro"]="pacman -S --noconfirm --needed ipset "
            ["debian"]="apt-get install -y iptables ipset "
            ["fedora"]="dnf install -y iptables ipset"
            ["ubuntu"]="apt-get install -y iptables ipset"
            ["mint"]="apt-get install -y iptables ipset"
            ["centos"]="yum install -y ipset iptables"
            ["void"]="xbps-install -y iptables ipset"
            ["gentoo"]="emerge net-firewall/iptables net-firewall/ipset"
            ["opensuse"]="zypper install -y iptables ipset"
            ["openwrt"]="opkg install iptables ipset"
            ["altlinux"]="apt-get install -y iptables ipset"
            ["almalinux"]="dnf install -y iptables ipset"
            ["rocky"]="dnf install -y iptables ipset"
            ["alpine"]="apk add iptables ipset"
        )
        if [[ -v command_by_ID[$ID] ]]; then
            eval "${command_by_ID[$ID]}"
        else
            for like in $ID_LIKE; do
                if [[ -n "${command_by_ID[$like]}" ]]; then
                    eval "${command_by_ID[$like]}"
                    break
                fi
            done
        fi
    elif [ "$kernel" = "Darwin" ]; then
        error_exit "macOS не поддерживается на данный момент."
    else
        echo "Неизвестная ОС: ${kernel}. Установите iptables и ipset самостоятельно." bash -c 'read -p "Нажмите Enter для продолжения..."'
    fi
}

install_zapret() {
    install_dependencies
    if [[ $dir_exists == true ]]; then
        read -p "На вашем компьютере был найден запрет (/opt/zapret). Для продолжения его необходимо удалить. Вы действительно хотите удалить запрет (/opt/zapret) и продолжить? (y/N): " answer
        case "$answer" in
            [Yy]* )
                if [[ -f /opt/zapret/uninstall_easy.sh ]]; then
                    cd /opt/zapret
                    sed -i '238s/ask_yes_no N/ask_yes_no Y/' /opt/zapret/common/installer.sh
                    yes "" | ./uninstall_easy.sh
                    sed -i '238s/ask_yes_no Y/ask_yes_no N/' /opt/zapret/common/installer.sh
                fi
                rm -rf /opt/zapret
                echo "Удаляю zapret..."
                cd /
                sleep 3
                ;;
            * )
                main_menu
                ;;
        esac
    fi
    if [ SYSTEM = openwrt ]; then
        echo "Получаю релиз запрета..."
        sleep 2
        mkdir -p /tmp/zapret_download
        cd /tmp/zapret_download || error_exit "Не удалось перейти в /tmp/zapret_download"
        if ! curl -L -o https://github.com/bol-van/zapret/releases/download/v71.1.1/zapret-v71.1.1.tar.gz; then
            rm -rf /tmp/zapret_download
            error_exit "Не удалось получить релиз запрета."
        fi
        mkdir -p /opt/zapret
        if ! tar -xzf zapret-v71.1.1.tar.gz -C /opt/zapret --strip-components=1; then
            rm -rf /tmp/zapret_download /opt/zapret
            error_exit "Не удалось разархивировать архив с релизом запрета."
        fi
        git clone https://github.com/Snowy-Fluffy/zapret.cfgs /opt/zapret/zapret.cfgs
        rm -rf /tmp/zapret_download   
    else
        echo "Клонирую репозиторий..."
        sleep 2
        git clone https://github.com/bol-van/zapret /opt/zapret
        echo "Клонирую репозиторий..."
        git clone https://github.com/Snowy-Fluffy/zapret.cfgs /opt/zapret/zapret.cfgs
        echo "Клонирование успешно завершено."
        rm -rf /opt/zapret/binaries
        echo -e "\e[45mКлонирую релиз запрета...\e[0m"
        if [[ ! -d /opt/zapret.installer/zapret.binaries/ ]]; then
            rm -rf /opt/zapret.installer/zapret.binaries/
        fi
        mkdir -p /opt/zapret.installer/zapret.binaries/zapret
        if ! curl -L -o /opt/zapret.installer/zapret.binaries/zapret/zapret-v71.1.1.tar.gz https://github.com/bol-van/zapret/releases/download/v71.1.1/zapret-v71.1.1.tar.gz; then
            rm -rf /opt/zapret /tmp/zapret
            error_exit "не удалось получить релиз запрета."
        fi
        echo "Получение запрета завершено."
        if ! tar -xzf /opt/zapret.installer/zapret.binaries/zapret/zapret-v71.1.1.tar.gz -C /opt/zapret.installer/zapret.binaries/zapret/; then
            rm -rf /opt/zapret.installer/
            error_exit "не удалось разархивировать архив с релизом запрета."
        fi
        cp -r /opt/zapret.installer/zapret.binaries/zapret/zapret-v71.1.1/binaries/ /opt/zapret/binaries
    fi

    cd /opt/zapret
    sed -i '238s/ask_yes_no N/ask_yes_no Y/' /opt/zapret/common/installer.sh
    yes "" | ./install_easy.sh
    sed -i '238s/ask_yes_no Y/ask_yes_no N/' /opt/zapret/common/installer.sh
    rm -f /bin/zapret
    rm -f /opt/zapret/config
    cp -r /opt/zapret/zapret.cfgs/configurations/general /opt/zapret/config || error_exit "не удалось автоматически скопировать конфиг"
    rm -f /opt/zapret/ipset/zapret-hosts-user.txt
    cp -r /opt/zapret/zapret.cfgs/lists/list-basic.txt /opt/zapret/ipset/zapret-hosts-user.txt || error_exit "не удалось автоматически скопировать хостлист"
    cp -r /opt/zapret/zapret.cfgs/lists/ipset-discord.txt /opt/zapret/ipset/ipset-discord.txt || error_exit "не удалось автоматически скопировать ипсет"
    ln -s /opt/zapret.installer/zapret-control.sh /bin/zapret || error_exit "не удалось создать символическую ссылку"
    if [[ INIT_SYSTEM = systemd ]]; then
        systemctl daemon-reload
    fi
    if [[ INIT_SYSTEM = runit ]]; then
        read -p "Для окончания установки необходимо перезапустить ваше устройство. Перезапустить его сейчас? (Y/n): " answer
        case "$answer" in
        [Yy]* )
            reboot
            ;;
        [Nn]* )
            TPUT_E
            exit 1
            ;;
        * )
            reboot
            ;;
    esac
    else
        manage_service restart
        configure_zapret_conf
    fi
}

update_zapret() {
    if [[ -d /opt/zapret ]]; then
        cd /opt/zapret && git fetch origin master; git reset --hard origin/master
    fi
    if [[ -d /opt/zapret/zapret.cfgs ]]; then
        cd /opt/zapret/zapret.cfgs && git fetch origin main; git reset --hard origin/main
    fi
    if [[ -d /opt/zapret.installer/ ]]; then
        cd /opt/zapret.installer/ && git fetch origin main; git reset --hard origin/main
        rm -f /bin/zapret
        ln -s /opt/zapret.installer/zapret-control.sh /bin/zapret || error_exit "не удалось создать символическую ссылку"
    fi
    manage_service restart
    bash -c 'read -p "Нажмите Enter для продолжения..."'
    exec "$0" "$@"
}

update_script() {
    if [[ -d /opt/zapret/zapret.cfgs ]]; then
        cd /opt/zapret/zapret.cfgs && git fetch origin main; git reset --hard origin/main
    fi
    if [[ -d /opt/zapret.installer/ ]]; then
        cd /opt/zapret.installer/ && git fetch origin main; git reset --hard origin/main
    fi
    rm -f /bin/zapret
    ln -s /opt/zapret.installer/zapret-control.sh /bin/zapret || error_exit "не удалось создать символическую ссылку"
    bash -c 'read -p "Нажмите Enter для продолжения..."'
    exec "$0" "$@"
}

update_installed_script() {
    if [[ -d /opt/zapret/zapret.cfgs ]]; then
        cd /opt/zapret/zapret.cfgs && git fetch origin main; git reset --hard origin/main
    fi
    if [[ -d /opt/zapret.installer/ ]]; then
        cd /opt/zapret.installer/ && git fetch origin main; git reset --hard origin/main
        rm -f /bin/zapret
        ln -s /opt/zapret.installer/zapret-control.sh /bin/zapret || error_exit "не удалось создать символическую ссылку"
        manage_service restart
    fi
    bash -c 'read -p "Нажмите Enter для продолжения..."'
    exec "$0" "$@"
}

uninstall_zapret() {
    read -p "Вы действительно хотите удалить запрет? (y/N): " answer
    case "$answer" in
        [Yy]* )
            if [[ -f /opt/zapret/uninstall_easy.sh ]]; then
                cd /opt/zapret
                yes "" | ./uninstall_easy.sh
            fi
            rm -rf /opt/zapret
            rm -rf /opt/zapret.installer/
            rm -r /bin/zapret
            echo "Удаляю zapret..."
            sleep 3
            ;;
        * )
            main_menu
            ;;
    esac
} 
