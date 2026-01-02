#!/bin/bash


remote_latest_version() {
    rver=$(timeout 10s curl -s https://api.github.com/repos/bol-van/zapret/releases/latest | \
          grep "tag_name" | \
          cut -d '"' -f 4 | \
          sed 's/^v//')
}

get_latest_version() {
    if [ -z "$rver" ]; then
        rver=$(timeout 10s curl -s -I https://github.com/bol-van/zapret/releases/latest | grep -i "location:" | cut -d' ' -f2 | tr -d '\r' | grep -o "tag/v[0-9.]\+" | cut -d'/' -f2 | sed 's/^v//')
        if [ -z "$rver" ]; then
            #error_exit "не удалось определить последнюю версию запрета. Проверьте соединение с сетью."
            echo "Неизвестно"
        else
            echo "$rver"
        fi
    else
        echo "$rver"
    fi
}

#zapret_update_check()
#{
#    if cmp -s <(get_latest_version) /opt/zapret-ver; then 
#        echo -e "0"
#    else
#        echo -e "1"
#    fi
#
#}
download_zapret_release()
{

    rm -rf /opt/zapret
    rm -rf /opt/zapret-v$(get_latest_version)
    TEMP_DIR_BIN=$(mktemp -d)
    if [ SYSTEM = openwrt ]; then
        if ! curl -L -o "$TEMP_DIR_BIN/latest.tar.gz" $(curl -s https://api.github.com/repos/bol-van/zapret/releases/latest | grep "browser_download_url.*openwrt.*tar.gz" | head -n 1 | cut -d '"' -f 4); then
            rm -rf $TEMP_DIR_BIN
            error_exit "Не удалось получить релиз запрета."
        fi        
        if ! tar -xzf $TEMP_DIR_BIN/latest.tar.gz -C /opt/ --strip-components=1; then
            rm -rf $TEMP_DIR_BIN /opt/zapret-v$(get_latest_version)
            error_exit "Не удалось разархивировать архив с релизом запрета."
        fi
    else
        curl -s https://api.github.com/repos/bol-van/zapret/releases/latest | grep "browser_download_url.*tar.gz" | grep -v "openwrt" | head -n 1 | cut -d '"' -f 4 | xargs -I {} curl -L -o "$TEMP_DIR_BIN/latest.tar.gz" "{}" || error_exit "не могу получить релиз запрета"
        if ! tar -xzf $TEMP_DIR_BIN/latest.tar.gz -C /opt/; then
            rm -rf $TEMP_DIR_BIN /opt/zapret-v$(get_latest_version)
            error_exit "Не удалось разархивировать архив с релизом запрета."
        fi
    fi
    mv /opt/zapret-v$(get_latest_version) /opt/zapret
    get_latest_version > /opt/zapret-ver
    echo "Клонирую репозиторий конфигураций..."
    git clone https://github.com/Snowy-Fluffy/zapret.cfgs /opt/zapret/zapret.cfgs || error_exit "не удалось получить репозиторий конфигураций. Вероятно это сетевая ошибка, попробуйте снова."
    echo "Клонирование успешно завершено."



}

download_zapret_git() {
    rm -rf /opt/zapret
    rm -rf /opt/zapret-v$(get_latest_version)
    echo "Клонирую репозиторий bol-van/zapret..."
    git clone https://github.com/bol-van/zapret /opt/zapret || error_exit "не удалось получить запрет. Вероятно это сетевая ошибка, попробуйте снова."
    echo "git" > /opt/zapret-ver
    echo "Клонирую репозиторий конфигураций..."
    git clone https://github.com/Snowy-Fluffy/zapret.cfgs /opt/zapret/zapret.cfgs || error_exit "не удалось получить репозиторий конфигураций. Вероятно это сетевая ошибка, попробуйте снова."
    echo "Клонирование успешно завершено."
}


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

install_zapret_release() {
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
    download_zapret_release
    cd /opt/zapret
    sed -i '238s/ask_yes_no N/ask_yes_no Y/' /opt/zapret/common/installer.sh
    yes "" | ./install_easy.sh
    sed -i '238s/ask_yes_no Y/ask_yes_no N/' /opt/zapret/common/installer.sh
    rm -f /bin/zapret
    rm -f /opt/zapret/config
    cp -r /opt/zapret/zapret.cfgs/configurations/general /opt/zapret/config || error_exit "не удалось автоматически скопировать конфиг"
    cp -r /opt/zapret/zapret.cfgs/bin/* /opt/zapret/files/fake || error_exit "не удалось автоматически скопировать fake bin"
    rm -f /opt/zapret/ipset/zapret-hosts-user.txt
    touch /opt/zapret/ipset/ipset-game.txt || error_exit "не удалось автоматически создать game ipset"
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
            $TPUT_E
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
install_zapret_git() {
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
    download_zapret_git
    cd /opt/zapret
    sed -i '238s/ask_yes_no N/ask_yes_no Y/' /opt/zapret/common/installer.sh
    yes "" | ./install_easy.sh
    sed -i '238s/ask_yes_no Y/ask_yes_no N/' /opt/zapret/common/installer.sh
    rm -f /bin/zapret
    rm -f /opt/zapret/config
    cp -r /opt/zapret/zapret.cfgs/configurations/general /opt/zapret/config || error_exit "не удалось автоматически скопировать конфиг"
    cp -r /opt/zapret/zapret.cfgs/bin/* /opt/zapret/files/fake || error_exit "не удалось автоматически скопировать fake bin"
    rm -f /opt/zapret/ipset/zapret-hosts-user.txt
    touch /opt/zapret/ipset/ipset-game.txt || error_exit "не удалось автоматически создать game ipset"
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
            $TPUT_E
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
    LIST_EXISTS=0
    CONF_EXISTS=0
    TEMP_DIR_CONF=$(mktemp -d)
    if [[ -f /opt/zapret/config ]]; then
        cp -r /opt/zapret/config $TEMP_DIR_CONF/config
        CONF_EXISTS=1
    fi
    if [[ -f /opt/zapret/ipset/zapret-hosts-user.txt ]]; then
        cp -r /opt/zapret/ipset/zapret-hosts-user.txt $TEMP_DIR_CONF/zapret-hosts-user.txt
        LIST_EXISTS=1
    fi 
    #if [ $(zapret_update_check) = 0 ]; then
    #    echo "Актуальная версия уже установлена: нечего обновлять." 
    #    bash -c 'read -p "Нажмите Enter для продолжения..."' 
    
    if [ -f /opt/zapret-ver ]; then
        #cat /opt/zapret-ver | tr -d '[:space:]' - useful
        if [ -z $(cat /opt/zapret-ver) ] || [ $(cat /opt/zapret-ver) != "git" ]; then
            download_zapret || error_exit "не удалось обновить запрет"
            echo -e "Запрет обновлен до версии $(cat /opt/zapret-ver)"
            cd /opt/zapret
            sed -i '238s/ask_yes_no N/ask_yes_no Y/' /opt/zapret/common/installer.sh
            yes "" | ./install_easy.sh
            sed -i '238s/ask_yes_no Y/ask_yes_no N/' /opt/zapret/common/installer.sh
        else
            cd /opt/zapret/ && git fetch origin master; git reset --hard origin/master || error_exit "не удалось обновить zapret с помощью git. Попробуйте снова, вероятно это сетевая ошибка. Если не помогло - переустановите zapret."
            echo -e "Репозиторий запрета был обновлен."
        fi
    else
        download_zapret || error_exit "не удалось обновить zapret"
        echo -e "Запрет обновлен до версии $(cat /opt/zapret-ver)"
        cd /opt/zapret
        sed -i '238s/ask_yes_no N/ask_yes_no Y/' /opt/zapret/common/installer.sh
        yes "" | ./install_easy.sh
        sed -i '238s/ask_yes_no Y/ask_yes_no N/' /opt/zapret/common/installer.sh
    fi

    if [[ -d /opt/zapret/zapret.cfgs ]]; then
        cd /opt/zapret/zapret.cfgs && git fetch origin main; git reset --hard origin/main
    fi
    if [[ -d /opt/zapret.installer/ ]]; then
        cd /opt/zapret.installer/ && git fetch origin main; git reset --hard origin/main
        rm -f /bin/zapret
        ln -s /opt/zapret.installer/zapret-control.sh /bin/zapret || error_exit "не удалось создать символическую ссылку"
    fi
    if [ CONF_EXISTS = 1 ]; then
        rm -f /opt/zapret/config
        mv $TEMP_DIR_CONF/config /opt/zapret/config
    fi
    if [ LIST_EXISTS = 1 ]; then 
        rm -f /opt/zapret/ipset/zapret-hosts-user.txt
        mv $TEMP_DIR_CONF/zapret-hosts-user.txt /opt/zapret/ipset/zapret-hosts-user.txt
    fi
    rm -rf $TEMP_DIR_CONF
    rm -rf $TEMP_DIR_BIN
    rm -f /opt/zapret/config
    cp -r /opt/zapret/zapret.cfgs/configurations/general /opt/zapret/config || error_exit "не удалось автоматически скопировать конфиг"
    cp -r /opt/zapret/zapret.cfgs/bin/* /opt/zapret/files/fake || error_exit "не удалось автоматически скопировать fake bin"
    rm -f /opt/zapret/ipset/zapret-hosts-user.txt
    touch /opt/zapret/ipset/ipset-game.txt || error_exit "не удалось автоматически создать game ipset"
    cp -r /opt/zapret/zapret.cfgs/lists/list-basic.txt /opt/zapret/ipset/zapret-hosts-user.txt || error_exit "не удалось автоматически скопировать хостлист"
    cp -r /opt/zapret/zapret.cfgs/lists/ipset-discord.txt /opt/zapret/ipset/ipset-discord.txt || error_exit "не удалось автоматически скопировать discord ipset"
    configure_zapret_conf
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
            rm -f /opt/zapret-ver
            echo "Удаляю zapret..."
            sleep 3
            echo "Запрет удален"
            $TPUT_E
            exit
            ;;
        * )
            main_menu
            ;;
    esac
} 
