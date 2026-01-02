#!/bin/bash



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

cur_conf() {
    cr_cnf="неизвестно"
    if [[ -f /opt/zapret/config ]]; then
        TEMP_CUR_STR=$(mktemp -d)
        cp -r /opt/zapret/config $TEMP_CUR_STR/config
        sed -i "s/^FWTYPE=.*/FWTYPE=iptables/" $TEMP_CUR_STR/config
        for file in /opt/zapret/zapret.cfgs/configurations/*; do
            if [[ -f "$file" && "$(sha256sum "$file" | awk '{print $1}')" == "$(sha256sum $TEMP_CUR_STR/config | awk '{print $1}')" ]]; then
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
        manage_service stop
        git clone https://github.com/Snowy-Fluffy/zapret.cfgs /opt/zapret/zapret.cfgs
        echo -e "\e[32mКлонирование успешно завершено.\e[0m"
        manage_service start
        sleep 2
    fi
    if [[ -d /opt/zapret/zapret.cfgs ]]; then
        echo "Проверяю наличие на обновление конфигураций..."
        manage_service stop 
        cd /opt/zapret/zapret.cfgs && git fetch origin main; git reset --hard origin/main
        manage_service start
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
        manage_service stop
        git clone https://github.com/Snowy-Fluffy/zapret.cfgs /opt/zapret/zapret.cfgs
        manage_service start
        echo -e "\e[32mКлонирование успешно завершено.\e[0m"
        sleep 2
    fi
    if [[ -d /opt/zapret/zapret.cfgs ]]; then
        echo "Проверяю наличие на обновление конфигураций..."
        manage_service stop
        cd /opt/zapret/zapret.cfgs && git fetch origin main; git reset --hard origin/main
        manage_service start
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

configure_custom_conf_path() {
    echo -e "\e[36mУкажите путь к стратегии. (Enter и пустой ввод для отмены)\e[0m"
    read -rp "Путь к стратегии (Пример: /home/user/folder/123): " CONFIG_PATH

    if [[ -z "$CONFIG_PATH" ]]; then
        main_menu
    fi

    if [[ ! -f "$CONFIG_PATH" ]]; then
        echo -e "\e[31mФайл не найден: $CONFIG_PATH\e[0m"
        sleep 2
        main_menu
    fi

    manage_service stop
    rm -f /opt/zapret/config
    cp -r -- "$CONFIG_PATH" /opt/zapret/config || error_exit "не удалось скопировать стратегию из указанного пути"
    get_fwtype
    sed -i "s/^FWTYPE=.*/FWTYPE=$FWTYPE/" /opt/zapret/config
    echo -e "\e[32mСтратегия установлена из: $CONFIG_PATH\e[0m"
    manage_service start
    sleep 2
    main_menu
}

configure_custom_list_path() {
    echo -e "\e[36mУкажите путь к хостлисту. (Enter и пустой ввод для отмены)\e[0m"
    read -rp "Путь к хостлисту: " LIST_PATH

    if [[ -z "$LIST_PATH" ]]; then
        main_menu
    fi

    if [[ ! -f "$LIST_PATH" ]]; then
        echo -e "\e[31mФайл не найден: $LIST_PATH\e[0m"
        sleep 2
        main_menu
    fi

    manage_service stop
    rm -f /opt/zapret/ipset/zapret-hosts-user.txt
    cp -r -- "$LIST_PATH" /opt/zapret/ipset/zapret-hosts-user.txt || error_exit "не удалось скопировать хостлист из указанного пути"
    echo -e "\e[32mХостлист установлен из: $LIST_PATH\e[0m"
    manage_service start
    sleep 2
    main_menu
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
        return
    fi

    echo
    echo "🔍 Результаты поиска по запросу: $keyword"
    echo "----------------------------------------"

    if grep -i --color=never -F "$keyword" "/opt/zapret/ipset/zapret-hosts-user.txt"; then
        echo "----------------------------------------"
        read -rp "Нажмите Enter для продолжения..."
    else
        echo "❌ Совпадений не найдено."
        echo "----------------------------------------"
        read -rp "Нажмите Enter для возврата в меню..."
    fi

    main_menu
}

auto_check_strategies() {
    local STRATS_DIR="/opt/zapret/zapret.cfgs/configurations"
    local CHECK_DOMAINS=("discord.com" "youtube.com" "rutracker.org")
    local SUMMARY=() 

    echo -e "\e[1;36m🚀 Начинаю перебирать стратегии...\e[0m"
    echo -e "\e[1;36mЭто может занять... какое-то время\e[0m"

    local files=($(ls "$STRATS_DIR"))

    for strat in "${files[@]}"; do
        echo -e "\n\e[1;33m🔍 Проверяю: $strat\e[0m"
        
        cp "$STRATS_DIR/$strat" /opt/zapret/config
        get_fwtype
        sed -i "s/^FWTYPE=.*/FWTYPE=$FWTYPE/" /opt/zapret/config

        manage_service restart > /dev/null 2>&1
        sleep 2

        local strat_works_for=""
        local success_count=0

        for domain in "${CHECK_DOMAINS[@]}"; do
            echo -n "   - $domain: "
            if curl -s -I -m 5 "https://$domain" > /dev/null 2>&1; then
                echo -e "\e[1;32mOK\e[0m"
                strat_works_for+="$domain "
                success_count=$((success_count + 1))
            else
                echo -e "\e[1;31mFAIL\e[0m"
            fi
        done

        if [ $success_count -gt 0 ]; then
            SUMMARY+=("\e[1;32m[+]\e[0m \e[1;37m$strat\e[0m: работает для -> \e[1;36m$strat_works_for\e[0m")
        else
            SUMMARY+=("\e[1;31m[-]\e[0m \e[1;30m$strat\e[0m: ничего не пробила")
        fi
    done

    clear
    echo -e "\e[1;36m╔══════════════════════════════════════════════╗"
    echo -e "║          📊 ИТОГИ АВТОПОДБОРА                ║"
    echo -e "╚══════════════════════════════════════════════╝\e[0m"
    
    for line in "${SUMMARY[@]}"; do
        echo -e "$line"
    done
    
    read -rp "Нажмите Enter для возврата в меню..."
    main_menu
}