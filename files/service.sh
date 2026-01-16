#!/bin/bash



manage_service() {
    case "$INIT_SYSTEM" in
        systemd)
            SYSTEMD_PAGER=cat systemctl "$1" zapret
            ;;
        openrc)
            rc-service zapret "$1"
            ;;
        runit|runit-artix)
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
        runit-artix)
            if [[ "$1" == "enable" ]]; then
                ln -fs /opt/zapret/init.d/runit/zapret/ /run/runit/service/
            else
                rm -f /run/runit/service/zapret
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
            if [[ "$1" == "enable" ]]; then
                rc-update add zapret default
            else
                rc-update del zapret
            fi
            ;;
        procd)
            service zapret "$1"
    esac
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
            ls /var/service | grep -q "zapret" && service_exists=true || service_exists=false
            ;;
        runit-artix)
            ls /run/runit/service | grep -q "zapret" && service_exists=true || service_exists=false
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
        runit-artix)
            sv status zapret | grep -q "run" && ZAPRET_ACTIVE=true || ZAPRET_ACTIVE=false 
            ls /run/runit/service | grep -q "zapret" && ZAPRET_ENABLED=true || ZAPRET_ENABLED=false
            ;;
        sysvinit)
            service zapret status >/dev/null 2>&1 && ZAPRET_ACTIVE=true || ZAPRET_ACTIVE=false
            ;;
    esac
}

toggle_service() {
    while true; do
        clear
        echo -e "\e[1;36m╔═════════════════════════════════════════════════╗"
        echo -e "║         Управление сервисом Запрета             ║"
        echo -e "╚═════════════════════════════════════════════════╝\e[0m"

        if [[ $ZAPRET_ACTIVE == true ]]; then 
            echo -e "  \e[1;32m Запрет запущен\e[0m"
        else 
            echo -e "  \e[1;31m Запрет выключен\e[0m"
        fi

        if [[ $ZAPRET_ENABLED == true ]]; then 
            echo -e "  \e[1;32m Запрет в автозагрузке\e[0m"
        else 
            echo -e "  \e[1;33m Запрет не в автозагрузке\e[0m"
        fi

        echo ""

        echo -e "  \e[1;31m0)\e[0m Выйти в меню"
        echo -e "  \e[1;33m1)\e[0m $( [[ $ZAPRET_ENABLED == true ]] && echo "Убрать из автозагрузки" || echo "Добавить в автозагрузку" )"
        echo -e "  \e[1;32m2)\e[0m $( [[ $ZAPRET_ACTIVE == true ]] && echo "Выключить Запрет" || echo "Включить Запрет" )"
        echo -e "  \e[1;36m3)\e[0m Посмотреть статус Запрета"
        echo -e "  \e[1;35m4)\e[0m Перезапустить Запрет"

        echo ""
        echo -e "\e[1;96m Сделано\e[0m by: \e[4;94mhttps://t.me/linux_hi\e[0m"
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
            0) 
                main_menu
                ;;
            *) 
                echo -e "\e[1;31m Неверный ввод! Попробуйте снова.\e[0m"
                sleep 2
                ;;
        esac
    done
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
    elif command -v openrc >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
    elif command -v runit >/dev/null 2>&1; then
        INIT_SYSTEM="runit"
        [ -f /etc/os-release ] && . /etc/os-release
        if [ $ID = artix ]; then
            INIT_SYSTEM="runit-artix"
        fi
    elif [ -x /sbin/init ] && /sbin/init --version 2>&1 | grep -qi "sysv init"; then
        INIT_SYSTEM="sysvinit" 
    else
        error_exit "Не удалось определить init."
    fi
}
