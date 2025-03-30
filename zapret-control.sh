#!/bin/bash

set -e  

if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

error_exit() {
    $TPUT_E 
    echo -e "\e[31mОшибка:\e[0m $1" >&2 
    exit 1
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
        error_exit "Ваш Init не поддерживается."
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
        openrc)
            rc-service -l | grep -q "zapret" && service_exists=true || service_exists=false
            ;;
        procd)
            if [ -f /etc/init.d/zapret ]; then
                service_exists=true
            else
                service_exists=false
            fi
            ;;
        runit)
            [ -d /etc/service/zapret ] && service_exists=true || service_exists=false
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
            sv status zapret >/dev/null 2>&1 && ZAPRET_ACTIVE=true || ZAPRET_ACTIVE=false
            [ -L /var/service/zapret ] && ZAPRET_ENABLED=true || ZAPRET_ENABLED=false
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
        TPUT_B=""
        TPUT_E=""
        
    else
        TPUT_B="tput smcup"
        TPUT_E="tput rmcup"
    fi
}




get_fwtype() {
    [ -n "$FWTYPE" ] && return

    local UNAME="$(uname)"

    case "$UNAME" in
        Linux)
            if [[ $SYSTEM == openwrt ]]; then
                local version_id
                version_id=$(grep '^VERSION_ID=' "$os_release" | cut -d '"' -f2)

                if [ "$(echo "$version_id >= 22.03" | bc)" -eq 1 ]; then
                    FWTYPE=nftables
                    return 0
                else
                    FWTYPE=iptables
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
                    echo "Не удалось определить файрвол. По умолчанию установлен iptables, вы его можете изменить в файле /opt/zapret/config."
                    echo "Продолжаю через 5 секунд..."
                    FWTYPE="iptables"
                    sleep 5
                fi
            else
                echo "Не удалось определить файрвол. По умолчанию установлен iptables, вы его можете изменить в файле /opt/zapret/config."
                echo "Продолжаю через 5 секунд..."
                
                FWTYPE="iptables"
                sleep 5
            fi
            ;;
        FreeBSD)
            if exists ipfw ; then
                FWTYPE="ipfw"
            else
                echo "Не удалось определить файрвол. По умолчанию установлен iptables, вы его можете изменить в файле /opt/zapret/config."
                echo "Продолжаю через 5 секунд..."
                
                FWTYPE="iptables"
                sleep 5
            fi
            ;;
        *)
        echo "Не удалось определить файрвол. По умолчанию установлен iptables, вы его можете изменить в файле /opt/zapret/config."
        echo "Продолжаю через 5 секунд..."
        
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
        openrc)
            service zapret "$1"
    esac
}

manage_autostart() {
    case "$INIT_SYSTEM" in
        systemd)
            systemctl "$1" zapret
            ;;
        openrc)
            if [[ "$1" == "enable" ]]; then
                rc-update add zapret default
            else
                rc-update del zapret default
            fi
            ;;
        runit)
            if [[ "$1" == "enable" ]]; then
                ln -s /etc/sv/zapret /var/service/
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
    esac
}

install_dependencies() {
    kernel="$(uname -s)"
    if [ "$kernel" = "Linux" ]; then
        . /etc/os-release

        declare -A command_by_ID=(
            ["arch"]="pacman -S --noconfirm make gcc wget libcap ipset \
                            libnetfilter_queue"
            ["debian"]="apt-get install -y make gcc zlib1g-dev ipset iptables \
                            libcap-dev wget"
            ["fedora"]="dnf install -y make gcc zlib-devel ipset iptables \
                            libcap-devel wget"
            ["ubuntu"]="apt-get install -y make gcc zlib1g-dev wget ipset iptables \
                            libcap-dev"
            ["mint"]="apt-get install -y make gcc wget zlib1g-dev ipset iptables \
                            libcap-dev libnetfilter-queue-dev"
            ["void"]="xpbs-install -y make gcc zlib libcap wget ipset iptables \
                            libnetfilter_queue"
            ["gentoo"]="emerge sys-libs/zlib net-firewall/iptables net-misc/wget net-firewall/ipset sys-libs/libcap  \
                            net-libs/libnetfilter_queue"
            ["opensuse"]="zypper install -y make gcc wget zlib-devel ipset iptables \
                            libcap-devel libnetfilter_queue-devel"
            ["openwrt"]="opkg install iptables ipset \
                            libcap wget"

        )

        if [[ -v command_by_ID[$ID] ]]; then
            eval "${command_by_ID[$ID]}"
        elif [[ -v command_by_ID[$ID_LIKE] ]]; then
            eval "${command_by_ID[$ID_LIKE]}"
        fi
    elif [ "$kernel" = "Darwin" ]; then
        error_exit "macOS не поддерживается на данный момент." 
    else
        error_exit "Неизвестная ОС: ${kernel}"
    fi
}



main_menu() {
    while true; do
        clear
        check_zapret_status
        check_zapret_exist
        echo "===== Меню управления Запретом ====="
        if [[ $ZAPRET_ACTIVE == true ]]; then echo "!Запрет запущен!"; fi
        if [[ $ZAPRET_ACTIVE == false ]]; then echo "!Запрет выключен!"; fi 
        if [[ $ZAPRET_EXIST == false ]]; then clear; echo "===== Меню управления Запретом ====="; echo "!Запрет не установлен!"; fi
        if [[ $ZAPRET_EXIST == true ]]; then
            echo "1) Проверить на обновления и обновить"
            echo "2) Сменить конфигурацию запрета"
            echo "3) Перезапустить Запрет"
            echo "4) Посмотреть статус Запрета"
            if [[ $ZAPRET_ENABLED == false ]]; then echo "5) Добавить в автозагрузку"; fi
            if [[ $ZAPRET_ACTIVE == false ]]; then echo "6) Включить Запрет"; fi
            if [[ $ZAPRET_ENABLED == true ]]; then echo "7) Убрать из автозагрузки"; fi
            if [[ $ZAPRET_ACTIVE == true ]]; then echo "8) Выключить Запрет"; fi
            echo "9) Удалить Запрет"
            echo "10) Выйти"
            read -p "Выберите действие: " CHOICE
            case "$CHOICE" in
                1) update_zapret;;
                2) change_configuration;;
                3) manage_service restart;;
                4) manage_service status; bash -c 'read -p "Нажмите Enter для продолжения..."';;
                5) manage_autostart enable;;
                6) manage_service start;;
                7) manage_autostart disable;;
                8) manage_service stop;;
                9) uninstall_zapret;;
                10) $TPUT_E; exit 0;;
                *) echo "Неверный ввод!"; sleep 2;;
            esac
        else
            echo "1) Установить Запрет"
            echo "2) Проверить скрипт на обновления"
            echo "3) Выйти"
            read -p "Выберите действие: " CHOICE
            case "$CHOICE" in
                1) install_zapret; main_menu;;
                2) update_script;;
                3) $TPUT_E; exit 0;;
                *) echo "Неверный ввод!"; sleep 2;;
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
                    yes "" | ./uninstall_easy.sh
                fi
                rm -rf /opt/zapret

                ;;
            * ) 
                main_menu
                ;;
        esac
    fi
    

    echo "Клонирую репозиторий..."
    if ! git clone https://github.com/bol-van/zapret /opt/zapret ; then
         error_exit "нестабильноe/слабое подключение к интернету."
    fi
    echo "Клонирование успешно завершено."

    echo "Клонирую репозиторий..."
        if ! git clone https://github.com/Snowy-Fluffy/zapret.cfgs /opt/zapret/zapret.cfgs ; then
        error_exit "нестабильноe/слабое подключение к интернету."
    fi
    echo "Клонирование успешно завершено."
    

    if [[ ! -d /opt/zapret.installer/zapret.binaries ]]; then
        echo "Клонирую релиз запрета..."
        mkdir -p /opt/zapret.installer/zapret.binaries
        if ! curl -L -o /opt/zapret.installer/zapret.binaries/zapret https://github.com/bol-van/zapret/releases/download/v70.4/zapret-v70.4.tar.gz; then
            rm -rf /opt/zapret.installer/
            error_exit "не удалось получить релиз запрета."
        fi
        echo "Получение запрета завершено."
        tar -xzf /opt/zapret.installer/zapret.binaries/zapret/zapret-v70.4.tar.gz -C /opt/zapret.installer/zapret.binaries/zapret
        cp -r /opt/zapret.installer/zapret.binaries/zapret/zapret-v70.4/binaries/ /opt/zapret/binaries

    fi
    if [[ ! -d /opt/zapret/binaries ]]; then
        tar -xzf /opt/zapret.installer/zapret.binaries/zapret/zapret-v70.4.tar.gz -C /opt/zapret.installer/zapret.binaries/zapret
        cp -r /opt/zapret.installer/zapret.binaries/zapret/zapret-v70.4/binaries/ /opt/zapret/binaries
    fi
    cd /opt/zapret
    yes "" | ./install_easy.sh
    cp -r /opt/zapret.installer/zapret-control.sh /bin/zapret || error_exit "не удалось скопировать скрипт в /bin" 
    chmod +x /bin/zapret
    rm -f /opt/zapret/config 
    cp -r /opt/zapret/zapret.cfgs/configurations/general /opt/zapret/config || error_exit "не удалось автоматически скопировать конфиг"
    rm -f /opt/zapret/ipset/zapret-hosts-user.txt
    cp -r /opt/zapret/zapret.cfgs/lists/list-basic.txt /opt/zapret/ipset/zapret-hosts-user.txt || error_exit "не удалось автоматически скопировать хостлист"
    cp -r /opt/zapret/zapret.cfgs/lists/ipset-discord.txt /opt/zapret/ipset/ipset-discord.txt || error_exit "не удалось автоматически скопировать ипсет"
    manage_service restart
    configure_zapret_conf
    
}

change_configuration(){
    while true; do
        clear
        echo "===== Меню управления Запретом ====="
        echo "1) Сменить стратегию"
        echo "2) Сменить лист обхода"
        echo "3) Добавить ip-адреса или домены в лист обхода"
        echo "4) Удалить ip-адреса или домены из листа обхода"
        echo "5) Поиск ip-адреса или домена в листе обхода"
        echo "6) Выйти в меню"
        read -p "Выберите действие: " CHOICE
        case "$CHOICE" in
            1) configure_zapret_conf;;
            2) configure_zapret_list;;
            3) add_to_zapret;;
            4) delete_from_zapret;;
            5) search_in_zapret;;
            6) main_menu;;
            *) echo "Неверный ввод!"; sleep 2;;
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

add_to_zapret() {
    read -p "Введите IP-адреса или домены для добавления в лист (разделяйте пробелами, запятыми или |)(Enter для отмены): " input
    
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
    read -p "Введите IP-адреса или домены для удаления из листа (разделяйте пробелами, запятыми или |)(Enter для отмены): " input

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
    read -p "Введите домен или IP-адрес для поиска в хостлисте (Enter для отмены): " keyword

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

configure_zapret_conf() {
    if [[ ! -d /opt/zapret/zapret.cfgs ]]; then
        echo "Клонирую конфигурации..."
        if ! git clone https://github.com/Snowy-Fluffy/zapret.cfgs /opt/zapret/zapret.cfgs ; then
            error_exit "нестабильноe/слабое подключение к интернету."
        fi
            echo "Клонирование успешно завершено."
            sleep 2
    fi
    if [[ -d /opt/zapret/zapret.cfgs ]]; then
        echo "Проверяю наличие на обновление конфигураций..."
        cd /opt/zapret/zapret.cfgs && git pull
        sleep 2
    fi

    clear


    echo "Выберите стратегию (можно поменять в любой момент, запустив Меню управления запретом еще раз):"
    PS3="Введите номер стратегии (по умолчанию 6): "

    select CONF in /opt/zapret/zapret.cfgs/configurations/* "Отмена"; do

    
        if [[ "$CONF" == "Отмена" ]]; then
            main_menu
        elif [[ -n "$CONF" ]]; then
            rm -f /opt/zapret/config
            cp "$CONF" /opt/zapret/config
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
        echo "Клонирую конфигурации..."
        if ! git clone https://github.com/Snowy-Fluffy/zapret.cfgs /opt/zapret/zapret.cfgs ; then
            error_exit "нестабильноe/слабое подключение к интернету."
        fi
            echo "Клонирование успешно завершено."
            sleep 2
    fi
    if [[ -d /opt/zapret/zapret.cfgs ]]; then
        echo "Проверяю наличие на обновление конфигураций..."
        cd /opt/zapret/zapret.cfgs && git pull
        sleep 2
    fi

    clear

    echo "Выберите хостлист (можно поменять в любой момент, запустив Меню управления запретом еще раз):"
    PS3="Введите номер листа (по умолчанию 2): "
    select LIST in /opt/zapret/zapret.cfgs/lists/list* "Отмена"; do
        if [[ "$LIST" == "Отмена" ]]; then
            main_menu
        elif [[ -n "$LIST" ]]; then
            rm -f /opt/zapret/ipset/zapret-hosts-user.txt
            cp "$LIST" /opt/zapret/ipset/zapret-hosts-user.txt
            echo "Хостлист '$LIST' установлен."
            sleep 2
            break
        else
            echo "Неверный выбор, попробуйте снова."
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
            ;;
        * ) 
            main_menu
            ;;
    esac
}

check_openwrt
$TPUT_B
detect_init
main_menu
