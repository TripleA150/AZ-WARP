#!/bin/bash
# warper menus: ip-menu.sh
# Интерактивное меню управления IP-подсетями (CIDR).
# Добавление, удаление, синхронизация, смена режима, экспорт в AntiZapret.
# Подключается через source из warper.sh

# Главное меню управления IP-подсетями.
# Показывает статус синхронизации и предоставляет
# все операции с ip-ranges.txt и kernel routes.
ip_ranges_menu() {
    while true; do
        clear
        load_config

        local ip_cnt route_cnt sync_stat
        ip_cnt=$(count_ip_ranges)
        route_cnt=$(count_tun_routes)

        if ip_ranges_in_sync; then
            sync_stat="${GREEN}✅ синхронизированы${NC}"
        else
            sync_stat="${YELLOW}⚠️  не синхронизированы${NC}"
        fi

        local mode_label export_label
        case "$IP_ROUTE_MODE" in
            antizapret) mode_label="${GREEN}Только AntiZapret${NC}" ;;
            all_vpn)    mode_label="${CYAN}AntiZapret + FullVPN${NC}" ;;
            all)        mode_label="${YELLOW}Весь трафик сервера (Beta)${NC}" ;;
            *)          mode_label="${RED}неизвестно${NC}" ;;
        esac

        if [ "$IP_EXPORT_TO_ANTIZAPRET" = "y" ]; then
            export_label="${GREEN}ВКЛ${NC}"
        else
            export_label="${RED}ВЫКЛ${NC}"
        fi

        echo -e "${CYAN}================================================${NC}"
        echo -e "    🌐 ${YELLOW}УПРАВЛЕНИЕ IP-ПОДСЕТЯМИ${NC} 🌐"
        echo -e "${CYAN}================================================${NC}"
        echo -e ""
        echo -e " 📁 ${CYAN}Подсетей в файле:${NC}     ${YELLOW}${ip_cnt}${NC}"
        echo -e " 🔀 ${CYAN}Маршрутов активно:${NC}    ${YELLOW}${route_cnt}${NC}"
        echo -e " 📊 ${CYAN}Статус:${NC}               $sync_stat"
        echo -e ""
        echo -e "${CYAN}------------------------------------------------${NC}"
        echo -e " ${GREEN}1.${NC} ➕ Добавить подсеть"
        echo -e " ${RED}2.${NC} ➖ Удалить подсеть"
        echo -e " ${CYAN}3.${NC} 📋 Показать список подсетей"
        echo -e " ${CYAN}4.${NC} ✏️  Редактировать файл (nano)"
        echo -e " ${GREEN}5.${NC} 🔄 Синхронизировать (файл → маршруты)"
        echo -e " ${CYAN}6.${NC} 📊 Показать активные маршруты"
        echo -e " ${RED}7.${NC} 🗑️  Удалить все маршруты"
        echo -e " ${CYAN}8.${NC} 🎯 Режим применения: [$mode_label]"
        echo -e " ${CYAN}9.${NC} 📤 Экспорт в AntiZapret route-ips: [$export_label]"
        echo -e " ${CYAN}0.${NC} ↩️  Назад"
        echo -e "${CYAN}================================================${NC}"

        read -r -e -p "Выбор [0-9]: " ipchoice
        case "${ipchoice:-}" in

            # ── Добавить подсеть ──────────────────────────────────────────
            1)
                echo -e "\n${CYAN}Введите подсеть в формате A.B.C.D/M:${NC}"
                echo -e "${YELLOW}Примеры: 91.108.4.0/22  5.255.255.242/32  104.24.0.0/14${NC}"
                read -r -e -p "> " raw_cidr
                if [ -z "$raw_cidr" ]; then
                    echo -e "${YELLOW}Отмена.${NC}"
                    sleep 1
                    continue
                fi
                if add_ip_range "$raw_cidr"; then
                    if is_warper_active; then
                        echo -e "${CYAN}Применить маршрут сейчас?${NC}"
                        read -r -e -p "[Y/n]: " apply_now
                        if [[ -z "$apply_now" || "$apply_now" =~ ^[Yy]$ ]]; then
                            sync_ip_ranges
                        fi
                    else
                        echo -e "${YELLOW}WARPER выключен — маршрут будет применён при включении.${NC}"
                    fi
                fi
                read -r -p "Нажмите Enter..."
                ;;

            # ── Удалить подсеть ───────────────────────────────────────────
            2)
                echo -e "\n${CYAN}Текущие подсети:${NC}"
                local ranges_list
                ranges_list=$(extract_ip_ranges)
                if [ -z "$ranges_list" ]; then
                    echo -e "${YELLOW}Список пуст.${NC}"
                    read -r -p "Нажмите Enter..."
                    continue
                fi

                local idx=1
                local -a ranges_array
                mapfile -t ranges_array <<< "$ranges_list"
                for r in "${ranges_array[@]}"; do
                    echo -e " ${GREEN}${idx}.${NC} $r"
                    ((idx++))
                done
                echo -e ""
                echo -e "${CYAN}Введите номер или CIDR для удаления (0 = отмена):${NC}"
                read -r -e -p "> " del_input

                if [ "$del_input" = "0" ] || [ -z "$del_input" ]; then
                    continue
                fi

                local to_remove=""
                if [[ "$del_input" =~ ^[0-9]+$ ]] && \
                   (( del_input >= 1 && del_input <= ${#ranges_array[@]} )); then
                    to_remove="${ranges_array[$((del_input-1))]}"
                else
                    to_remove="$del_input"
                fi

                if remove_ip_range "$to_remove"; then
                    if is_warper_active; then
                        echo -e "${CYAN}Удалить маршрут из ядра сейчас?${NC}"
                        read -r -e -p "[Y/n]: " apply_now
                        if [[ -z "$apply_now" || "$apply_now" =~ ^[Yy]$ ]]; then
                            sync_ip_ranges
                        fi
                    fi
                fi
                read -r -p "Нажмите Enter..."
                ;;

            # ── Показать список ───────────────────────────────────────────
            3)
                echo -e "\n${CYAN}--- Подсети в $IP_RANGES_FILE ---${NC}"
                local ranges
                ranges=$(extract_ip_ranges)
                if [ -n "$ranges" ]; then
                    echo "$ranges" | nl -ba
                else
                    echo -e "${YELLOW}Список пуст.${NC}"
                fi
                echo -e "${CYAN}--------------------------------${NC}"
                read -r -p "Нажмите Enter..."
                ;;

            # ── Редактировать в nano ──────────────────────────────────────
            4)
                local before_hash after_hash
                before_hash=$(extract_ip_ranges | sha256sum | awk '{print $1}')
                nano "$IP_RANGES_FILE"
                after_hash=$(extract_ip_ranges | sha256sum | awk '{print $1}')
                if [ "$before_hash" != "$after_hash" ]; then
                    echo -e "${GREEN}Файл изменён.${NC}"
                    if is_warper_active; then
                        echo -e "${CYAN}Синхронизировать маршруты?${NC}"
                        read -r -e -p "[Y/n]: " apply_now
                        if [[ -z "$apply_now" || "$apply_now" =~ ^[Yy]$ ]]; then
                            sync_ip_ranges
                        fi
                    fi
                else
                    echo -e "${YELLOW}Изменений нет.${NC}"
                fi
                sleep 1
                ;;

            # ── Синхронизировать ──────────────────────────────────────────
            5)
                sync_ip_ranges
                read -r -p "Нажмите Enter..."
                ;;

            # ── Показать активные маршруты ────────────────────────────────
            6)
                echo -e "\n${CYAN}--- Применённые WARPER IP-маршруты ---${NC}"
                local routes
                routes=$(get_current_tun_routes)
                if [ -n "$routes" ]; then
                    echo "$routes" | nl -ba
                else
                    echo -e "${YELLOW}Нет активных маршрутов.${NC}"
                fi
                echo -e "${CYAN}--------------------------------------${NC}"
                read -r -p "Нажмите Enter..."
                ;;

            # ── Удалить все маршруты ──────────────────────────────────────
            7)
                echo -e "\n${RED}Удалить ВСЕ пользовательские IP-маршруты?${NC}"
                read -r -e -p "Вы уверены? [y/N]: " confirm_del
                if [[ "$confirm_del" =~ ^[Yy]$ ]]; then
                    remove_all_ip_routes
                fi
                read -r -p "Нажмите Enter..."
                ;;

            # ── Сменить режим применения ──────────────────────────────────
            8)
                echo -e "\n${CYAN}Выберите, для каких клиентов применять IP-маршруты:${NC}"
                echo -e ""
                detect_client_subnets
                echo -e " ${GREEN}1.${NC} Только AntiZapret         (${AZ_CLIENT_NET})"
                echo -e " ${CYAN}2.${NC} AntiZapret + FullVPN       (${ALL_CLIENT_NET})"
                echo -e " ${YELLOW}3.${NC} Весь трафик сервера (Beta) (без ограничений по source)"
                echo -e " ${CYAN}0.${NC} Отмена"
                echo -e ""
                read -r -e -p "Выбор [0-3]: " mode_choice

                case "${mode_choice:-}" in
                    1) IP_ROUTE_MODE="antizapret" ;;
                    2) IP_ROUTE_MODE="all_vpn" ;;
                    3) IP_ROUTE_MODE="all" ;;
                    0) continue ;;
                    *)
                        echo -e "${RED}Неверный выбор.${NC}"
                        sleep 1
                        continue
                        ;;
                esac

                # Сохраняем в warper.conf
                if grep -q '^IP_ROUTE_MODE=' "$CONF_FILE" 2>/dev/null; then
                    sed -i "s/^IP_ROUTE_MODE=.*/IP_ROUTE_MODE=$IP_ROUTE_MODE/" "$CONF_FILE"
                else
                    echo "IP_ROUTE_MODE=$IP_ROUTE_MODE" >> "$CONF_FILE"
                fi

                echo -e "${GREEN}Режим изменён на: $IP_ROUTE_MODE${NC}"

                # Пересинхронизируем если есть активные маршруты
                if [ "$(count_ip_ranges)" -gt 0 ] && is_warper_active; then
                    echo -e "${CYAN}Пересинхронизация маршрутов...${NC}"
                    sync_ip_ranges
                fi
                read -r -p "Нажмите Enter..."
                ;;

            # ── Переключить экспорт в AntiZapret ─────────────────────────
            9)
                if [ "$IP_EXPORT_TO_ANTIZAPRET" = "y" ]; then
                    IP_EXPORT_TO_ANTIZAPRET="n"
                else
                    IP_EXPORT_TO_ANTIZAPRET="y"
                fi

                # Сохраняем в warper.conf
                if grep -q '^IP_EXPORT_TO_ANTIZAPRET=' "$CONF_FILE" 2>/dev/null; then
                    sed -i "s/^IP_EXPORT_TO_ANTIZAPRET=.*/IP_EXPORT_TO_ANTIZAPRET=$IP_EXPORT_TO_ANTIZAPRET/" \
                        "$CONF_FILE"
                else
                    echo "IP_EXPORT_TO_ANTIZAPRET=$IP_EXPORT_TO_ANTIZAPRET" >> "$CONF_FILE"
                fi

                echo -e "${GREEN}Экспорт в AntiZapret: $IP_EXPORT_TO_ANTIZAPRET${NC}"
                sync_ip_ranges_to_antizapret
                read -r -p "Нажмите Enter..."
                ;;

            # ── Назад ─────────────────────────────────────────────────────
            0) return ;;

            *)
                echo -e "${RED}Неверный выбор.${NC}"
                sleep 1
                ;;
        esac
    done
}
