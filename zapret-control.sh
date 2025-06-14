#!/bin/bash

warnings=()

set -e  

if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

error_exit() {
    $TPUT_E 

    echo -e "\e[31mОшибка:\e[0m $1" >&2 
    exit 1
}
warning() {
    echo -e "\e[43m⚠️Предупреждение: \e[0m $1" >&2
    warnings+=("$1")
}

detect_init() {
    GET_LIST_PREFIX=/ipset/get_

    SYSTEMD_DIR=/lib/systemd
    [ -d "$SYSTEMD_DIR" ] || SYSTEMD_DIR=/usr/lib/systemd
    [ -d "$SYSTEMD_DIR" ] && SYSTEMD_SYSTEM_DIR="$SYSTEMD_DIR/system"

    INIT_SCRIPT=/etc/init.d/zapret
    if [ -d /run/systemd/system ]; then
        INIT_SYSTEM="systemd"
    elif [ $SYSTEM == openwrt ]; then
        INIT_SYSTEM="procd"
    elif command -v openrc-init >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
    elif command -v runit >/dev/null 2>&1; then
        INIT_SYSTEM="runit"
    elif [ -x /sbin/init ] && /sbin/init --version 2>&1 | grep -qi "sysv init"; then
        INIT_SYSTEM="sysvinit" 
    else
        error_exit "Не удалось определить init."
    fi
}

check_zapret_exist() {
    case "$INIT_SYSTEM" in
        systemd)
            if [ -f /etc/systemd/system/timers.target.wants/zapret-list-update.timer ]; then
                service_exists=true
            else
                service_exists=false
            fi
            ;;
        procd)
            if [ -f /etc/init.d/zapret ]; then
                service_exists=true
            else
                service_exists=false
            fi
            ;;
        runit)
            service_exists=true
            ;;
        openrc)
            rc-service -l | grep -q "zapret" && service_exists=true || service_exists=false
            ;;
        sysvinit)
            [ -f /etc/init.d/zapret ] && service_exists=true || service_exists=false
            ;;
        *)
            ZAPRET_EXIST=false
            return
            ;;
    esac


    if [ -d /opt/zapret ]; then
        dir_exists=true
        [ -d /opt/zapret/binaries ] && binaries_exists=true || binaries_exists=false
    else
        dir_exists=false
        binaries_exists=false
    fi


    if [ "$service_exists" = true ] && [ "$dir_exists" = true ] && [ "$binaries_exists" = true ]; then
        ZAPRET_EXIST=true
    else
        ZAPRET_EXIST=false
    fi
}


check_zapret_status() {
    case "$INIT_SYSTEM" in
        systemd)
        ZAPRET_ACTIVE=$(systemctl show -p ActiveState zapret | cut -d= -f2 || true)
        ZAPRET_ENABLED=$(systemctl is-enabled zapret 2>/dev/null || echo "false")
        ZAPRET_SUBSTATE=$(systemctl show -p SubState zapret | cut -d= -f2)
        if [[ "$ZAPRET_ACTIVE" == "active" && "$ZAPRET_SUBSTATE" == "running" ]]; then
           ZAPRET_ACTIVE=true
        else
            ZAPRET_ACTIVE=false
        fi
        
        if [[ "$ZAPRET_ENABLED" == "enabled" ]]; then
            ZAPRET_ENABLED=true
        else
            ZAPRET_ENABLED=false
        fi
        if [[ "$ZAPRET_ENABLED" == "not-found" ]]; then
            ZAPRET_ENABLED=false
        fi
        ;;
        openrc)
            rc-service zapret status >/dev/null 2>&1 && ZAPRET_ACTIVE=true || ZAPRET_ACTIVE=false
            rc-update show | grep -q zapret && ZAPRET_ENABLED=true || ZAPRET_ENABLED=false
            ;;
        procd)
            
            if /etc/init.d/zapret status | grep -q "running"; then
                ZAPRET_ACTIVE=true
            else
                ZAPRET_ACTIVE=false
            fi
            if ls /etc/rc.d/ | grep -q zapret >/dev/null 2>&1; then
                ZAPRET_ENABLED=true
            else
                ZAPRET_ENABLED=false
            fi

            ;;
        runit)
            sv status zapret | grep -q "run" && ZAPRET_ACTIVE=true || ZAPRET_ACTIVE=false 
            ls /var/service | grep -q "zapret" && ZAPRET_ENABLED=true || ZAPRET_ENABLED=false
            ;;
        sysvinit)
            service zapret status >/dev/null 2>&1 && ZAPRET_ACTIVE=true || ZAPRET_ACTIVE=false
            ;;
    esac
}


exists()
{
	which "$1" >/dev/null 2>/dev/null
}
existf()
{
	type "$1" >/dev/null 2>/dev/null
}
whichq()
{
	which $1 2>/dev/null
}

check_openwrt() {
    if grep -q '^ID="openwrt"$' /etc/os-release; then
        SYSTEM=openwrt
    fi
}
check_tput() {
    if command -v tput &>/dev/null; then
        TPUT_B="tput smcup"
        TPUT_E="tput rmcup"
    else
        TPUT_B=""
        TPUT_E=""
    fi
}


is_network_error() {
    local log="$1"
    echo "$log" | grep -qiE "timed out|recv failure|unexpected disconnect|early EOF|RPC failed|curl.*recv"
}

try_again() {
    local error_message="$1"
    shift

    local -a command=("$@") 
    local attempt=0
    local max_attempts=3
    local success=0

    while (( attempt < max_attempts )); do
        ((attempt++))

        (( attempt > 1 )) && echo -e "\e[33mПопытка $attempt из $max_attempts...\e[0m"


        output=$("${command[@]}" 2>&1) && success=1 && break

        if ! is_network_error "$output"; then
            echo "$output" >&2
            error_exit "не удалось склонировать репозиторий."
        fi
        sleep 2
    done

    (( success == 0 )) && error_exit "$error_message"
}



get_fwtype() {
    [ -n "$FWTYPE" ] && return

    local UNAME="$(uname)"

    case "$UNAME" in
        Linux)
            if [[ $SYSTEM == openwrt ]]; then
                if exists iptables; then
                    iptables_version=$(iptables --version 2>&1)

                    if [[ "$iptables_version" == *"legacy"* ]]; then
                        FWTYPE="iptables"
                        return 0
                    elif [[ "$iptables_version" == *"nf_tables"* ]]; then
                        FWTYPE="nftables"
                        return 0
                    else
                        echo -e "\e[1;33m⚠️ Не удалось определить тип файрвола.\e[0m"
                        echo -e "По умолчанию будет использован: \e[1;36mnftables\e[0m"
                        echo -e "\e[2m(Можно изменить в /opt/zapret/config)\e[0m"
                        echo -e "⏳ Продолжаю через 5 секунд..."
                        FWTYPE="nftables"
                        sleep 5
                        return 0 
                    fi
                else
                    echo -e "\e[1;33m⚠️ iptables не найден. Используется по умолчанию: \e[1;36mnftables\e[0m"
                    echo -e "\e[2m(Можно изменить в /opt/zapret/config)\e[0m"
                    echo -e "⏳ Продолжаю через 5 секунд..."
                    FWTYPE="nftables"
                    sleep 5
                    return 0
                fi
            fi

            if exists iptables; then
                iptables_version=$(iptables -V 2>&1)

                if [[ "$iptables_version" == *"legacy"* ]]; then
                    FWTYPE="iptables"
                elif [[ "$iptables_version" == *"nf_tables"* ]]; then
                    FWTYPE="nftables"
                else
                    echo -e "\e[1;33m⚠️ Не удалось определить тип файрвола.\e[0m"
                    echo -e "По умолчанию используется: \e[1;36miptables\e[0m"
                    echo -e "\e[2m(Можно изменить в /opt/zapret/config)\e[0m"
                    echo -e "⏳ Продолжаю через 5 секунд..."
                    FWTYPE="iptables"
                    sleep 5
                fi
            else
                echo -e "\e[1;31m❌ iptables не найден!\e[0m"
                echo -e "По умолчанию используется: \e[1;36miptables\e[0m"
                echo -e "\e[2m(Можно изменить в /opt/zapret/config)\e[0m"
                echo -e "⏳ Продолжаю через 5 секунд..."
                FWTYPE="iptables"
                sleep 5
            fi
            ;;
        FreeBSD)
            if exists ipfw ; then
                FWTYPE="ipfw"
            else
                echo -e "\e[1;33m⚠️ ipfw не найден!\e[0m"
                echo -e "По умолчанию используется: \e[1;36miptables\e[0m"
                echo -e "\e[2m(Можно изменить в /opt/zapret/config)\e[0m"
                echo -e "⏳ Продолжаю через 5 секунд..."
                FWTYPE="iptables"
                sleep 5
            fi
            ;;
        *)
            echo -e "\e[1;31m❌ Неизвестная система: $UNAME\e[0m"
            echo -e "По умолчанию используется: \e[1;36miptables\e[0m"
            echo -e "\e[2m(Можно изменить в /opt/zapret/config)\e[0m"
            echo -e "⏳ Продолжаю через 5 секунд..."
            FWTYPE="iptables"
            sleep 5
            ;;
    esac
}



manage_service() {
    case "$INIT_SYSTEM" in
        systemd)
            SYSTEMD_PAGER=cat systemctl "$1" zapret
            ;;
        openrc)
            rc-service zapret "$1"
            ;;
        runit)
            sv "$1" zapret
            ;;
        sysvinit)
            service zapret "$1"
            ;;
        procd)
            service zapret "$1"
    esac
}

manage_autostart() {
    case "$INIT_SYSTEM" in
        systemd)
            systemctl "$1" zapret
            ;;
        runit)
            if [[ "$1" == "enable" ]]; then
                ln -fs /opt/zapret/init.d/runit/zapret/ /var/service/
            else
                rm -f /var/service/zapret
            fi
            ;;
        sysvinit)
            if [[ "$1" == "enable" ]]; then
                update-rc.d zapret defaults
            else
                update-rc.d -f zapret remove
            fi
            ;;
        openrc)
            service zapret "$1"
            ;;
        procd)
            service zapret "$1"
    esac
}

install_dependencies() {
    kernel="$(uname -s)"
    if [ "$kernel" = "Linux" ]; then
        . /etc/os-release
        
        declare -A command_by_ID=(
            ["arch"]="pacman -S --noconfirm ipset dnscrypt-proxy"
            ["debian"]="apt-get install -y iptables ipset dnscrypt-proxy"
            ["fedora"]="dnf install -y iptables ipset"
            ["ubuntu"]="apt-get install -y iptables ipset dnscrypt-proxy"
            ["mint"]="apt-get install -y iptables ipset dnscrypt-proxy"
            ["centos"]="sudo yum install -y ipset iptables"
            ["void"]="xbps-install -y iptables ipset"
            ["gentoo"]="emerge net-firewall/iptables net-firewall/ipset net-dns/dnscrypt-proxy"
            ["opensuse"]="zypper install -y iptables ipset"
            ["openwrt"]="opkg install iptables ipset"
            ["altlinux"]="apt-get install -y iptables ipset"
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


toggle_service() {
    while true; do
        clear
        echo -e "\e[1;36m╔═════════════════════════════════════════════════╗"
        echo -e "║       🛠️ Управление сервисом Запрета            ║"
        echo -e "╚═════════════════════════════════════════════════╝\e[0m"

        if [[ $ZAPRET_ACTIVE == true ]]; then 
            echo -e "  \e[1;32m✔️ Запрет запущен\e[0m"
        else 
            echo -e "  \e[1;31m❌ Запрет выключен\e[0m"
        fi

        if [[ $ZAPRET_ENABLED == true ]]; then 
            echo -e "  \e[1;32m🔁 Запрет в автозагрузке\e[0m"
        else 
            echo -e "  \e[1;33m⏹️ Запрет не в автозагрузке\e[0m"
        fi

        echo ""

        echo -e "  \e[1;33m1)\e[0m $( [[ $ZAPRET_ENABLED == true ]] && echo "🚫 Убрать из автозагрузки" || echo "✅ Добавить в автозагрузку" )"
        echo -e "  \e[1;32m2)\e[0m $( [[ $ZAPRET_ACTIVE == true ]] && echo "⛔ Выключить Запрет" || echo "▶️ Включить Запрет" )"
        echo -e "  \e[1;36m3)\e[0m 🔍 Посмотреть статус Запрета"
        echo -e "  \e[1;35m4)\e[0m 🔄 Перезапустить Запрет"
        echo -e "  \e[1;31m5)\e[0m 🚪 Выйти в меню"

        echo ""
        echo -e "\e[1;96m✨ Сделано с любовью 💙\e[0m by: \e[4;94mhttps://t.me/linux_hi\e[0m"
        echo ""

        read -p $'\e[1;36mВыберите действие: \e[0m' CHOICE
        case "$CHOICE" in
            1) 
                [[ $ZAPRET_ENABLED == true ]] && manage_autostart disable || manage_autostart enable
                main_menu
                ;;
            2) 
                [[ $ZAPRET_ACTIVE == true ]] && manage_service stop || manage_service start
                main_menu
                ;;
            3) 
                manage_service status
                read -p $'\e[1;36mНажмите Enter для продолжения...\e[0m'
                main_menu
                ;;
            4) 
                manage_service restart
                main_menu
                ;;
            5) 
                main_menu
                ;;
            *) 
                echo -e "\e[1;31m❌ Неверный ввод! Попробуйте снова.\e[0m"
                sleep 2
                ;;
        esac
    done
}

main_menu() {
    while true; do
        clear
        check_zapret_status
        check_zapret_exist
        echo -e "\e[1;36m╔════════════════════════════════════════════╗"
        echo -e "║         ⚙️ Меню управления Запретом        ║"
        echo -e "╚════════════════════════════════════════════╝\e[0m"

        if [[ $ZAPRET_ACTIVE == true ]]; then 
            echo -e "  \e[1;32m✔️ Запрет запущен\e[0m"
        else 
            echo -e "  \e[1;31m❌ Запрет выключен\e[0m"
        fi 

        if [[ $ZAPRET_ENABLED == true ]]; then 
            echo -e "  \e[1;32m🔁 Запрет в автозагрузке\e[0m"
        else 
            echo -e "  \e[1;33m⏹️ Запрет не в автозагрузке\e[0m"
        fi

        echo ""

        if [[ $ZAPRET_EXIST == true ]]; then
            echo -e "  \e[1;33m1)\e[0m 🔄 Проверить на обновления и обновить"
            echo -e "  \e[1;36m2)\e[0m ⚙️ Сменить конфигурацию запрета"
            echo -e "  \e[1;35m3)\e[0m 🛠️ Управление сервисом запрета"
            echo -e "  \e[1;31m4)\e[0m 🗑️ Удалить Запрет"
            echo -e "  \e[1;34m5)\e[0m 🚪 Выйти"
        else
            echo -e "  \e[1;32m1)\e[0m 📥 Установить Запрет"
            echo -e "  \e[1;36m2)\e[0m 📜 Проверить скрипт на обновления"
            echo -e "  \e[1;34m3)\e[0m 🚪 Выйти"
        fi

        echo ""
        echo -e "\e[1;96m✨ Сделано с любовью 💙\e[0m by: \e[4;94mhttps://t.me/linux_hi\e[0m"
        echo ""

        if [[ $ZAPRET_EXIST == true ]]; then
            read -p $'\e[1;36mВыберите действие: \e[0m' CHOICE
            case "$CHOICE" in
                1) update_zapret_menu;;
                2) change_configuration;;
                3) toggle_service;;
                4) uninstall_zapret;;
                5) $TPUT_E; exit 0;;
                *) echo -e "\e[1;31m❌ Неверный ввод! Попробуйте снова.\e[0m"; sleep 2;;
            esac
        else
            read -p $'\e[1;36mВыберите действие: \e[0m' CHOICE
            case "$CHOICE" in
                1) install_zapret; main_menu;;
                2) update_script;;
                3) tput rmcup; exit 0;;
                *) echo -e "\e[1;31m❌ Неверный ввод! Попробуйте снова.\e[0m"; sleep 2;;
            esac
        fi
    done
}




install_zapret() {
    install_dependencies 
    if [[ $dir_exists == true ]]; then
        read -p "На вашем компьютере был найден запрет (/opt/zapret). Для продолжения его необходимо удалить. Вы действительно хотите удалить запрет (/opt/zapret) и продолжить? (y/N): " answer
        case "$answer" in
            [Yy]* ) 
                if [[ -f /opt/zapret/uninstall_easy.sh ]]; then
                    cd /opt/zapret
                    sed -i '235s/ask_yes_no N/ask_yes_no Y/' /opt/zapret/common/installer.sh
                    yes "" | ./uninstall_easy.sh
                    sed -i '235s/ask_yes_no N/ask_yes_no Y/' /opt/zapret/common/installer.sh
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
    

    echo "Клонирую репозиторий..."
    sleep 2
    git clone https://github.com/bol-van/zapret /opt/zapret
    echo "Клонирую репозиторий..."
    git clone https://github.com/Snowy-Fluffy/zapret.cfgs /opt/zapret/zapret.cfgs
    echo "Клонирование успешно завершено."
    
    sudo rm -rf /opt/zapret/binaries
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

    cd /opt/zapret
    sed -i '235s/ask_yes_no N/ask_yes_no Y/' /opt/zapret/common/installer.sh
    yes "" | ./install_easy.sh
    sed -i '235s/ask_yes_no N/ask_yes_no Y/' /opt/zapret/common/installer.sh
    cp -r /opt/zapret.installer/zapret-control.sh /bin/zapret || error_exit "не удалось скопировать скрипт в /bin" 
    chmod +x /bin/zapret
    rm -f /opt/zapret/config 
    cp -r /opt/zapret/zapret.cfgs/configurations/general /opt/zapret/config || error_exit "не удалось автоматически скопировать конфиг"

    rm -f /opt/zapret/ipset/zapret-hosts-user.txt
    cp -r /opt/zapret/zapret.cfgs/lists/list-basic.txt /opt/zapret/ipset/zapret-hosts-user.txt || error_exit "не удалось автоматически скопировать хостлист"

    cp -r /opt/zapret/zapret.cfgs/lists/ipset-discord.txt /opt/zapret/ipset/ipset-discord.txt || error_exit "не удалось автоматически скопировать ипсет"
    
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




change_configuration() {
    while true; do
        clear
        cur_conf
        cur_list

        echo -e "\e[1;36m╔══════════════════════════════════════════════╗"
        echo -e "║     ⚙️  Управление конфигурацией Запрета     ║"
        echo -e "╚══════════════════════════════════════════════╝\e[0m"
        echo -e "  \e[1;33m📌 Используемая стратегия:\e[0m \e[1;32m$cr_cnf\e[0m"
        echo -e "  \e[1;33m📜 Используемый хостлист:\e[0m \e[1;32m$cr_lst\e[0m"
        echo ""
        echo -e "  \e[1;34m1)\e[0m 🔁 Сменить стратегию"
        echo -e "  \e[1;34m2)\e[0m 📄 Сменить лист обхода"
        echo -e "  \e[1;34m3)\e[0m ➕ Добавить IP или домены в лист"
        echo -e "  \e[1;34m4)\e[0m ➖ Удалить IP или домены из листа"
        echo -e "  \e[1;34m5)\e[0m 🔍 Найти IP или домены в листе"
        echo -e "  \e[1;31m6)\e[0m 🚪 Выйти в меню"
        echo ""
        echo -e "\e[1;96m✨ Сделано с любовью 💙\e[0m by: \e[4;94mhttps://t.me/linux_hi\e[0m"
        echo ""

        read -p $'\e[1;36mВыберите действие: \e[0m' CHOICE
        case "$CHOICE" in
            1) configure_zapret_conf ;;
            2) configure_zapret_list ;;
            3) add_to_zapret ;;
            4) delete_from_zapret ;;
            5) search_in_zapret ;;
            6) main_menu ;;
            *) echo -e "\e[1;31m❌ Неверный ввод! Попробуйте снова.\e[0m"; sleep 2 ;;
        esac
    done
}







update_zapret_menu(){
    while true; do
        clear
        echo -e "\e[1;36m╔════════════════════════════════════╗"
        echo -e "║        🔄 Обновление Запрета       ║"
        echo -e "╚════════════════════════════════════╝\e[0m"
        echo -e "  \e[1;33m1)\e[0m 🔧 Обновить \e[33mzapret и скрипт\e[0m \e[2m(не рекомендуется)\e[0m"
        echo -e "  \e[1;32m2)\e[0m 📜 Обновить только \e[32mскрипт\e[0m"
        echo -e "  \e[1;31m3)\e[0m 🚪 Выйти в меню"
        echo ""
        echo -e "\e[1;96m✨ Сделано с любовью 💙\e[0m by: \e[4;94mhttps://t.me/linux_hi\e[0m"
        echo ""
        read -p $'\e[1;36mВыберите действие: \e[0m' CHOICE
        case "$CHOICE" in
            1) update_zapret;;
            2) update_installed_script;;
            3) main_menu;;
            *) echo -e "\e[1;31m❌ Неверный ввод! Попробуйте снова.\e[0m"; sleep 2;;
        esac
    done
}




update_zapret() {
    if [[ -d /opt/zapret ]]; then
        cd /opt/zapret && git pull
    fi
    if [[ -d /opt/zapret/zapret.cfgs ]]; then
        cd /opt/zapret/zapret.cfgs && git pull
    fi
    if [[ -d /opt/zapret.installer/ ]]; then
        cd /opt/zapret.installer/ && git pull
        rm -f /bin/zapret
        cp -r /opt/zapret.installer/zapret-control.sh /bin/zapret || error_exit "не удалось скопировать скрипт в /bin при обновлении"
        chmod +x /bin/zapret
    fi
    manage_service restart
    bash -c 'read -p "Нажмите Enter для продолжения..."'
    exec "$0" "$@"
}

update_script() {
    if [[ -d /opt/zapret/zapret.cfgs ]]; then
        cd /opt/zapret/zapret.cfgs && git pull
    fi
    if [[ -d /opt/zapret.installer/ ]]; then
        cd /opt/zapret.installer/ && git pull
    fi

    bash -c 'read -p "Нажмите Enter для продолжения..."'
    exec "$0" "$@"
}

update_installed_script() {
    if [[ -d /opt/zapret/zapret.cfgs ]]; then
        cd /opt/zapret/zapret.cfgs && git pull
    fi
    if [[ -d /opt/zapret.installer/ ]]; then
        cd /opt/zapret.installer/ && git pull
        rm -f /bin/zapret
        cp -r /opt/zapret.installer/zapret-control.sh /bin/zapret || error_exit "не удалось скопировать скрипт в /bin при обновлении"
        chmod +x /bin/zapret
        manage_service restart
    fi

    bash -c 'read -p "Нажмите Enter для продолжения..."'
    exec "$0" "$@"
}

add_to_zapret() {
    read -p "Введите IP-адреса или домены для добавления в лист (разделяйте пробелами, запятыми или |)(Enter и пустой ввод для отмены): " input
    
    if [[ -z "$input" ]]; then
        main_menu
    fi

    IFS=',| ' read -ra ADDRESSES <<< "$input"

    for address in "${ADDRESSES[@]}"; do
        address=$(echo "$address" | xargs)
        if [[ -n "$address" && ! $(grep -Fxq "$address" "/opt/zapret/ipset/zapret-hosts-user.txt") ]]; then
            echo "$address" >> "/opt/zapret/ipset/zapret-hosts-user.txt"
            echo "Добавлено: $address"
        else
            echo "Уже существует: $address"
        fi
    done
    
    manage_service restart

    echo "Готово"
    sleep 2
    main_menu
}

delete_from_zapret() {
    read -p "Введите IP-адреса или домены для удаления из листа (разделяйте пробелами, запятыми или |)(Enter и пустой ввод для отмены): " input

    if [[ -z "$input" ]]; then
        main_menu
    fi

    IFS=',| ' read -ra ADDRESSES <<< "$input"

    for address in "${ADDRESSES[@]}"; do
        address=$(echo "$address" | xargs)
        if [[ -n "$address" ]]; then
            if grep -Fxq "$address" "/opt/zapret/ipset/zapret-hosts-user.txt"; then
                sed -i "\|^$address\$|d" "/opt/zapret/ipset/zapret-hosts-user.txt"
                echo "Удалено: $address"
            else
                echo "Не найдено: $address"
            fi
        fi
    done

    manage_service restart

    echo "Готово"
    sleep 2
    main_menu
}

search_in_zapret() {
    read -p "Введите домен или IP-адрес для поиска в хостлисте (Enter и пустой ввод для отмены): " keyword

    if [[ -z "$keyword" ]]; then
        main_menu
    fi

    matches=$(grep "$keyword" "/opt/zapret/ipset/zapret-hosts-user.txt")

    if [[ -n "$matches" ]]; then
        echo "Найденные записи:"
        echo "$matches"
        bash -c 'read -p "Нажмите Enter для продолжения..."'
    else
        echo "Совпадений не найдено."
        sleep 2
        main_menu
    fi
}

cur_conf() {
    cr_cnf="неизвестно"
    if [[ -f /opt/zapret/config ]]; then
        for file in /opt/zapret/zapret.cfgs/configurations/*; do
            if [[ -f "$file" && "$(sha256sum "$file" | awk '{print $1}')" == "$(sha256sum /opt/zapret/config | awk '{print $1}')" ]]; then
                cr_cnf="$(basename "$file")"
                break
            fi
        done
    fi
}

cur_list() {
    cr_lst="неизвестно"
    if [[ -f /opt/zapret/config ]]; then
        for file in /opt/zapret/zapret.cfgs/lists/*; do
            if [[ -f "$file" && "$(sha256sum "$file" | awk '{print $1}')" == "$(sha256sum /opt/zapret/ipset/zapret-hosts-user.txt | awk '{print $1}')" ]]; then
                cr_lst="$(basename "$file")"
                break
            fi
        done
    fi
}

configure_zapret_conf() {
    if [[ ! -d /opt/zapret/zapret.cfgs ]]; then
        echo -e "\e[35mКлонирую конфигурации...\e[0m"
        git clone https://github.com/Snowy-Fluffy/zapret.cfgs /opt/zapret/zapret.cfgs
        echo -e "\e[32mКлонирование успешно завершено.\e[0m"
        sleep 2
    fi
    if [[ -d /opt/zapret/zapret.cfgs ]]; then
        echo "Проверяю наличие на обновление конфигураций..."
        cd /opt/zapret/zapret.cfgs && git pull
        sleep 2
    fi

    clear




    echo "Выберите стратегию (можно поменять в любой момент, запустив Меню управления запретом еще раз):"
    PS3="Введите номер стратегии (по умолчанию 'general'): "

    select CONF in $(for f in /opt/zapret/zapret.cfgs/configurations/*; do echo "$(basename "$f" | tr ' ' '.')"; done) "Отмена"; do
        if [[ "$CONF" == "Отмена" ]]; then
            main_menu
        elif [[ -n "$CONF" ]]; then
            CONFIG_PATH="/opt/zapret/zapret.cfgs/configurations/${CONF//./ }"
            rm -f /opt/zapret/config
            cp "$CONFIG_PATH" /opt/zapret/config || error_exit "не удалось скопировать стратегию"
            echo "Стратегия '$CONF' установлена."


            sleep 2
            break
        else
            echo "Неверный выбор, попробуйте снова."
        fi
    done


   
    get_fwtype

    sed -i "s/^FWTYPE=.*/FWTYPE=$FWTYPE/" /opt/zapret/config

    manage_service restart
    
    main_menu
}

configure_zapret_list() {
    if [[ ! -d /opt/zapret/zapret.cfgs ]]; then
        echo -e "\e[35mКлонирую конфигурации...\e[0m"
        git clone https://github.com/Snowy-Fluffy/zapret.cfgs /opt/zapret/zapret.cfgs
        echo -e "\e[32mКлонирование успешно завершено.\e[0m"
        sleep 2
    fi
    if [[ -d /opt/zapret/zapret.cfgs ]]; then
        echo "Проверяю наличие на обновление конфигураций..."
        cd /opt/zapret/zapret.cfgs && git pull
        sleep 2
    fi

    clear


    echo -e "\e[36mВыберите хостлист (можно поменять в любой момент, запустив Меню управления запретом еще раз):\e[0m"
    PS3="Введите номер листа (по умолчанию 'list-basic.txt'): "

    select LIST in $(for f in /opt/zapret/zapret.cfgs/lists/list*; do echo "$(basename "$f")"; done) "Отмена"; do
        if [[ "$LIST" == "Отмена" ]]; then
            main_menu
        elif [[ -n "$LIST" ]]; then
            LIST_PATH="/opt/zapret/zapret.cfgs/lists/$LIST"
            rm -f /opt/zapret/ipset/zapret-hosts-user.txt
            cp "$LIST_PATH" /opt/zapret/ipset/zapret-hosts-user.txt || error_exit "не удалось скопировать хостлист"
            echo -e "\e[32mХостлист '$LIST' установлен.\e[0m"

            sleep 2
            break
        else
            echo -e "\e[31mНеверный выбор, попробуйте снова.\e[0m"
        fi
    done
    manage_service restart
    
    main_menu
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

check_openwrt
check_tput
$TPUT_B
detect_init
main_menu
