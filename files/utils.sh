#!/bin/bash


error_exit() {
    $TPUT_E 
    echo -e "\e[31mОшибка:\e[0m $1" >&2 
    exit 1
}

check_fs() {
    if [ "$(awk '$2 == "/" {print $4}' /proc/mounts)" = "ro" ]; then
        error_exit "файловая система только для чтения, не могу продолжить."
    fi
}

exists() {
    which "$1" >/dev/null 2>/dev/null
}

existf() {
    type "$1" >/dev/null 2>/dev/null
}

whichq() {
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
open_editor() {
    local file_path="$1"
    if [ ! -f "$1" ]; then
        error_exit "заданного файла не существует"
    fi
    
    if [ -z "$EDITOR" ] || [ ! -n "$EDITOR" ]; then
        echo "Переменная EDITOR пуста"
        echo ""
        echo "Продолжаю через 5 секунд..."
        sleep 5
        main_menu
    fi
    
    "$EDITOR" "$1"
    main_menu
}
fast_exit(){
    $TPUT_E
    echo "Выход по запросу пользователя"
    exit 1
}
