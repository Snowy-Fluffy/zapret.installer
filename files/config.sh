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
game_mode_check() {
    if [ ! -f "/opt/zapret/ipset/ipset-game.txt" ]; then
        touch /opt/zapret/ipset/ipset-game.txt || error_exit "не удалось создать ipset для игрвого режима"
    fi
    
    if grep -q "^0\.0\.0\.0/0$" /opt/zapret/ipset/ipset-game.txt; then
        game_mode_status="включен"
    else
        game_mode_status="выключен"
    fi
}

toggle_game_mode() {
    game_mode_check
    
    if [[ $game_mode_status == "включен" ]]; then
        rm -f /opt/zapret/ipset/ipset-game.txt
        touch /opt/zapret/ipset/ipset-game.txt || error_exit "не удалось создать ipset для игрвого режима"
        echo "203.0.113.77" >> /opt/zapret/ipset/ipset-game.txt
    else
        rm -f /opt/zapret/ipset/ipset-game.txt
        touch /opt/zapret/ipset/ipset-game.txt || error_exit "не удалось создать ipset для игрвого режима"
        echo "0.0.0.0/0" >> /opt/zapret/ipset/ipset-game.txt
    fi
    manage_service restart
    sleep 2
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

test_domain() {
    local domain="$1"
    local results=()
    domain=$(echo "$domain" | sed 's/#.*//' | xargs)
    [[ -z "$domain" ]] && return
    if [[ "$domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ping_result=$(ping -c 2 -W 2 "$domain" 2>/dev/null | grep -E "rtt min/avg/max/mdev" | awk -F'/' '{print $5}')
        if [[ -n "$ping_result" ]]; then
            results=("${ping_result}ms" "N/A" "N/A" "N/A")
        else
            results=("FAIL" "N/A" "N/A" "N/A")
        fi
    else
        ping_result=$(ping -c 2 -W 2 "$domain" 2>/dev/null | grep -E "rtt min/avg/max/mdev" | awk -F'/' '{print $5}')
        if [[ -n "$ping_result" ]]; then
            results+=("${ping_result}ms")
        else
            results+=("FAIL")
        fi
        http_result=$(timeout 5 curl -s -o /dev/null -w "%{http_code}" "http://$domain" 2>/dev/null || echo "FAIL")
        if [[ "$http_result" =~ ^[0-9]+$ ]]; then
            results+=("HTTP:$http_result")
        else
            results+=("FAIL")
        fi
        tls12_result=$(timeout 5 curl -s -o /dev/null -w "%{http_code}" --tlsv1.2 "https://$domain" 2>/dev/null || echo "FAIL")
        if [[ "$tls12_result" =~ ^[0-9]+$ ]]; then
            results+=("TLS1.2:$tls12_result")
        else
            results+=("FAIL")
        fi
        tls13_result=$(timeout 5 curl -s -o /dev/null -w "%{http_code}" --tlsv1.3 "https://$domain" 2>/dev/null || echo "FAIL")
        if [[ "$tls13_result" =~ ^[0-9]+$ ]]; then
            results+=("TLS1.3:$tls13_result")
        else
            results+=("FAIL")
        fi
    fi
    echo "${results[@]}"
}

print_table_header() {
    echo "┌─────────────────────────────────────────────────────────────────────────────┐"
    printf "│ %-30s │ %-8s │ %-10s │ %-10s │ %-10s │\n" "Домен/IP" "Ping" "HTTP" "TLS1.2" "TLS1.3"
    echo "├─────────────────────────────────────────────────────────────────────────────┤"
}

print_table_row() {
    local domain="$1"
    local ping="$2"
    local http="$3"
    local tls12="$4"
    local tls13="$5"
    local display_domain="$domain"
    if [[ ${#domain} -gt 30 ]]; then
        display_domain="${domain:0:27}..."
    fi
    printf "│ %-30s  %-8s  %-10s  %-10s  %-10s \n" "$display_domain" "$ping" "$http" "$tls12" "$tls13"
}

test_all_domains() {
    local config_name="$1"
    local list_path="$2"
    local total=0
    local available=0
    echo "┌─────────────────────────────────────────────────────────────────────────────┐"
    echo "│ Стратегия: $config_name"
    echo "├─────────────────────────────────────────────────────────────────────────────┤"
    print_table_header
    local results_lines=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=$(echo "$line" | sed 's/#.*//' | xargs)
        [[ -z "$line" ]] && continue
        total=$((total + 1))
        results=($(test_domain "$line"))
        local is_available=0
        if [[ "${results[0]}" != "FAIL" ]] && \
           ([[ "${results[2]}" =~ ^TLS1\.2:[23] ]] || [[ "${results[3]}" =~ ^TLS1\.3:[23] ]]); then
            available=$((available + 1))
            is_available=1
        fi
        results_lines+=("$line|${results[0]}|${results[1]}|${results[2]}|${results[3]}|$is_available")
    done < "$list_path"
    for line_info in "${results_lines[@]}"; do
        IFS='|' read -r domain ping http tls12 tls13 is_available <<< "$line_info"
        print_table_row "$domain" "$ping" "$http" "$tls12" "$tls13"
    done
    echo "├─────────────────────────────────────────────────────────────────────────────┤"
    printf "│ Доступно: %d/%d доменов/IP                                           │\n" "$available" "$total"
    echo "└─────────────────────────────────────────────────────────────────────────────┘"
    echo ""
    echo "$available"
}

apply_config() {
    local config="$1"
    echo -e "\e[33mПрименяем стратегию: $config\e[0m"
    CONFIG_PATH="/opt/zapret/zapret.cfgs/configurations/$config"
    if [[ ! -f "$CONFIG_PATH" ]]; then
        echo -e "\e[31mФайл конфигурации не найден: $CONFIG_PATH\e[0m"
    fi
    rm -f /opt/zapret/config
    cp "$CONFIG_PATH" /opt/zapret/config || error_exit "не удалось скопировать стратегию"
    get_fwtype
    sed -i "s/^FWTYPE=.*/FWTYPE=$FWTYPE/" /opt/zapret/config
    manage_service restart
}

check_conf() {
    echo -e "\e[36mВыберите хостлист для тестирования (можно поменять в любой момент, запустив Меню управления запретом еще раз):\e[0m"
    PS3="Введите номер листа (по умолчанию для тестирования 'list-simple.txt'): "

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
    check_list
    echo -e "\e[36mНачинаем проверку всех стратегий...\e[0m"
    echo -e "\e[33mВсего стратегий: ${#configs[@]}\e[0m"
    echo ""
    stats_file="/tmp/zapret_final_stats_$$.txt"
    > "$stats_file"
    local best_config=""
    local best_available=0
    local total_domains=0
    total_domains=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=$(echo "$line" | sed 's/#.*//' | xargs)
        [[ -n "$line" ]] && total_domains=$((total_domains + 1))
    done < "$LIST_PATH"
    for config in "${configs[@]}"; do
        echo "──────────────────────────────────────────────────────────────────────────────"
        echo ""
        if ! apply_config "$config"; then
            echo -e "\e[31mНе удалось применить стратегию: $config\e[0m"
            echo ""
            continue
        fi
        available=$(test_all_domains "$config" "$LIST_PATH" | tee /dev/tty | tail -1)
        if [[ "$available" =~ ^[0-9]+$ ]]; then
            echo "$config $available" >> "$stats_file"
            if [[ $available -gt $best_available ]]; then
                best_available=$available
                best_config="$config"
            fi
        else
            echo -e "\e[31mОшибка при тестировании стратегии: $config\e[0m"
        fi
    done
    echo ""
    echo -e "\e[42m\e[30m╔══════════════════════════════════════════════════════════════════════════╗\e[0m"
    echo -e "\e[42m\e[30m║                           ИТОГОВЫЙ РЕЗУЛЬТАТ                             ║\e[0m"
    echo -e "\e[42m\e[30m╠══════════════════════════════════════════════════════════════════════════╣\e[0m"
    echo -e "\e[42m\e[30m║                                                                          ║\e[0m"
    printf "\e[42m\e[30m║  Лучшая стратегия: %-52s ║\n\e[0m" "$best_config"
    printf "\e[42m\e[30m║  Доступно доменов/IP: %-3d из %-3d (%.1f%%)                  ║\n\e[0m" "$best_available" "$total_domains" $(echo "scale=1; $best_available * 100 / $total_domains" | bc)
    echo -e "\e[42m\e[30m║                                                                          ║\e[0m"
    echo -e "\e[42m\e[30m╚══════════════════════════════════════════════════════════════════════════╝\e[0m"
    echo ""
    echo -e "\e[33mПрименяем лучшую стратегию: $best_config\e[0m"
    apply_config "$best_config"
    if [[ -f "$stats_file" ]] && [[ $(wc -l < "$stats_file") -gt 0 ]]; then
        echo ""
        echo -e "\e[36mСтатистика по всем стратегиям:\e[0m"
        echo "┌──────────────────────────────────────────────────────┐"
        printf "│ %-30s │ %-10s │ %-6s │\n" "Стратегия" "Доступно" "%"
        echo "├──────────────────────────────────────────────────────┤"
        while read -r line; do
            read -r config count <<< "$line"
            if [[ "$count" =~ ^[0-9]+$ ]] && [[ $total_domains -gt 0 ]]; then
                percentage=$(echo "scale=1; $count * 100 / $total_domains" | bc)
                printf "│ %-30s │ %-10s │ %-5s%% │\n" "$config" "$count/$total_domains" "$percentage"
            fi
        done < "$stats_file"
        echo "└──────────────────────────────────────────────────────┘"
    fi
    rm -f "$stats_file"
    return 0
}
check_list() {

    LINE_COUNT=$(wc -l < "/opt/zapret/ipset/zapret-hosts-user.txt" 2>/dev/null || echo "0")
    if [ "$LINE_COUNT" = "0" ] && [ -s "/opt/zapret/ipset/zapret-hosts-user.txt" ]; then
        LINE_COUNT=$(awk 'END{print NR}' "/opt/zapret/ipset/zapret-hosts-user.txt" 2>/dev/null || echo "0")
    fi

    if ! [[ "$LINE_COUNT" =~ ^[0-9]+$ ]]; then
        echo "Ошибка: Не удалось подсчитать строки в файле"
        exit 1
    fi

    echo "В выбраном листе $LINE_COUNT доменов/айпи."

    if [ "$LINE_COUNT" -gt 100 ]; then
        echo "Проверка может занять *ОЧЕНЬ* много времени!"
        
        echo ""
        read -p "Нажмите Enter для продолжения или Ctrl+C для отмены... "
    fi
}
check_conf_simple() {
    rm -f /opt/zapret/ipset/zapret-hosts-user.txt
    cp -r /opt/zapret/zapret.cfgs/lists/list-simple.txt /opt/zapret/ipset/zapret-hosts-user.txt
    check_list
    echo -e "\e[36mНачинаем проверку всех стратегий...\e[0m"
    echo -e "\e[33mВсего стратегий: ${#configs[@]}\e[0m"
    echo ""
    stats_file="/tmp/zapret_final_stats_$$.txt"
    > "$stats_file"
    local best_config=""
    local best_available=0
    local total_domains=0
    total_domains=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=$(echo "$line" | sed 's/#.*//' | xargs)
        [[ -n "$line" ]] && total_domains=$((total_domains + 1))
    done < "$LIST_PATH"
    for config in "${configs[@]}"; do
        echo "──────────────────────────────────────────────────────────────────────────────"
        echo ""
        if ! apply_config "$config"; then
            echo -e "\e[31mНе удалось применить стратегию: $config\e[0m"
            echo ""
            continue
        fi
        available=$(test_all_domains "$config" "$LIST_PATH" | tee /dev/tty | tail -1)
        if [[ "$available" =~ ^[0-9]+$ ]]; then
            echo "$config $available" >> "$stats_file"
            if [[ $available -gt $best_available ]]; then
                best_available=$available
                best_config="$config"
            fi
        else
            echo -e "\e[31mОшибка при тестировании стратегии: $config\e[0m"
        fi
    done
    echo ""
    echo -e "\e[42m\e[30m╔══════════════════════════════════════════════════════════════════════════╗\e[0m"
    echo -e "\e[42m\e[30m║                           ИТОГОВЫЙ РЕЗУЛЬТАТ                             ║\e[0m"
    echo -e "\e[42m\e[30m╠══════════════════════════════════════════════════════════════════════════╣\e[0m"
    echo -e "\e[42m\e[30m║                                                                          ║\e[0m"
    printf "\e[42m\e[30m║  Лучшая стратегия: %-52s ║\n\e[0m" "$best_config"
    printf "\e[42m\e[30m║  Доступно доменов/IP: %-3d из %-3d (%.1f%%)                  ║\n\e[0m" "$best_available" "$total_domains" $(echo "scale=1; $best_available * 100 / $total_domains" | bc)
    echo -e "\e[42m\e[30m║                                                                          ║\e[0m"
    echo -e "\e[42m\e[30m╚══════════════════════════════════════════════════════════════════════════╝\e[0m"
    echo ""
    echo -e "\e[33mПрименяем лучшую стратегию: $best_config\e[0m"
    apply_config "$best_config"
    if [[ -f "$stats_file" ]] && [[ $(wc -l < "$stats_file") -gt 0 ]]; then
        echo ""
        echo -e "\e[36mСтатистика по всем стратегиям:\e[0m"
        echo "┌──────────────────────────────────────────────────────┐"
        printf "│ %-30s │ %-10s │ %-6s │\n" "Стратегия" "Доступно" "%"
        echo "├──────────────────────────────────────────────────────┤"
        while read -r line; do
            read -r config count <<< "$line"
            if [[ "$count" =~ ^[0-9]+$ ]] && [[ $total_domains -gt 0 ]]; then
                percentage=$(echo "scale=1; $count * 100 / $total_domains" | bc)
                printf "│ %-30s │ %-10s │ %-5s%% │\n" "$config" "$count/$total_domains" "$percentage"
            fi
        done < "$stats_file"
        echo "└──────────────────────────────────────────────────────┘"
    fi
    rm -f "$stats_file"
    return 0
}
