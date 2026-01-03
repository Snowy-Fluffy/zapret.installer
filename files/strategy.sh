#!/bin/bash

STRATEGY_TEST_DIR=""
STRATEGY_TEST_PIDS=()
STRATEGY_TEST_RUNNING=false
STRATEGY_ORIGINAL_CONFIG=""
STRATEGY_CONFIGS_DIR="/opt/zapret/zapret.cfgs/configurations"
MAX_PARALLEL_TESTS=16
CURL_TIMEOUT=3

strategy_cleanup() {
    STRATEGY_TEST_RUNNING=false

    for pid in "${STRATEGY_TEST_PIDS[@]}"; do
        kill -TERM "$pid" 2>/dev/null
        kill -9 "$pid" 2>/dev/null
    done
    STRATEGY_TEST_PIDS=()

    if [[ -n "$STRATEGY_TEST_DIR" && -d "$STRATEGY_TEST_DIR" ]]; then
        rm -rf "$STRATEGY_TEST_DIR"
        STRATEGY_TEST_DIR=""
    fi

    if [[ -n "$STRATEGY_ORIGINAL_CONFIG" && -f "$STRATEGY_ORIGINAL_CONFIG" ]]; then
        cp "$STRATEGY_ORIGINAL_CONFIG" /opt/zapret/config 2>/dev/null
        STRATEGY_ORIGINAL_CONFIG=""
    fi
}

strategy_signal_handler() {
    echo ""
    echo -e "\e[33mПрерывание тестирования...\e[0m"
    strategy_cleanup
    manage_service restart 2>/dev/null || true
    main_menu
}

strategy_init() {
    set +e
    trap strategy_signal_handler SIGINT SIGTERM
    STRATEGY_TEST_RUNNING=true
    STRATEGY_TEST_DIR=$(mktemp -d)
    mkdir -p "$STRATEGY_TEST_DIR/results"
}

strategy_finish() {
    trap - SIGINT SIGTERM
    STRATEGY_TEST_RUNNING=false
    [[ -n "$STRATEGY_TEST_DIR" && -d "$STRATEGY_TEST_DIR" ]] && rm -rf "$STRATEGY_TEST_DIR"
    STRATEGY_TEST_DIR=""
    STRATEGY_ORIGINAL_CONFIG=""
    echo ""
    read -rp "Нажмите Enter для возврата в меню..."
    main_menu
}

ensure_configs_repo() {
    if [[ ! -d /opt/zapret/zapret.cfgs ]]; then
        echo -e "\e[35mКлонирую конфигурации...\e[0m"
        git clone https://github.com/Snowy-Fluffy/zapret.cfgs /opt/zapret/zapret.cfgs 2>/dev/null || true
    fi

    if [[ -d /opt/zapret/zapret.cfgs ]]; then
        cd /opt/zapret/zapret.cfgs && git fetch origin main 2>/dev/null && git reset --hard origin/main 2>/dev/null || true
    fi
}

load_configs_list() {
    local configs=()
    if [[ -d "$STRATEGY_CONFIGS_DIR" ]]; then
        while IFS= read -r -d '' file; do
            configs+=("$(basename "$file")")
        done < <(find "$STRATEGY_CONFIGS_DIR" -maxdepth 1 -type f -print0 | sort -z)
    fi
    printf '%s\n' "${configs[@]}"
}

get_default_targets() {
    cat << 'EOF'
Discord_Main=https://discord.com
Discord_Gateway=https://gateway.discord.gg
Discord_CDN=https://cdn.discordapp.com
YouTube_Web=https://www.youtube.com
YouTube_Short=https://youtu.be
Google_Main=https://www.google.com
Google_DNS=https://dns.google
Cloudflare_Web=https://www.cloudflare.com
Cloudflare_DNS=https://1.1.1.1
EOF
}

load_targets() {
    local targets_file="/opt/zapret/zapret.cfgs/targets.txt"
    if [[ -f "$targets_file" ]]; then
        cat "$targets_file"
    else
        get_default_targets
    fi
}

get_result_color() {
    case "$1" in
        OK|2*|3*|4*|5*) echo "32" ;;
        FAIL)           echo "31" ;;
        SKIP|--)        echo "90" ;;
        *)              echo "32" ;;
    esac
}

do_curl_test() {
    local url="$1" test_type="$2" timeout="$3" result_file="$4"
    local http_code

    case "$test_type" in
        http)  http_code=$(timeout "$timeout" curl -s -o /dev/null -w "%{http_code}" --http1.1 "$url" 2>/dev/null) ;;
        tls12) http_code=$(timeout "$timeout" curl -s -o /dev/null -w "%{http_code}" --tlsv1.2 --tls-max 1.2 "$url" 2>/dev/null) ;;
        tls13) http_code=$(timeout "$timeout" curl -s -o /dev/null -w "%{http_code}" --tlsv1.3 --tls-max 1.3 "$url" 2>/dev/null) ;;
    esac

    if [[ "$http_code" =~ ^[23] ]]; then
        echo "OK"
    elif [[ -n "$http_code" && "$http_code" != "000" ]]; then
        echo "$http_code"
    else
        echo "FAIL"
    fi > "$result_file"
}

do_ping_test() {
    local target="$1" result_file="$2"
    local output ms

    output=$(ping -c 1 -W 2 "$target" 2>/dev/null)

    if [[ "$output" =~ time=([0-9.]+) ]]; then
        echo "${BASH_REMATCH[1]}ms"
    elif [[ -n "$output" ]]; then
        echo "OK"
    else
        echo "FAIL"
    fi > "$result_file"
}

test_single_target() {
    local name="$1" value="$2" output_file="$3"
    local tmp_dir pids=() ping_target=""
    local http="--" tls12="--" tls13="--" ping="--"

    tmp_dir=$(mktemp -d)

    if [[ "$value" != PING:* ]]; then
        ping_target=$(echo "$value" | sed 's|^https\?://||;s|/.*$||')
        do_curl_test "$value" "http" "$CURL_TIMEOUT" "$tmp_dir/http" & pids+=($!)
        do_curl_test "$value" "tls12" "$CURL_TIMEOUT" "$tmp_dir/tls12" & pids+=($!)
        do_curl_test "$value" "tls13" "$CURL_TIMEOUT" "$tmp_dir/tls13" & pids+=($!)
    else
        ping_target="${value#PING:}"
    fi

    [[ -n "$ping_target" ]] && { do_ping_test "$ping_target" "$tmp_dir/ping" & pids+=($!); }

    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done

    [[ -f "$tmp_dir/http" ]] && http=$(cat "$tmp_dir/http")
    [[ -f "$tmp_dir/tls12" ]] && tls12=$(cat "$tmp_dir/tls12")
    [[ -f "$tmp_dir/tls13" ]] && tls13=$(cat "$tmp_dir/tls13")
    [[ -f "$tmp_dir/ping" ]] && ping=$(cat "$tmp_dir/ping")

    rm -rf "$tmp_dir"
    echo "$name|$http|$tls12|$tls13|$ping" >> "$output_file"
}

run_parallel_tests() {
    local output_file="$1"
    local running_pids=()

    > "$output_file"

    while IFS='=' read -r name value; do
        [[ -z "$name" || "$name" == \#* ]] && continue
        name=${name// /}
        value=${value// /}

        while [[ ${#running_pids[@]} -ge $MAX_PARALLEL_TESTS ]]; do
            local new_pids=()
            for pid in "${running_pids[@]}"; do
                kill -0 "$pid" 2>/dev/null && new_pids+=("$pid")
            done
            running_pids=("${new_pids[@]}")
            [[ ${#running_pids[@]} -ge $MAX_PARALLEL_TESTS ]] && sleep 0.1
        done

        test_single_target "$name" "$value" "$output_file" &
        running_pids+=($!)
        STRATEGY_TEST_PIDS+=($!)
    done <<< "$(load_targets)"

    for pid in "${running_pids[@]}"; do wait "$pid" 2>/dev/null || true; done
}

calculate_score() {
    local results_file="$1"
    local ok=0 fail=0 ping_ok=0

    while IFS='|' read -r _ http tls12 tls13 ping; do
        for val in "$http" "$tls12" "$tls13"; do
            case "$val" in
                FAIL) ((fail++)) ;;
                SKIP|--) ;;
                *) ((ok++)) ;;
            esac
        done
        [[ "$ping" != "FAIL" && "$ping" != "SKIP" && "$ping" != "--" ]] && ((ping_ok++))
    done < "$results_file"

    echo "$ok $fail $ping_ok"
}

print_test_results() {
    local results_file="$1"
    local E=$'\e'

    echo "┌──────────────────────┬────────┬─────────┬─────────┬──────────┐"
    echo "│ Target               │ HTTP   │ TLS1.2  │ TLS1.3  │ Ping     │"
    echo "├──────────────────────┼────────┼─────────┼─────────┼──────────┤"

    while IFS='|' read -r name http tls12 tls13 ping; do
        [[ -z "$name" ]] && continue
        [[ ${#name} -gt 20 ]] && name="${name:0:17}..."

        printf "│ %-20s │ ${E}[%sm%-6s${E}[0m │ ${E}[%sm%-7s${E}[0m │ ${E}[%sm%-7s${E}[0m │ ${E}[%sm%-8s${E}[0m │\n" \
            "$name" \
            "$(get_result_color "$http")" "$http" \
            "$(get_result_color "$tls12")" "$tls12" \
            "$(get_result_color "$tls13")" "$tls13" \
            "$(get_result_color "$ping")" "$ping"
    done < "$results_file"

    echo "└──────────────────────┴────────┴─────────┴─────────┴──────────┘"
}

print_score() {
    local results_file="$1"
    read -r ok fail ping_ok <<< "$(calculate_score "$results_file")"
    echo -e "\e[36mРезультат: \e[32mOK:$ok\e[0m \e[31mFAIL:$fail\e[0m \e[36mPING:$ping_ok\e[0m"
}

apply_strategy() {
    local config_path="$1"

    [[ ! -f "$config_path" ]] && return 1

    cp "$config_path" /opt/zapret/config 2>/dev/null || return 1
    get_fwtype 2>/dev/null || true
    sed -i "s/^FWTYPE=.*/FWTYPE=$FWTYPE/" /opt/zapret/config 2>/dev/null || true
    manage_service restart >/dev/null 2>&1 || true
    sleep 3
    return 0
}

backup_current_config() {
    if [[ -f /opt/zapret/config ]]; then
        STRATEGY_ORIGINAL_CONFIG="$STRATEGY_TEST_DIR/original_config"
        cp /opt/zapret/config "$STRATEGY_ORIGINAL_CONFIG"
    fi
}

select_strategies() {
    local -n configs_ref=$1
    local -n selected_ref=$2

    echo -e "\e[36mДоступные стратегии:\e[0m"
    for i in "${!configs_ref[@]}"; do
        printf "  %2d. %s\n" $((i+1)) "${configs_ref[$i]}"
    done
    echo ""

    echo -e "\e[33mВыберите режим:\e[0m"
    echo -e "  \e[32mEnter\e[0m - проверить все"
    echo -e "  \e[32m+\e[0m     - белый список (только указанные)"
    echo -e "  \e[32m-\e[0m     - чёрный список (исключить указанные)"
    echo ""
    read -rp $'\e[1;36mВаш выбор: \e[0m' input

    selected_ref=()

    case "$input" in
        "")
            selected_ref=("${configs_ref[@]}")
            ;;
        +*)
            local nums="${input#+}"
            [[ -z "$nums" ]] && read -rp $'\e[33mНомера для проверки: \e[0m' nums
            for n in $nums; do
                [[ "$n" =~ ^[0-9]+$ ]] && ((n > 0 && n <= ${#configs_ref[@]})) && selected_ref+=("${configs_ref[$((n-1))]}")
            done
            ;;
        -*)
            local nums="${input#-}" excluded=()
            [[ -z "$nums" ]] && read -rp $'\e[33mНомера для исключения: \e[0m' nums
            for n in $nums; do
                [[ "$n" =~ ^[0-9]+$ ]] && ((n > 0 && n <= ${#configs_ref[@]})) && excluded+=("${configs_ref[$((n-1))]}")
            done
            for cfg in "${configs_ref[@]}"; do
                local skip=false
                for ex in "${excluded[@]}"; do [[ "$cfg" == "$ex" ]] && skip=true && break; done
                $skip || selected_ref+=("$cfg")
            done
            ;;
        *)
            if [[ "$input" =~ ^[0-9\ ]+$ ]]; then
                for n in $input; do
                    [[ "$n" =~ ^[0-9]+$ ]] && ((n > 0 && n <= ${#configs_ref[@]})) && selected_ref+=("${configs_ref[$((n-1))]}")
                done
            else
                selected_ref=("${configs_ref[@]}")
            fi
            ;;
    esac
}

auto_select_strategy() {
    strategy_init
    ensure_configs_repo

    clear
    echo -e "\e[1;36m╔════════════════════════════════════════════════════════════════╗"
    echo -e "║            Автоматический подбор стратегии                    ║"
    echo -e "╚════════════════════════════════════════════════════════════════╝\e[0m"
    echo ""

    backup_current_config

    if [[ ! -d "$STRATEGY_CONFIGS_DIR" ]]; then
        echo -e "\e[31mДиректория с конфигурациями не найдена\e[0m"
        strategy_finish
        return
    fi

    local configs=() selected=()
    mapfile -t configs < <(load_configs_list)

    if [[ ${#configs[@]} -eq 0 ]]; then
        echo -e "\e[31mНе найдено стратегий\e[0m"
        strategy_finish
        return
    fi

    select_strategies configs selected

    if [[ ${#selected[@]} -eq 0 ]]; then
        echo -e "\e[31mНе выбрано ни одной стратегии\e[0m"
        strategy_finish
        return
    fi

    echo ""
    echo -e "\e[36mБудет протестировано: ${#selected[@]}\e[0m"
    echo -e "\e[33mНажмите Ctrl+C для отмены\e[0m"
    sleep 2

    local best_config="" best_score=0 best_ping=0
    local num=0 total=${#selected[@]}
    declare -A scores

    for config in "${selected[@]}"; do
        [[ "$STRATEGY_TEST_RUNNING" != "true" ]] && break
        ((num++))

        echo ""
        echo -e "\e[1;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m"
        echo -e "\e[1;36m[$num/$total] $config\e[0m"
        echo -e "\e[1;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m"

        echo -e "\e[35mПрименяю стратегию...\e[0m"
        if ! apply_strategy "$STRATEGY_CONFIGS_DIR/$config"; then
            echo -e "\e[31mОшибка применения\e[0m"
            continue
        fi

        echo -e "\e[35mТестирую...\e[0m"
        local results_file="$STRATEGY_TEST_DIR/results/${config//[ ]/_}.results"
        run_parallel_tests "$results_file"

        if [[ -f "$results_file" ]]; then
            print_test_results "$results_file"

            read -r ok fail ping_ok <<< "$(calculate_score "$results_file")"
            scores["$config"]="OK:$ok FAIL:$fail PING:$ping_ok"

            echo ""
            echo -e "\e[36mРезультат: \e[32mOK:$ok\e[0m \e[31mFAIL:$fail\e[0m \e[36mPING:$ping_ok\e[0m"

            if ((ok > best_score)) || ((ok == best_score && ping_ok > best_ping)); then
                best_score=$ok
                best_ping=$ping_ok
                best_config="$config"
            fi
        fi
    done

    echo ""
    echo -e "\e[1;42;30m╔════════════════════════════════════════════════════════════════╗\e[0m"
    echo -e "\e[1;42;30m║                      ИТОГОВЫЙ РЕЗУЛЬТАТ                        ║\e[0m"
    echo -e "\e[1;42;30m╠════════════════════════════════════════════════════════════════╣\e[0m"
    if [[ -n "$best_config" ]]; then
        printf "\e[1;42;30m║  Лучшая: %-53s  ║\e[0m\n" "$best_config"
        printf "\e[1;42;30m║  Счёт: OK=%d PING=%d%-43s║\e[0m\n" "$best_score" "$best_ping" ""
    else
        echo -e "\e[1;42;30m║  Не удалось определить лучшую стратегию                        ║\e[0m"
    fi
    echo -e "\e[1;42;30m╚════════════════════════════════════════════════════════════════╝\e[0m"

    if [[ ${#scores[@]} -gt 1 ]]; then
        echo ""
        echo -e "\e[36mВсе результаты:\e[0m"
        for cfg in "${!scores[@]}"; do
            printf "  %-40s %s\n" "${cfg:0:40}" "${scores[$cfg]}"
        done
    fi

    if [[ -n "$best_config" ]]; then
        echo ""
        echo -e "\e[33mПрименяю лучшую стратегию...\e[0m"
        apply_strategy "$STRATEGY_CONFIGS_DIR/$best_config"
        echo -e "\e[32mГотово: $best_config\e[0m"
    fi

    STRATEGY_ORIGINAL_CONFIG=""
    strategy_finish
}

quick_test_current() {
    strategy_init

    clear
    echo -e "\e[1;36m╔════════════════════════════════════════════════════════════════╗"
    echo -e "║           Тестирование текущей стратегии                       ║"
    echo -e "╚════════════════════════════════════════════════════════════════╝\e[0m"
    echo ""

    cur_conf 2>/dev/null || true
    echo -e "\e[33mТекущая: \e[36m$cr_cnf\e[0m"
    echo ""

    echo -e "\e[35mТестирую...\e[0m"
    local results_file="$STRATEGY_TEST_DIR/results/current.results"
    run_parallel_tests "$results_file"

    if [[ -f "$results_file" ]]; then
        echo ""
        print_test_results "$results_file"
        echo ""
        print_score "$results_file"
    fi

    strategy_finish
}

test_single_strategy_menu() {
    strategy_init
    ensure_configs_repo

    clear
    echo -e "\e[1;36m╔════════════════════════════════════════════════════════════════╗"
    echo -e "║            Тестирование отдельной стратегии                    ║"
    echo -e "╚════════════════════════════════════════════════════════════════╝\e[0m"
    echo ""

    local configs=()
    mapfile -t configs < <(load_configs_list)

    if [[ ${#configs[@]} -eq 0 ]]; then
        echo -e "\e[31mНе найдено стратегий\e[0m"
        strategy_finish
        return
    fi

    echo -e "\e[36mВыберите стратегию:\e[0m"
    for i in "${!configs[@]}"; do
        printf "  %2d. %s\n" $((i+1)) "${configs[$i]}"
    done
    echo "   0. Отмена"
    echo ""

    read -rp "Номер: " choice

    if [[ -z "$choice" || "$choice" == "0" ]] || ! [[ "$choice" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#configs[@]})); then
        strategy_finish
        return
    fi

    local selected="${configs[$((choice-1))]}"
    backup_current_config

    echo ""
    echo -e "\e[35mПрименяю: $selected\e[0m"

    if ! apply_strategy "$STRATEGY_CONFIGS_DIR/$selected"; then
        echo -e "\e[31mОшибка применения\e[0m"
        strategy_cleanup
        strategy_finish
        return
    fi

    echo -e "\e[35mТестирую...\e[0m"
    local results_file="$STRATEGY_TEST_DIR/results/test.results"
    run_parallel_tests "$results_file"

    if [[ -f "$results_file" ]]; then
        echo ""
        print_test_results "$results_file"
        echo ""
        print_score "$results_file"
    fi

    echo ""
    read -rp "Применить эту стратегию? (y/N): " answer

    if [[ "$answer" =~ ^[Yy]$ ]]; then
        echo -e "\e[32mСтратегия применена\e[0m"
        STRATEGY_ORIGINAL_CONFIG=""
    else
        strategy_cleanup
        manage_service restart >/dev/null 2>&1 || true
        echo -e "\e[33mВосстановлена предыдущая стратегия\e[0m"
    fi

    strategy_finish
}

strategy_menu() {
    set +e
    while true; do
        clear
        cur_conf 2>/dev/null || true

        echo -e "\e[1;36m╔════════════════════════════════════════════════════════════════╗"
        echo -e "║              Подбор и тестирование стратегий                   ║"
        echo -e "╚════════════════════════════════════════════════════════════════╝\e[0m"
        echo -e "  \e[33mТекущая:\e[0m \e[32m$cr_cnf\e[0m"
        echo ""
        echo -e "  \e[31m0)\e[0m Назад"
        echo -e "  \e[34m1)\e[0m Тест текущей стратегии"
        echo -e "  \e[34m2)\e[0m Тест отдельной стратегии"
        echo -e "  \e[32m3)\e[0m Автоподбор лучшей"
        echo -e "  \e[34m4)\e[0m Выбрать вручную"
        echo ""

        read -rp $'\e[1;36mВыбор: \e[0m' choice

        case "$choice" in
            0) main_menu ;;
            1) quick_test_current ;;
            2) test_single_strategy_menu ;;
            3) auto_select_strategy ;;
            4) configure_zapret_conf ;;
            *) echo -e "\e[31mНеверный ввод\e[0m"; sleep 1 ;;
        esac
    done
}
