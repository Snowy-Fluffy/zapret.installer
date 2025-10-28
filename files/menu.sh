#!/bin/bash


main_menu() {
    if [[ SYSTEM != openwrt ]]; then
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
                echo -e "  \e[1;34m0)\e[0m 🚪 Выйти"
            else
                echo -e "  \e[1;32m1)\e[0m 📥 Установить Запрет"
                echo -e "  \e[1;36m2)\e[0m 📜 Проверить скрипт на обновления"
                echo -e "  \e[1;34m0)\e[0m 🚪 Выйти"
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
                    0) $TPUT_E; exit 0;;
                    *) echo -e "\e[1;31m❌ Неверный ввод! Попробуйте снова.\e[0m"; sleep 2;;
                esac
            else
                read -p $'\e[1;36mВыберите действие: \e[0m' CHOICE
                case "$CHOICE" in
                    1) install_zapret; main_menu;;
                    2) update_script;;
                    0) tput rmcup; exit 0;;
                    *) echo -e "\e[1;31m❌ Неверный ввод! Попробуйте снова.\e[0m"; sleep 2;;
                esac
            fi
        done
    else
        while true; do
            clear
            check_zapret_status
            check_zapret_exist
            echo -e "\e[1;36m╔════════════════════════════════════════════╗"
            echo -e "║           Меню управления Запретом         ║"
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
                echo -e "  \e[1;33m1)\e[0m  Проверить на обновления и обновить"
                echo -e "  \e[1;36m2)\e[0m  Сменить конфигурацию запрета"
                echo -e "  \e[1;35m3)\e[0m  Управление сервисом запрета"
                echo -e "  \e[1;31m4)\e[0m  Удалить Запрет"
                echo -e "  \e[1;34m0)\e[0m  Выйти"
            else
                echo -e "  \e[1;32m1)\e[0m  Установить Запрет"
                echo -e "  \e[1;36m2)\e[0m  Проверить скрипт на обновления"
                echo -e "  \e[1;34m0)\e[0m  Выйти"
            fi

            echo ""
            echo -e "\e[1;96m Сделано с любовью \e[0m by: \e[4;94mhttps://t.me/linux_hi\e[0m"
            echo ""

            if [[ $ZAPRET_EXIST == true ]]; then
                read -p $'\e[1;36mВыберите действие: \e[0m' CHOICE
                case "$CHOICE" in
                    1) update_zapret_menu;;
                    2) change_configuration;;
                    3) toggle_service;;
                    4) uninstall_zapret;;
                    0) $TPUT_E; exit 0;;
                    *) echo -e "\e[1;31m Неверный ввод! Попробуйте снова.\e[0m"; sleep 2;;
                esac
            else
                read -p $'\e[1;36mВыберите действие: \e[0m' CHOICE
                case "$CHOICE" in
                    1) install_zapret; main_menu;;
                    2) update_script;;
                    0) tput rmcup; exit 0;;
                    *) echo -e "\e[1;31m Неверный ввод! Попробуйте снова.\e[0m"; sleep 2;;
                esac
            fi
        done
    fi
}

change_configuration() {
    if [[ SYSTEM != openwrt ]]; then
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
            echo -e "  \e[1;34m6)\e[0m 📥 Установить стратегию из файла (путь)"
            echo -e "  \e[1;34m7)\e[0m 📥 Установить хостлист из файла (путь)"
            echo -e "  \e[1;31m0)\e[0m 🚪 Выйти в меню"
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
                6) configure_custom_conf_path ;;
                7) configure_custom_list_path ;;
                0) main_menu ;;
                *) echo -e "\e[1;31m❌ Неверный ввод! Попробуйте снова.\e[0m"; sleep 2 ;;
            esac
        done
    else
        while true; do
            clear
            cur_conf
            cur_list

            echo -e "\e[1;36m╔══════════════════════════════════════════════╗"
            echo -e "║        Управление конфигурацией Запрета      ║"
            echo -e "╚══════════════════════════════════════════════╝\e[0m"
            echo -e "  \e[1;33m Используемая стратегия:\e[0m \e[1;32m$cr_cnf\e[0m"
            echo -e "  \e[1;33m Используемый хостлист:\e[0m \e[1;32m$cr_lst\e[0m"
            echo ""
            echo -e "  \e[1;34m1)\e[0m  Сменить стратегию"
            echo -e "  \e[1;34m2)\e[0m  Сменить лист обхода"
            echo -e "  \e[1;34m3)\e[0m  Добавить IP или домены в лист"
            echo -e "  \e[1;34m4)\e[0m  Удалить IP или домены из листа"
            echo -e "  \e[1;34m5)\e[0m  Найти IP или домены в листе"
            echo -e "  \e[1;34m6)\e[0m  Установить стратегию из файла (путь)"
            echo -e "  \e[1;34m7)\e[0m  Установить лист обхода из файла (путь)"
            echo -e "  \e[1;31m0)\e[0m  Выйти в меню"
            echo ""
            echo -e "\e[1;96m Сделано с любовью \e[0m by: \e[4;94mhttps://t.me/linux_hi\e[0m"
            echo ""

            read -p $'\e[1;36mВыберите действие: \e[0m' CHOICE
            case "$CHOICE" in
                1) configure_zapret_conf ;;
                2) configure_zapret_list ;;
                3) add_to_zapret ;;
                4) delete_from_zapret ;;
                5) search_in_zapret ;;
                6) configure_custom_conf_path ;;
                7) configure_custom_list_path ;;
                0) main_menu ;;
                *) echo -e "\e[1;31m Неверный ввод! Попробуйте снова.\e[0m"; sleep 2 ;;
            esac
        done
    fi
}

update_zapret_menu(){
    if [[ SYSTEM != openwrt ]]; then
        while true; do
            clear
            echo -e "\e[1;36m╔════════════════════════════════════╗"
            echo -e "║        🔄 Обновление Запрета       ║"
            echo -e "║         Текущая версия: $(if [ -f /opt/zapret-ver ]; then cat /opt/zapret-ver; else echo "Неизвестно";fi)       ║"

            echo -e "║       Последняя версия: $(get_latest_version)       ║"
            echo -e "╚════════════════════════════════════╝\e[0m"
            echo -e "  \e[1;33m1)\e[0m 🔧 Обновить \e[33mвсё\e[0m"
            echo -e "  \e[1;32m2)\e[0m 📜 Обновить только \e[32mскрипт\e[0m"
            echo -e "  \e[1;31m0)\e[0m 🚪 Выйти в меню"
            echo ""
            echo -e "\e[1;96m✨ Сделано с любовью 💙\e[0m by: \e[4;94mhttps://t.me/linux_hi\e[0m"
            echo ""
            read -p $'\e[1;36mВыберите действие: \e[0m' CHOICE
            case "$CHOICE" in
                1) update_zapret;;
                2) update_installed_script;;
                0) main_menu;;
                *) echo -e "\e[1;31m❌ Неверный ввод! Попробуйте снова.\e[0m"; sleep 2;;
            esac
        done
    else
        while true; do
            clear
            echo -e "\e[1;36m╔════════════════════════════════════╗"
            echo -e "║          Обновление Запрета        ║"

            echo -e "║         Текущая версия: $(if [ -f /opt/zapret-ver ]; then cat /opt/zapret-ver; else echo "Неизвестно";fi)       ║"

            echo -e "║       Последняя версия: $(get_latest_version)       ║"

            echo -e "╚════════════════════════════════════╝\e[0m"
            echo -e "  \e[1;33m1)\e[0m Обновить \e[33mвсё\e[0m"
            echo -e "  \e[1;32m2)\e[0m Обновить только \e[32mскрипт\e[0m"
            echo -e "  \e[1;31m0)\e[0m Выйти в меню"
            echo ""
            echo -e "\e[1;96m Сделано с любовью \e[0m by: \e[4;94mhttps://t.me/linux_hi\e[0m"
            echo ""
            read -p $'\e[1;36mВыберите действие: \e[0m' CHOICE
            case "$CHOICE" in
                1) update_zapret;;
                2) update_installed_script;;
                0) main_menu;;
                *) echo -e "\e[1;31m Неверный ввод! Попробуйте снова.\e[0m"; sleep 2;;
            esac
        done
    fi
} 
