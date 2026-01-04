#!/bin/bash


main_menu() {
    while true; do
        clear
        check_zapret_status
        check_zapret_exist
        echo -e "\e[1;36m╔════════════════════════════════════════════╗"
        echo -e "║          Меню управления Запретом          ║"
        echo -e "╚════════════════════════════════════════════╝\e[0m"

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

        if [[ $ZAPRET_EXIST == true ]]; then
            echo -e "  \e[1;34m0)\e[0m Выйти"
            echo -e "  \e[1;32m1)\e[0m Автоподбор лучшей стратегии"
            echo -e "  \e[1;33m2)\e[0m Проверить на обновления и обновить"
            echo -e "  \e[1;36m3)\e[0m Сменить конфигурацию запрета"
            echo -e "  \e[1;35m4)\e[0m Управление сервисом запрета"
            echo -e "  \e[1;31m5)\e[0m Удалить Запрет"
        else
            echo -e "  \e[1;34m0)\e[0m Выйти"
            echo -e "  \e[1;32m1)\e[0m Установить Запрет"
            echo -e "  \e[1;36m2)\e[0m Проверить скрипт на обновления"
        fi

        echo ""
        echo -e "\e[1;96mСделано\e[0m by: \e[4;94mhttps://t.me/linux_hi\e[0m"
        echo ""

        if [[ $ZAPRET_EXIST == true ]]; then
            read -p $'\e[1;36mВыберите действие: \e[0m' CHOICE
            case "$CHOICE" in
                1) auto_select_strategy;;
                2) update_zapret_menu;;
                3) change_configuration;;
                4) toggle_service;;
                5) uninstall_zapret;;
                0) $TPUT_E; exit 0;;
                *) echo -e "\e[1;31m Неверный ввод! Попробуйте снова.\e[0m"; sleep 2;;
            esac
        else
            read -p $'\e[1;36mВыберите действие: \e[0m' CHOICE
            case "$CHOICE" in
                1) install_zapret_menu; main_menu;;
                2) update_script;;
                0) tput rmcup; exit 0;;
                *) echo -e "\e[1;31m Неверный ввод! Попробуйте снова.\e[0m"; sleep 2;;
            esac
        fi
    done
}
install_zapret_menu() {
    while true; do
        clear
        echo -e "\e[1;36m╔════════════════════════════════════════════╗"
        echo -e "║          Меню управления Запретом          ║"
        echo -e "╚════════════════════════════════════════════╝\e[0m"
        echo -e "  \e[1;31m0)\e[0m Выйти в меню"
        echo -e "  \e[1;34m1)\e[0m Установить zapret как релиз (рекомендуется)"
        echo -e "  \e[1;34m2)\e[0m Установить zapret через git"
        read -p $'\e[1;36mВыберите действие: \e[0m' CHOICE
        case "$CHOICE" in
            1) install_zapret_release ;;
            2) install_zapret_git ;;
            0) main_menu ;;
            *) echo -e "\e[1;31mНеверный ввод! Попробуйте снова.\e[0m"; sleep 2 ;;
        esac
    done

}
change_configuration() {
    while true; do
        clear
        cur_conf
        cur_list
        game_mode_check

        echo -e "\e[1;36m╔══════════════════════════════════════════════╗"
        echo -e "║        Управление конфигурацией Запрета      ║"
        echo -e "╚══════════════════════════════════════════════╝\e[0m"
        echo -e "  \e[1;33m Используемая стратегия:\e[0m \e[1;32m$cr_cnf\e[0m"
        echo -e "  \e[1;33m Используемый хостлист:\e[0m \e[1;32m$cr_lst\e[0m"
        echo -e "  \e[1;33m Игровой режим:\e[0m \e[1;32m$game_mode_status\e[0m"
        echo ""
        echo -e "  \e[1;31m0)\e[0m Выйти в меню"
        if [[ $game_mode_status == "включен" ]]; then 
            echo -e "  \e[1;34m1)\e[0m Выключить игровой режим"
        else 
            echo -e "  \e[1;34m1)\e[0m Включить игровой режим"
        fi
        echo -e "  \e[1;34m2)\e[0m Сменить стратегию"
        echo -e "  \e[1;34m3)\e[0m Сменить лист обхода"
        echo -e "  \e[1;34m4)\e[0m Добавить IP или домены в лист"
        echo -e "  \e[1;34m5)\e[0m Удалить IP или домены из листа"
        echo -e "  \e[1;34m6)\e[0m Найти IP или домены в листе"
        echo -e "  \e[1;34m7)\e[0m Установить стратегию из файла (путь)"
        echo -e "  \e[1;34m8)\e[0m Установить хостлист из файла (путь)"
        echo -e "  \e[1;34m9)\e[0m Редактировать стратегию напрямую"
        echo -e "  \e[1;34m10)\e[0m Редактировать хостлист напрямую"
        echo -e "  \e[1;34m11)\e[0m Создать/Редактировать кастомный хостлист"
        echo -e "  \e[1;34m12)\e[0m Создать/Редактировать кастомную стратегию"

        echo ""
        echo -e "\e[1;96mСделано\e[0m by: \e[4;94mhttps://t.me/linux_hi\e[0m"
        echo ""

        read -p $'\e[1;36mВыберите действие: \e[0m' CHOICE
        case "$CHOICE" in
            1) toggle_game_mode ;;
            2) configure_zapret_menu ;;
            3) configure_zapret_list ;;
            4) add_to_zapret ;;
            5) delete_from_zapret ;;
            6) search_in_zapret ;;
            7) configure_custom_conf_path ;;
            8) configure_custom_list_path ;;
            9) open_editor /opt/zapret/config ;;
            10) open_editor /opt/zapret/ipset/zapret-hosts-user.txt ;;
            11) edit_cust_list;;
            12) edit_cust_conf;;
            0) main_menu ;;
            *) echo -e "\e[1;31mНеверный ввод! Попробуйте снова.\e[0m"; sleep 2 ;;
        esac
    done
}
configure_zapret_menu(){
    if existf strategy_menu; then
        strategy_menu
    else
        while true; do
            clear
            cur_conf
            echo -e "\e[1;36m╔══════════════════════════════════════════════╗"
            echo -e "║         Управление стратегиями Запрета       ║"
            echo -e "╚══════════════════════════════════════════════╝\e[0m"
            echo -e "  \e[1;33m Используемая стратегия:\e[0m \e[1;32m$cr_cnf\e[0m"
            echo -e "  \e[1;31m0)\e[0m Выйти в меню"
            echo -e "  \e[1;34m1)\e[0m Выбрать стратегию вручную"
            echo -e "  \e[1;34m2)\e[0m Подобрать стратегию автоматически"
            echo ""
            echo -e "\e[1;96mСделано\e[0m by: \e[4;94mhttps://t.me/linux_hi\e[0m"
            echo ""
            read -p $'\e[1;36m Выберите действие: \e[0m' CHOICE
            case "$CHOICE" in
                1) configure_zapret_conf;;
                2) check_conf;;
                0) main_menu;;
                *) echo -e "\e[1;31m Неверный ввод! Попробуйте снова.\e[0m"; sleep 2;;
            esac
        done
    fi
}


update_zapret_menu(){
    while true; do
        clear
        echo -e "\e[1;36m╔════════════════════════════════════╗"
        echo -e "║            Обновление Запрета       ║"
        echo -e "║         Текущая версия: $(if [ -f /opt/zapret-ver ]; then cat /opt/zapret-ver; else echo "Неизвестно";fi)       ║"

        echo -e "║       Последняя версия: $(get_latest_version)       ║"
        echo -e "╚════════════════════════════════════╝\e[0m"
        echo -e "  \e[1;31m0)\e[0m Выйти в меню"
        echo -e "  \e[1;33m1)\e[0m Обновить \e[33mвсё\e[0m"
        echo -e "  \e[1;32m2)\e[0m Обновить только \e[32mскрипт\e[0m"
        echo ""
        echo -e "\e[1;96mСделано\e[0m by: \e[4;94mhttps://t.me/linux_hi\e[0m"
        echo ""
        read -p $'\e[1;36m Выберите действие: \e[0m' CHOICE
        case "$CHOICE" in
            1) update_zapret;;
            2) update_installed_script;;
            0) main_menu;;
            *) echo -e "\e[1;31m Неверный ввод! Попробуйте снова.\e[0m"; sleep 2;;
        esac
    done
}
