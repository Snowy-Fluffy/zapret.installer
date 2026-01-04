#!/bin/bash

STRATEGY_TEST_DIR=""
STRATEGY_TEST_RUNNING=false
STRATEGY_ORIGINAL_CONFIG=""
STRATEGY_CONFIGS_DIR="/opt/zapret/zapret.cfgs/configurations"
STRATEGY_TARGETS_DIR="/opt/zapret/zapret.cfgs/lists"
STRATEGY_SELECTED_TARGETS=()
STRATEGY_BEST_SCORE=0
BATCH_SIZE=10000

CURL_TIMEOUT=3

strategy_auto_tune() {
    local hard_limit=$(ulimit -Hn 2>/dev/null || echo 1024)
    local current_limit=$(ulimit -n 2>/dev/null || echo 1024)

    local available_fd=$((current_limit > hard_limit ? hard_limit : current_limit))
    local fd_based=$((available_fd / 8))

    MAX_PARALLEL=$fd_based
    ((MAX_PARALLEL > 1000)) && MAX_PARALLEL=1000
    ((MAX_PARALLEL < 500)) && MAX_PARALLEL=500

    REQUIRED_NOFILE=$((MAX_PARALLEL * 8))
    ((REQUIRED_NOFILE < 65536)) && REQUIRED_NOFILE=65536
}

strategy_calibrate() {
    local sample_file="$1"
    local sample_count=$(wc -l < "$sample_file" 2>/dev/null || echo 0)
    ((sample_count < 50)) && return 0

    local tmp_config=$(mktemp)
    local tmp_output=$(mktemp)

    awk '{
        print "url = " $0
        print "output = /dev/null"
        print "write-out = %{http_code}\\n"
        print "silent"
        print "head"
        print "connect-timeout = 2"
        print "max-time = 2"
        print ""
    }' "$sample_file" > "$tmp_config"

    local start_ms=$(date +%s%3N)
    timeout 15 curl --parallel --parallel-max 1000 --parallel-immediate \
        --config "$tmp_config" > "$tmp_output" 2>/dev/null || true
    local end_ms=$(date +%s%3N)

    local duration_ms=$((end_ms - start_ms))
    local success_count=$(grep -cE '^[23][0-9][0-9]$' "$tmp_output" 2>/dev/null || echo 0)

    rm -f "$tmp_config" "$tmp_output"

    if ((success_count < 10)) || ((duration_ms < 500)); then
        MAX_PARALLEL=1000
    elif ((duration_ms > 10000)); then
        MAX_PARALLEL=500
    else
        MAX_PARALLEL=750
    fi

    export MAX_PARALLEL
}

strategy_auto_tune

export MAX_PARALLEL CURL_TIMEOUT

STRATEGY_ORIG_ULIMIT=""
STRATEGY_ORIG_CONNTRACK=""
STRATEGY_ORIG_SOMAXCONN=""
STRATEGY_SYSTEM_TUNED=false

strategy_tune_system() {
    [[ "$STRATEGY_SYSTEM_TUNED" == "true" ]] && return 0

    STRATEGY_ORIG_ULIMIT=$(ulimit -n 2>/dev/null)

    if [[ -f /proc/sys/net/netfilter/nf_conntrack_max ]]; then
        STRATEGY_ORIG_CONNTRACK=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)
    fi

    if [[ -f /proc/sys/net/core/somaxconn ]]; then
        STRATEGY_ORIG_SOMAXCONN=$(cat /proc/sys/net/core/somaxconn 2>/dev/null)
    fi

    local current_ulimit=$(ulimit -n 2>/dev/null)
    if [[ -n "$current_ulimit" ]] && ((current_ulimit < REQUIRED_NOFILE)); then
        ulimit -n "$REQUIRED_NOFILE" 2>/dev/null || \
        ulimit -n "$(ulimit -Hn 2>/dev/null)" 2>/dev/null || true
    fi

    if [[ -n "$STRATEGY_ORIG_CONNTRACK" ]] && ((STRATEGY_ORIG_CONNTRACK < 262144)); then
        echo 262144 > /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || true
    fi

    if [[ -n "$STRATEGY_ORIG_SOMAXCONN" ]] && ((STRATEGY_ORIG_SOMAXCONN < 4096)); then
        echo 4096 > /proc/sys/net/core/somaxconn 2>/dev/null || true
    fi

    STRATEGY_SYSTEM_TUNED=true
}

strategy_restore_system() {
    [[ "$STRATEGY_SYSTEM_TUNED" != "true" ]] && return 0

    if [[ -n "$STRATEGY_ORIG_ULIMIT" ]]; then
        ulimit -n "$STRATEGY_ORIG_ULIMIT" 2>/dev/null || true
    fi

    if [[ -n "$STRATEGY_ORIG_CONNTRACK" ]]; then
        echo "$STRATEGY_ORIG_CONNTRACK" > /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || true
    fi

    if [[ -n "$STRATEGY_ORIG_SOMAXCONN" ]]; then
        echo "$STRATEGY_ORIG_SOMAXCONN" > /proc/sys/net/core/somaxconn 2>/dev/null || true
    fi

    STRATEGY_SYSTEM_TUNED=false
}

strategy_cleanup() {
    STRATEGY_TEST_RUNNING=false

    pkill -P $$ 2>/dev/null || true
    wait 2>/dev/null || true

    if [[ -n "$STRATEGY_TEST_DIR" && -d "$STRATEGY_TEST_DIR" ]]; then
        rm -rf "$STRATEGY_TEST_DIR"
    fi
    STRATEGY_TEST_DIR=""

    if [[ -n "$STRATEGY_ORIGINAL_CONFIG" && -f "$STRATEGY_ORIGINAL_CONFIG" ]]; then
        cp "$STRATEGY_ORIGINAL_CONFIG" /opt/zapret/config 2>/dev/null
    fi
    STRATEGY_ORIGINAL_CONFIG=""
    STRATEGY_SELECTED_TARGETS=()

    strategy_restore_system
}

strategy_signal_handler() {
    trap - SIGINT SIGTERM

    echo ""
    echo -e "\e[33mПрерывание тестирования...\e[0m"
    strategy_cleanup
    manage_service restart 2>/dev/null || true

    stty sane 2>/dev/null || true
    read -r -t 0.1 -n 10000 discard 2>/dev/null || true
    exec < /dev/tty

    main_menu
}

strategy_init() {
    set +e
    trap strategy_signal_handler SIGINT SIGTERM
    STRATEGY_TEST_RUNNING=true
    STRATEGY_TEST_DIR=$(mktemp -d)
    mkdir -p "$STRATEGY_TEST_DIR/results"
    STRATEGY_BEST_SCORE=0
    STRATEGY_CALIBRATED=""
    strategy_tune_system
}

strategy_finish() {
    trap - SIGINT SIGTERM
    STRATEGY_TEST_RUNNING=false
    [[ -n "$STRATEGY_TEST_DIR" && -d "$STRATEGY_TEST_DIR" ]] && rm -rf "$STRATEGY_TEST_DIR"
    STRATEGY_TEST_DIR=""
    STRATEGY_ORIGINAL_CONFIG=""
    STRATEGY_SELECTED_TARGETS=()
    strategy_restore_system
    echo ""
    read -rp "Нажмите Enter для возврата в меню..."
    main_menu
}

ensure_configs_repo() {
    local repo_dir="/opt/zapret/zapret.cfgs"
    if [[ ! -d "$repo_dir" ]]; then
        echo -e "\e[35mКлонирую конфигурации...\e[0m"
        git clone https://github.com/Snowy-Fluffy/zapret.cfgs "$repo_dir" 2>/dev/null || true
    fi
    if [[ -d "$repo_dir/.git" ]]; then
        git -C "$repo_dir" fetch origin main 2>/dev/null && \
        git -C "$repo_dir" reset --hard origin/main 2>/dev/null || true
    fi
}

extract_domain() {
    local url="$1"
    echo "$url" | sed 's|^https\?://||;s|[:/].*$||'
}

load_configs_list() {
    [[ ! -d "$STRATEGY_CONFIGS_DIR" ]] && return
    find "$STRATEGY_CONFIGS_DIR" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort
}

load_target_groups() {
    [[ ! -d "$STRATEGY_TARGETS_DIR" ]] && return
    find "$STRATEGY_TARGETS_DIR" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort
}

load_targets_from_groups() {
    local -n groups_ref=$1
    for group in "${groups_ref[@]}"; do
        local file="$STRATEGY_TARGETS_DIR/$group"
        [[ ! -f "$file" ]] && continue
        local base="${group%.*}"
        sed -e '/^#/d' -e '/^$/d' \
            -e 's|^https\?://||' \
            -e 's|/.*||' \
            -e 's|^\*\.||' \
            "$file" | awk -v base="$base" '{if($0!="")print base"_"NR-1"=https://"$0}'
    done
}

select_items() {
    local -n items_ref=$1
    local -n selected_ref=$2

    for i in "${!items_ref[@]}"; do
        printf "  %2d. %s\n" $((i+1)) "${items_ref[$i]}"
    done
    echo ""
    echo -e "\e[33mВыберите режим:\e[0m"
    echo -e "  \e[32mEnter\e[0m - все"
    echo -e "  \e[32m+\e[0m     - только указанные"
    echo -e "  \e[32m-\e[0m     - исключить указанные"
    echo ""
    read -rp $'\e[1;36mВаш выбор: \e[0m' input

    selected_ref=()
    local max=${#items_ref[@]}

    case "$input" in
        "")
            selected_ref=("${items_ref[@]}")
            ;;
        +*)
            local nums="${input#+}"
            [[ -z "$nums" ]] && read -rp $'\e[33mНомера: \e[0m' nums
            for n in $nums; do
                [[ "$n" =~ ^[0-9]+$ && $n -gt 0 && $n -le $max ]] && \
                    selected_ref+=("${items_ref[$((n-1))]}")
            done
            ;;
        -*)
            local nums="${input#-}"
            [[ -z "$nums" ]] && read -rp $'\e[33mНомера для исключения: \e[0m' nums
            declare -A excluded
            for n in $nums; do
                [[ "$n" =~ ^[0-9]+$ && $n -gt 0 && $n -le $max ]] && \
                    excluded["${items_ref[$((n-1))]}"]=1
            done
            for item in "${items_ref[@]}"; do
                [[ -z "${excluded[$item]}" ]] && selected_ref+=("$item")
            done
            ;;
        *)
            if [[ "$input" =~ ^[0-9\ ]+$ ]]; then
                for n in $input; do
                    [[ "$n" =~ ^[0-9]+$ && $n -gt 0 && $n -le $max ]] && \
                        selected_ref+=("${items_ref[$((n-1))]}")
                done
            else
                selected_ref=("${items_ref[@]}")
            fi
            ;;
    esac
}

select_targets() {
    local -n groups_ref=$1
    local -n selected_ref=$2

    echo -e "\e[36mДоступные списки таргетов:\e[0m"
    for i in "${!groups_ref[@]}"; do
        local file="$STRATEGY_TARGETS_DIR/${groups_ref[$i]}"
        local count=0
        [[ -f "$file" ]] && count=$(grep -Ecv '^#|^$' "$file" 2>/dev/null || echo 0)
        printf "  %2d. %s (%d)\n" $((i+1)) "${groups_ref[$i]}" "$count"
    done
    echo ""
    echo -e "\e[33mВыберите режим:\e[0m"
    echo -e "  \e[32mEnter\e[0m - все группы"
    echo -e "  \e[32m+\e[0m     - только указанные"
    echo -e "  \e[32m-\e[0m     - исключить указанные"
    echo ""
    read -rp $'\e[1;36mВаш выбор: \e[0m' input

    selected_ref=()
    local max=${#groups_ref[@]}

    case "$input" in
        "") selected_ref=("${groups_ref[@]}") ;;
        +*)
            local nums="${input#+}"
            [[ -z "$nums" ]] && read -rp $'\e[33mНомера: \e[0m' nums
            for n in $nums; do
                [[ "$n" =~ ^[0-9]+$ && $n -gt 0 && $n -le $max ]] && \
                    selected_ref+=("${groups_ref[$((n-1))]}")
            done
            ;;
        -*)
            local nums="${input#-}"
            [[ -z "$nums" ]] && read -rp $'\e[33mНомера: \e[0m' nums
            declare -A excluded
            for n in $nums; do
                [[ "$n" =~ ^[0-9]+$ && $n -gt 0 && $n -le $max ]] && \
                    excluded["${groups_ref[$((n-1))]}"]=1
            done
            for g in "${groups_ref[@]}"; do
                [[ -z "${excluded[$g]}" ]] && selected_ref+=("$g")
            done
            ;;
        *)
            if [[ "$input" =~ ^[0-9\ ]+$ ]]; then
                for n in $input; do
                    [[ "$n" =~ ^[0-9]+$ && $n -gt 0 && $n -le $max ]] && \
                        selected_ref+=("${groups_ref[$((n-1))]}")
                done
            else
                selected_ref=("${groups_ref[@]}")
            fi
            ;;
    esac
}

select_strategies() {
    echo -e "\e[36mДоступные стратегии:\e[0m"
    select_items "$1" "$2"
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

get_result_color() {
    case "$1" in
        OK|2*|3*|4*|5*) echo "32" ;;
        FAIL)           echo "31" ;;
        SKIP|--)        echo "90" ;;
        *)              echo "32" ;;
    esac
}

curl_test_single() {
    local url="$1" test_type="$2" timeout="${3:-3}"
    local http_code=""
    local opts="-s -o /dev/null -w %{http_code} --head --connect-timeout $timeout --max-time $timeout"

    case "$test_type" in
        http)  http_code=$(curl $opts --http1.1 "$url" 2>/dev/null) ;;
        tls12) http_code=$(curl $opts --tlsv1.2 --tls-max 1.2 "$url" 2>/dev/null) ;;
        tls13) http_code=$(curl $opts --tlsv1.3 --tls-max 1.3 "$url" 2>/dev/null) ;;
    esac

    if [[ "$http_code" =~ ^[2345][0-9][0-9]$ ]]; then
        echo "$url|$http_code"
    else
        echo "$url|FAIL"
    fi
}

ping_test_single() {
    local domain="$1"
    local output
    output=$(ping -c 1 -W 2 "$domain" 2>/dev/null)

    if [[ "$output" =~ time=([0-9.]+) ]]; then
        echo "$domain|${BASH_REMATCH[1]}ms"
    elif [[ -n "$output" ]]; then
        echo "$domain|OK"
    else
        echo "$domain|FAIL"
    fi
}

export -f curl_test_single ping_test_single extract_domain

prepare_test_data() {
    local urls_file="$1"
    local domains_file="$2"
    local targets=""

    if [[ ${#STRATEGY_SELECTED_TARGETS[@]} -gt 0 ]]; then
        targets=$(load_targets_from_groups STRATEGY_SELECTED_TARGETS)
    fi
    [[ -z "$targets" ]] && targets=$(get_default_targets)

    echo "$targets" | awk -F'=' '
        /^#/ || /^$/ {next}
        {
            gsub(/ /, "", $2)
            url = $2
            if (url == "") next
            print url > "'"$urls_file"'"
            domain = url
            sub(/^https?:\/\//, "", domain)
            sub(/[:\/].*$/, "", domain)
            print domain > "'"$domains_file"'"
        }
    '
}

run_batch_curl() {
    local urls_file="$1" test_type="$2" output_file="$3"
    local timeout="$CURL_TIMEOUT"
    local tls_ver="" tls_max=""

    case "$test_type" in
        http)  tls_ver="http1.1" ;;
        tls12) tls_ver="tlsv1.2"; tls_max="1.2" ;;
        tls13) tls_ver="tlsv1.3"; tls_max="1.3" ;;
    esac

    local config_file="${urls_file}.curlconfig"
    awk -v timeout="$timeout" -v tlsver="$tls_ver" -v tlsmax="$tls_max" '{
        print "url = " $0
        print "output = /dev/null"
        print "write-out = %{url}|%{http_code}\\n"
        print "silent"
        print "head"
        print "connect-timeout = " timeout
        print "max-time = " timeout
        if (length(tlsver) > 0) print tlsver
        if (length(tlsmax) > 0) print "tls-max = " tlsmax
        print ""
    }' "$urls_file" > "$config_file"

    curl --parallel --parallel-max "$MAX_PARALLEL" --parallel-immediate \
        --config "$config_file" 2>/dev/null | \
    awk -F'|' '{code=$NF; if(code ~ /^[2345][0-9][0-9]$/)print $0; else print $1"|FAIL"}' \
        > "$output_file" || true

    rm -f "$config_file"
}

run_batch_ping() {
    local domains_file="$1" output_file="$2"

    sort -u "$domains_file" | xargs -P "$MAX_PARALLEL" -I{} \
        bash -c 'ping_test_single "$1"' _ {} \
        > "$output_file" 2>/dev/null || true
}

combine_results() {
    local urls_file="$1"
    local http_file="$2"
    local tls12_file="$3"
    local tls13_file="$4"
    local ping_file="$5"
    local output_file="$6"

    declare -A http_results tls12_results tls13_results ping_results

    while IFS='|' read -r url code; do
        [[ -n "$url" ]] && http_results["$url"]="$code"
    done < "$http_file"

    while IFS='|' read -r url code; do
        [[ -n "$url" ]] && tls12_results["$url"]="$code"
    done < "$tls12_file"

    while IFS='|' read -r url code; do
        [[ -n "$url" ]] && tls13_results["$url"]="$code"
    done < "$tls13_file"

    while IFS='|' read -r domain ping_val; do
        [[ -n "$domain" ]] && ping_results["$domain"]="$ping_val"
    done < "$ping_file"

    > "$output_file"
    local idx=0
    while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        local domain
        domain=$(extract_domain "$url")
        local http="${http_results[$url]:-FAIL}"
        local tls12="${tls12_results[$url]:-FAIL}"
        local tls13="${tls13_results[$url]:-FAIL}"
        local ping="${ping_results[$domain]:-FAIL}"
        echo "target_${idx}|$http|$tls12|$tls13|$ping" >> "$output_file"
        ((idx++))
    done < "$urls_file"
}

run_batch_test() {
    local batch_urls="$1"
    local batch_domains="$2"
    local test_dir="$3"
    local batch_output="$4"

    run_batch_curl "$batch_urls" "http" "$test_dir/http.txt" &
    local pid_http=$!
    run_batch_curl "$batch_urls" "tls12" "$test_dir/tls12.txt" &
    local pid_tls12=$!
    run_batch_curl "$batch_urls" "tls13" "$test_dir/tls13.txt" &
    local pid_tls13=$!
    run_batch_ping "$batch_domains" "$test_dir/ping.txt" &
    local pid_ping=$!

    wait $pid_http $pid_tls12 $pid_tls13 $pid_ping 2>/dev/null || true

    combine_results "$batch_urls" \
        "$test_dir/http.txt" \
        "$test_dir/tls12.txt" \
        "$test_dir/tls13.txt" \
        "$test_dir/ping.txt" \
        "$batch_output"
}

can_strategy_win() {
    local current_ok="$1"
    local tested_count="$2"
    local total_count="$3"

    [[ $STRATEGY_BEST_SCORE -eq 0 ]] && return 0

    local remaining=$((total_count - tested_count))
    local max_possible=$((current_ok + remaining * 3))

    ((max_possible >= STRATEGY_BEST_SCORE))
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

run_parallel_tests() {
    local output_file="$1"
    local test_dir="$STRATEGY_TEST_DIR/batch_$$"
    mkdir -p "$test_dir"

    local urls_file="$test_dir/all_urls.txt"
    local domains_file="$test_dir/all_domains.txt"

    prepare_test_data "$urls_file" "$domains_file"

    local total
    total=$(wc -l < "$urls_file")

    if [[ -z "$STRATEGY_CALIBRATED" ]] && ((total >= 200)); then
        echo -ne "\e[90mКалибровка...\e[0m"
        local sample_file="$test_dir/calibration_sample.txt"
        head -200 "$urls_file" > "$sample_file"
        strategy_calibrate "$sample_file"
        rm -f "$sample_file"
        STRATEGY_CALIBRATED=1
        echo -e "\r\e[90mКалибровка: MAX_PARALLEL=$MAX_PARALLEL\e[0m"
    fi

    if ((total <= 500)); then
        BATCH_SIZE=$total
    elif ((total <= 5000)); then
        BATCH_SIZE=$(( (total + 4) / 5 ))
    elif ((total <= 50000)); then
        BATCH_SIZE=$(( (total + 4) / 5 ))
        ((BATCH_SIZE > 10000)) && BATCH_SIZE=10000
    else
        BATCH_SIZE=20000
    fi

    local num_batches=$(( (total + BATCH_SIZE - 1) / BATCH_SIZE ))

    echo -e "\e[36mТаргетов: $total | Батч: $BATCH_SIZE | Параллельность: $MAX_PARALLEL | Таймаут: ${CURL_TIMEOUT}s\e[0m"

    > "$output_file"
    local current_ok=0 tested=0 skipped=false

    for ((batch=0; batch<num_batches; batch++)); do
        [[ "$STRATEGY_TEST_RUNNING" != "true" ]] && break

        local start=$((batch * BATCH_SIZE + 1))
        local end=$(( (batch + 1) * BATCH_SIZE ))
        ((end > total)) && end=$total
        local batch_count=$((end - start + 1))

        local batch_dir="$test_dir/b$batch"
        mkdir -p "$batch_dir"

        sed -n "${start},${end}p" "$urls_file" > "$batch_dir/urls.txt"
        sed -n "${start},${end}p" "$domains_file" > "$batch_dir/domains.txt"

        echo -ne "\e[90m  [$((batch+1))/$num_batches] $tested/$total...\e[0m"

        run_batch_test "$batch_dir/urls.txt" "$batch_dir/domains.txt" "$batch_dir" "$batch_dir/results.txt"
        cat "$batch_dir/results.txt" >> "$output_file"

        local batch_ok
        batch_ok=$(awk -F'|' '{for(i=2;i<=4;i++)if($i!="FAIL"&&$i!="SKIP"&&$i!="--")c++}END{print c+0}' "$batch_dir/results.txt")
        current_ok=$((current_ok + batch_ok))
        tested=$((tested + batch_count))

        echo -e " \e[32mOK:$current_ok\e[0m"
        rm -rf "$batch_dir"

        if ! can_strategy_win "$current_ok" "$tested" "$total"; then
            local remaining=$((total - tested))
            local max_possible=$((current_ok + remaining * 3))
            echo -e "\e[33m  ⚡ Раннее завершение: макс $max_possible < лидер $STRATEGY_BEST_SCORE\e[0m"
            skipped=true
            break
        fi
    done

    rm -rf "$test_dir"
    [[ "$skipped" == "true" ]] && return 1
    return 0
}

print_test_results() {
    local results_file="$1"
    local E=$'\e'
    local max_lines=50

    echo "┌──────────────────────┬────────┬─────────┬─────────┬──────────┐"
    echo "│ Target               │ HTTP   │ TLS1.2  │ TLS1.3  │ Ping     │"
    echo "├──────────────────────┼────────┼─────────┼─────────┼──────────┤"

    local count=0
    while IFS='|' read -r name http tls12 tls13 ping; do
        [[ -z "$name" ]] && continue
        ((count >= max_lines)) && break
        [[ ${#name} -gt 20 ]] && name="${name:0:17}..."

        printf "│ %-20s │ ${E}[%sm%-6s${E}[0m │ ${E}[%sm%-7s${E}[0m │ ${E}[%sm%-7s${E}[0m │ ${E}[%sm%-8s${E}[0m │\n" \
            "$name" \
            "$(get_result_color "$http")" "$http" \
            "$(get_result_color "$tls12")" "$tls12" \
            "$(get_result_color "$tls13")" "$tls13" \
            "$(get_result_color "$ping")" "$ping"
        ((count++))
    done < "$results_file"

    echo "└──────────────────────┴────────┴─────────┴─────────┴──────────┘"

    local total
    total=$(wc -l < "$results_file")
    ((total > max_lines)) && echo -e "\e[90m  ... и ещё $((total - max_lines)) таргетов\e[0m"
}

print_score() {
    local results_file="$1"
    local score
    score=$(calculate_score "$results_file")
    local ok fail ping_ok
    read -r ok fail ping_ok <<< "$score"
    echo -e "\e[36mРезультат: \e[32mOK:$ok\e[0m \e[31mFAIL:$fail\e[0m \e[36mPING:$ping_ok\e[0m"
}

apply_strategy() {
    local config_path="$1"
    [[ ! -f "$config_path" ]] && return 1

    cp "$config_path" /opt/zapret/config 2>/dev/null || return 1
    get_fwtype 2>/dev/null || true
    sed -i "s|^FWTYPE=.*|FWTYPE=$FWTYPE|" /opt/zapret/config 2>/dev/null || true
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

    local target_groups=() selected_targets=()
    mapfile -t target_groups < <(load_target_groups)
    STRATEGY_SELECTED_TARGETS=()

    if [[ ${#target_groups[@]} -gt 0 ]]; then
        echo -e "\e[1;33m━━━ Выбор таргетов ━━━\e[0m"
        echo ""
        select_targets target_groups selected_targets
        if [[ ${#selected_targets[@]} -gt 0 ]]; then
            echo -e "\e[35mВыбраны: ${selected_targets[*]}\e[0m"
            STRATEGY_SELECTED_TARGETS=("${selected_targets[@]}")
        fi
        echo ""
    else
        echo -e "\e[36mИспользуются стандартные таргеты\e[0m"
        echo ""
    fi

    local configs=() selected=()
    mapfile -t configs < <(load_configs_list)

    if [[ ${#configs[@]} -eq 0 ]]; then
        echo -e "\e[31mНе найдено стратегий\e[0m"
        strategy_finish
        return
    fi

    echo -e "\e[1;33m━━━ Выбор стратегий ━━━\e[0m"
    echo ""
    select_strategies configs selected

    if [[ ${#selected[@]} -eq 0 ]]; then
        echo -e "\e[31mНе выбрано ни одной стратегии\e[0m"
        strategy_finish
        return
    fi

    echo ""
    echo -e "\e[36mБудет протестировано: ${#selected[@]}\e[0m"
    echo -e "\e[33mCtrl+C для отмены\e[0m"
    echo -e "\e[90mУмное отсечение: пропуск если стратегия не может победить\e[0m"
    sleep 2

    local num=0 total=${#selected[@]}
    declare -A scores scores_ok scores_fail scores_ping skipped

    for config in "${selected[@]}"; do
        [[ "$STRATEGY_TEST_RUNNING" != "true" ]] && break
        ((num++))

        echo ""
        echo -e "\e[1;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m"
        echo -e "\e[1;36m[$num/$total] $config\e[0m"
        [[ $STRATEGY_BEST_SCORE -gt 0 ]] && echo -e "\e[90mЛидер: $STRATEGY_BEST_SCORE OK\e[0m"
        echo -e "\e[1;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m"

        echo -e "\e[35mПрименяю...\e[0m"
        if ! apply_strategy "$STRATEGY_CONFIGS_DIR/$config"; then
            echo -e "\e[31mОшибка применения\e[0m"
            continue
        fi

        echo -e "\e[35mТестирую...\e[0m"
        local results_file="$STRATEGY_TEST_DIR/results/${config//[^a-zA-Z0-9_-]/_}.results"

        if ! run_parallel_tests "$results_file"; then
            skipped["$config"]=1
            continue
        fi

        if [[ -f "$results_file" && -s "$results_file" ]]; then
            local ok fail ping_ok
            read -r ok fail ping_ok <<< "$(calculate_score "$results_file")"

            scores["$config"]="OK:$ok FAIL:$fail PING:$ping_ok"
            scores_ok["$config"]=$ok
            scores_fail["$config"]=$fail
            scores_ping["$config"]=$ping_ok

            ((ok > STRATEGY_BEST_SCORE)) && STRATEGY_BEST_SCORE=$ok

            echo ""
            echo -e "\e[36mИтог: \e[32mOK:$ok\e[0m \e[31mFAIL:$fail\e[0m \e[36mPING:$ping_ok\e[0m"
            echo -e "\e[90mЛучший: $STRATEGY_BEST_SCORE\e[0m"
        fi
    done

    echo ""
    echo -e "\e[1;42;30m╔════════════════════════════════════════════════════════════════╗\e[0m"
    echo -e "\e[1;42;30m║                      ИТОГОВЫЙ РЕЗУЛЬТАТ                        ║\e[0m"
    echo -e "\e[1;42;30m╚════════════════════════════════════════════════════════════════╝\e[0m"
    echo ""

    if [[ ${#scores[@]} -eq 0 ]]; then
        echo -e "\e[31mНе удалось протестировать ни одной стратегии\e[0m"
        strategy_cleanup
        manage_service restart >/dev/null 2>&1 || true
        strategy_finish
        return
    fi

    local sorted_configs=()
    while IFS=$'\t' read -r _ _ cfg; do
        sorted_configs+=("$cfg")
    done < <(
        for cfg in "${!scores_ok[@]}"; do
            printf '%d\t%d\t%s\n' "${scores_ok[$cfg]}" "${scores_ping[$cfg]}" "$cfg"
        done | sort -t$'\t' -k1,1nr -k2,2nr
    )

    local leaders=()
    while IFS=$'\t' read -r _ _ cfg; do
        leaders+=("$cfg")
    done < <(
        for cfg in "${!scores_ok[@]}"; do
            ((scores_ok[$cfg] == STRATEGY_BEST_SCORE)) && \
                printf '%d\t%d\t%s\n' "${scores_fail[$cfg]}" "${scores_ping[$cfg]}" "$cfg"
        done | sort -t$'\t' -k1,1n -k2,2nr
    )

    echo -e "\e[1;32m★ ЛИДЕРЫ (OK: $STRATEGY_BEST_SCORE):\e[0m"
    echo ""
    for cfg in "${leaders[@]}"; do
        local ping=${scores_ping[$cfg]} fail=${scores_fail[$cfg]}
        printf "  \e[1;32m► %-40s FAIL:%-3d PING:%-3d\e[0m\n" "${cfg:0:40}" "$fail" "$ping"
    done

    echo ""
    echo -e "\e[36mВсе результаты:\e[0m"
    echo ""
    printf "  \e[1;33m%-3s %-40s %s\e[0m\n" "N" "Стратегия" "Результат"
    echo "  ─────────────────────────────────────────────────────────────"

    local idx=1
    for cfg in "${sorted_configs[@]}"; do
        local ok=${scores_ok[$cfg]} fail=${scores_fail[$cfg]} ping=${scores_ping[$cfg]}
        local color="32"
        ((ok == STRATEGY_BEST_SCORE)) && color="1;32"
        ((fail > 0 && ok < STRATEGY_BEST_SCORE)) && color="33"
        ((fail > ok)) && color="31"
        printf "  \e[${color}m%2d. %-40s OK:%-3d FAIL:%-3d PING:%-3d\e[0m\n" \
            "$idx" "${cfg:0:40}" "$ok" "$fail" "$ping"
        ((idx++))
    done

    if [[ ${#skipped[@]} -gt 0 ]]; then
        echo ""
        echo -e "\e[90mПропущены (не могли догнать лидера): ${#skipped[@]}\e[0m"
    fi

    echo ""
    echo -e "\e[33mВведите номер для применения (0 - отмена):\e[0m"
    read -rp $'\e[1;36mВыбор: \e[0m' choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice > 0 && choice <= ${#sorted_configs[@]})); then
        local chosen="${sorted_configs[$((choice-1))]}"
        echo ""
        echo -e "\e[35mПрименяю: $chosen\e[0m"
        if apply_strategy "$STRATEGY_CONFIGS_DIR/$chosen"; then
            STRATEGY_ORIGINAL_CONFIG=""
            echo -e "\e[32mГотово\e[0m"
        else
            echo -e "\e[31mОшибка применения, восстанавливаю...\e[0m"
            strategy_cleanup
            manage_service restart >/dev/null 2>&1 || true
        fi
    else
        echo ""
        echo -e "\e[33mВосстанавливаю конфигурацию...\e[0m"
        strategy_cleanup
        manage_service restart >/dev/null 2>&1 || true
        echo -e "\e[32mГотово\e[0m"
    fi

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
    echo -e "\e[33mТекущая: \e[36m${cr_cnf:-неизвестно}\e[0m"
    echo ""

    echo -e "\e[35mТестирую...\e[0m"
    local results_file="$STRATEGY_TEST_DIR/results/current.results"
    run_parallel_tests "$results_file"

    if [[ -f "$results_file" && -s "$results_file" ]]; then
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

    if [[ -z "$choice" || "$choice" == "0" ]] || \
       ! [[ "$choice" =~ ^[0-9]+$ ]] || \
       ((choice < 1 || choice > ${#configs[@]})); then
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

    if [[ -f "$results_file" && -s "$results_file" ]]; then
        echo ""
        print_test_results "$results_file"
        echo ""
        print_score "$results_file"
    fi

    echo ""
    read -rp "Применить? (y/N): " answer

    if [[ "$answer" =~ ^[Yy]$ ]]; then
        echo -e "\e[32mПрименено\e[0m"
        STRATEGY_ORIGINAL_CONFIG=""
    else
        strategy_cleanup
        manage_service restart >/dev/null 2>&1 || true
        echo -e "\e[33mВосстановлено\e[0m"
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
        echo -e "  \e[33mТекущая:\e[0m \e[32m${cr_cnf:-неизвестно}\e[0m"
        echo ""
        echo -e "  \e[31m0)\e[0m Назад"
        echo -e "  \e[34m1)\e[0m Тест текущей"
        echo -e "  \e[34m2)\e[0m Тест отдельной"
        echo -e "  \e[32m3)\e[0m Автоподбор"
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
