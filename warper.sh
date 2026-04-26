#!/bin/bash

set -uo pipefail

SLAVE_DIR="/root/warperslave"
SLAVE_CONF="$SLAVE_DIR/slave.conf"
SINGBOX_SLAVE_CONF="/etc/sing-box-slave/config.json"
SERVICE_NAME="sing-box-slave"
REPO_URL="https://raw.githubusercontent.com/Liafanx/AZ-WARP/main"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

LOCK_FILE="/var/run/warperslave.lock"

acquire_lock() {
    exec 8>"$LOCK_FILE"
    if ! flock -n 8; then
        echo -e "${RED}Другой экземпляр warperslave уже запущен.${NC}" >&2
        exit 1
    fi
}

release_lock() {
    rm -f "$LOCK_FILE"
}

trap 'release_lock' EXIT
acquire_lock

# ===== Загрузка конфигурации =====

load_config_value() {
    local key="$1"
    grep -E "^${key}=" "$SLAVE_CONF" 2>/dev/null | tail -n1 | cut -d'=' -f2-
}

SLAVE_MODE=""
SLAVE_PORT=""
SS_PASSWORD=""

load_config() {
    if [ ! -f "$SLAVE_CONF" ]; then
        echo -e "${RED}Конфигурация warperslave не найдена: $SLAVE_CONF${NC}"
        echo -e "${YELLOW}Запустите установщик:${NC}"
        echo -e "  ${GREEN}curl -fsSL $REPO_URL/install-slave.sh | bash${NC}"
        exit 1
    fi
    SLAVE_MODE=$(load_config_value "SLAVE_MODE" | tr -d '[:space:]')
    SLAVE_PORT=$(load_config_value "SLAVE_PORT" | tr -d '[:space:]')
    SS_PASSWORD=$(load_config_value "SS_PASSWORD")
}

save_config() {
    {
        echo "SLAVE_MODE=$SLAVE_MODE"
        echo "SLAVE_PORT=$SLAVE_PORT"
        echo "SS_PASSWORD=$SS_PASSWORD"
    } > "$SLAVE_CONF"
    chmod 600 "$SLAVE_CONF"
}

# ===== Утилиты =====

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

check_port_available() {
    local port="$1"
    local current_pid
    current_pid=$(systemctl show -p MainPID "$SERVICE_NAME" 2>/dev/null | cut -d= -f2)
    if [ -n "$current_pid" ] && [ "$current_pid" != "0" ]; then
        # Исключаем порты занятые нашим же сервисом
        if ss -tlnp 2>/dev/null | grep ":${port} " | grep -v "pid=${current_pid}" | grep -q .; then
            return 1
        fi
        return 0
    fi
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        return 1
    fi
    return 0
}

ensure_port_open() {
    local port="$1"
    iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
    iptables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p udp --dport "$port" -j ACCEPT
}

remove_port_rules() {
    local port="$1"
    iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null && \
        iptables -D INPUT -p tcp --dport "$port" -j ACCEPT
    iptables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null && \
        iptables -D INPUT -p udp --dport "$port" -j ACCEPT
}

validate_singbox_config() {
    if ! command -v sing-box >/dev/null 2>&1; then return 1; fi
    sing-box check -c "$SINGBOX_SLAVE_CONF" >/dev/null 2>&1
}

find_warp_keys() {
    local address="" private_key=""

    if [ -f "/etc/wireguard/warp.conf" ]; then
        private_key=$(grep -m 1 '^PrivateKey' "/etc/wireguard/warp.conf" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
        address=$(grep -m 1 '^Address' "/etc/wireguard/warp.conf" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
        if [ -n "$private_key" ] && [ -n "$address" ]; then
            [[ ! "$address" =~ / ]] && address="${address}/32"
            echo "$address"
            echo "$private_key"
            return 0
        fi
    fi

    if [ -f "$SLAVE_DIR/wgcf/wgcf-profile.conf" ]; then
        address=$(grep -m 1 '^Address = ' "$SLAVE_DIR/wgcf/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
        private_key=$(grep -m 1 '^PrivateKey = ' "$SLAVE_DIR/wgcf/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
        if [ -n "$private_key" ] && [ -n "$address" ]; then
            echo "$address"
            echo "$private_key"
            return 0
        fi
    fi

    if [ -f "/root/wgcf-profile.conf" ]; then
        address=$(grep -m 1 '^Address = ' "/root/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
        private_key=$(grep -m 1 '^PrivateKey = ' "/root/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
        if [ -n "$private_key" ] && [ -n "$address" ]; then
            echo "$address"
            echo "$private_key"
            return 0
        fi
    fi

    return 1
}

# ===== Команды =====

status_cmd() {
    load_config
    local sb_run sb_en
    if systemctl is-active --quiet "$SERVICE_NAME"; then sb_run="running"; else sb_run="stopped"; fi
    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then sb_en="enabled"; else sb_en="disabled"; fi
    local ext_ip
    ext_ip=$(curl -s --max-time 3 ifconfig.me 2>/dev/null || echo "n/a")

    echo "=== WARPERSLAVE STATUS ==="
    echo "Mode:       $SLAVE_MODE"
    echo "Port:       $SLAVE_PORT"
    echo "Service:    $sb_run"
    echo "Autostart:  $sb_en"
    echo "SS key:     ${SS_PASSWORD:0:8}..."
    echo "External IP: $ext_ip"
}

switch_mode() {
    load_config
    local new_mode backup
    backup=$(mktemp /tmp/slave_config_backup.XXXXXX)
    cp -a "$SINGBOX_SLAVE_CONF" "$backup"

    if [ "$SLAVE_MODE" = "direct" ]; then
        new_mode="warp"
        echo -e "${YELLOW}Переключение на режим WARP...${NC}"

        # Получаем WARP-ключи
        local warp_address="" warp_private_key=""
        if existing_keys=$(find_warp_keys); then
            warp_address=$(echo "$existing_keys" | sed -n '1p')
            warp_private_key=$(echo "$existing_keys" | sed -n '2p')
        else
            echo -e "${RED}WARP-ключи не найдены!${NC}"
            echo -e "${YELLOW}Положите wgcf-profile.conf в $SLAVE_DIR/wgcf/ и попробуйте снова.${NC}"
            rm -f "$backup"
            return 1
        fi

        cat > "$SINGBOX_SLAVE_CONF" << WARPEOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "0.0.0.0",
      "listen_port": $SLAVE_PORT,
      "method": "2022-blake3-aes-128-gcm",
      "password": "$SS_PASSWORD"
    }
  ],
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "warp",
      "name": "warp-tun",
      "system": false,
      "mtu": 1420,
      "address": [ "$warp_address" ],
      "private_key": "$warp_private_key",
      "peers": [
        {
          "address": "162.159.192.1",
          "port": 2408,
          "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
          "allowed_ips": ["0.0.0.0/0"],
          "reserved": [0, 0, 0]
        }
      ]
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": [
      { "inbound": "ss-in", "outbound": "warp" }
    ],
    "final": "direct"
  }
}
WARPEOF
    else
        new_mode="direct"
        echo -e "${YELLOW}Переключение на режим Direct...${NC}"

        cat > "$SINGBOX_SLAVE_CONF" << DIRECTEOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "0.0.0.0",
      "listen_port": $SLAVE_PORT,
      "method": "2022-blake3-aes-128-gcm",
      "password": "$SS_PASSWORD"
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": [
      { "inbound": "ss-in", "outbound": "direct" }
    ],
    "final": "direct"
  }
}
DIRECTEOF
    fi

    chmod 600 "$SINGBOX_SLAVE_CONF"

    # Валидация
    if ! validate_singbox_config; then
        echo -e "${RED}Ошибка валидации конфига! Откат...${NC}"
        cp -a "$backup" "$SINGBOX_SLAVE_CONF"
        chmod 600 "$SINGBOX_SLAVE_CONF"
        rm -f "$backup"
        return 1
    fi

    # Обновляем конфиг
    SLAVE_MODE="$new_mode"
    save_config

    # Перезапуск
    systemctl restart "$SERVICE_NAME"
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "${GREEN}Режим переключен на: $new_mode${NC}"
    else
        echo -e "${RED}Ошибка перезапуска! Откат...${NC}"
        cp -a "$backup" "$SINGBOX_SLAVE_CONF"
        chmod 600 "$SINGBOX_SLAVE_CONF"
        SLAVE_MODE=$([ "$new_mode" = "warp" ] && echo "direct" || echo "warp")
        save_config
        systemctl restart "$SERVICE_NAME" >/dev/null 2>&1
        rm -f "$backup"
        return 1
    fi
    rm -f "$backup"
}

change_port() {
    load_config
    local old_port="$SLAVE_PORT"

    echo -e "${CYAN}Текущий порт: $old_port${NC}"
    read -r -p "Новый порт (или Enter для отмены): " new_port

    if [ -z "$new_port" ]; then
        echo -e "${YELLOW}Отмена.${NC}"
        return 0
    fi

    if ! validate_port "$new_port"; then
        echo -e "${RED}Некорректный порт! Допустимо: 1-65535.${NC}"
        return 1
    fi

    if [ "$new_port" = "$old_port" ]; then
        echo -e "${YELLOW}Порт не изменился.${NC}"
        return 0
    fi

    if ! check_port_available "$new_port"; then
        echo -e "${RED}Порт $new_port уже занят!${NC}"
        ss -tlnp 2>/dev/null | grep ":${new_port} " || true
        return 1
    fi

    # Обновляем конфиг
    local backup
    backup=$(mktemp /tmp/slave_config_backup.XXXXXX)
    cp -a "$SINGBOX_SLAVE_CONF" "$backup"

    if command -v jq >/dev/null 2>&1; then
        local tmp
        tmp=$(mktemp)
        if ! jq --argjson port "$new_port" '.inbounds[0].listen_port = $port' "$SINGBOX_SLAVE_CONF" > "$tmp"; then
            rm -f "$backup" "$tmp"
            echo -e "${RED}Ошибка обработки JSON!${NC}"
            return 1
        fi
        mv "$tmp" "$SINGBOX_SLAVE_CONF"
        chmod 600 "$SINGBOX_SLAVE_CONF"
    else
        sed -i "s|\"listen_port\": $old_port|\"listen_port\": $new_port|g" "$SINGBOX_SLAVE_CONF"
    fi

    # Валидация
    if ! validate_singbox_config; then
        echo -e "${RED}Ошибка валидации! Откат...${NC}"
        cp -a "$backup" "$SINGBOX_SLAVE_CONF"
        chmod 600 "$SINGBOX_SLAVE_CONF"
        rm -f "$backup"
        return 1
    fi

    # Обновляем firewall
    remove_port_rules "$old_port" 2>/dev/null || true
    ensure_port_open "$new_port"

    # Сохраняем
    SLAVE_PORT="$new_port"
    save_config

    # Перезапуск
    systemctl restart "$SERVICE_NAME"
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "${GREEN}Порт изменён: $old_port → $new_port${NC}"
    else
        echo -e "${RED}Ошибка перезапуска! Откат...${NC}"
        cp -a "$backup" "$SINGBOX_SLAVE_CONF"
        chmod 600 "$SINGBOX_SLAVE_CONF"
        remove_port_rules "$new_port" 2>/dev/null || true
        ensure_port_open "$old_port"
        SLAVE_PORT="$old_port"
        save_config
        systemctl restart "$SERVICE_NAME" >/dev/null 2>&1
    fi
    rm -f "$backup"
}

change_key() {
    load_config
    echo -e "${CYAN}Текущий ключ: ${SS_PASSWORD:0:8}...${NC}"
    echo -e ""
    echo -e " ${GREEN}1.${NC} Сгенерировать новый"
    echo -e " ${GREEN}2.${NC} Ввести вручную"
    echo -e " ${CYAN}0.${NC} Отмена"

    read -r -p "Выбор: " key_action

    local new_key=""
    case "${key_action:-}" in
        1) new_key=$(openssl rand -base64 16) ;;
        2)
            read -r -p "Введите ключ: " new_key
            if [ -z "$new_key" ]; then
                echo -e "${YELLOW}Отмена.${NC}"
                return 0
            fi
            ;;
        0) return 0 ;;
        *) echo -e "${RED}Неверный выбор.${NC}"; return 1 ;;
    esac

    # Обновляем конфиг
    local backup
    backup=$(mktemp /tmp/slave_config_backup.XXXXXX)
    cp -a "$SINGBOX_SLAVE_CONF" "$backup"

    if command -v jq >/dev/null 2>&1; then
        local tmp
        tmp=$(mktemp)
        if ! jq --arg pwd "$new_key" '.inbounds[0].password = $pwd' "$SINGBOX_SLAVE_CONF" > "$tmp"; then
            rm -f "$backup" "$tmp"
            echo -e "${RED}Ошибка обработки JSON!${NC}"
            return 1
        fi
        mv "$tmp" "$SINGBOX_SLAVE_CONF"
        chmod 600 "$SINGBOX_SLAVE_CONF"
    else
        # Fallback: sed
        local old_escaped new_escaped
        old_escaped=$(printf '%s\n' "$SS_PASSWORD" | sed 's/[[\.*^$()+?{|\\]/\\&/g')
        new_escaped=$(printf '%s\n' "$new_key" | sed 's/[&/\]/\\&/g')
        sed -i "s|\"password\": \"$old_escaped\"|\"password\": \"$new_escaped\"|g" "$SINGBOX_SLAVE_CONF"
    fi

    if ! validate_singbox_config; then
        echo -e "${RED}Ошибка валидации! Откат...${NC}"
        cp -a "$backup" "$SINGBOX_SLAVE_CONF"
        chmod 600 "$SINGBOX_SLAVE_CONF"
        rm -f "$backup"
        return 1
    fi

    SS_PASSWORD="$new_key"
    save_config

    systemctl restart "$SERVICE_NAME"
    sleep 2

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "${GREEN}Ключ обновлён!${NC}"
        echo -e "${YELLOW}Новый ключ: ${new_key}${NC}"
        echo -e ""
        echo -e "${RED}================================================${NC}"
        echo -e "${RED}⚠️  Не забудьте обновить ключ на основном${NC}"
        echo -e "${RED}   WARPER-сервере! (warper → Настройки →${NC}"
        echo -e "${RED}   Режим маршрутизации → Slave)${NC}"
        echo -e "${RED}================================================${NC}"
    else
        echo -e "${RED}Ошибка перезапуска! Откат...${NC}"
        cp -a "$backup" "$SINGBOX_SLAVE_CONF"
        chmod 600 "$SINGBOX_SLAVE_CONF"
        SS_PASSWORD=$(load_config_value "SS_PASSWORD")
        systemctl restart "$SERVICE_NAME" >/dev/null 2>&1
    fi
    rm -f "$backup"
}

uninstall_cmd() {
    if [ -f "$SLAVE_DIR/uninstall-slave.sh" ]; then
        exec bash "$SLAVE_DIR/uninstall-slave.sh"
    else
        exec bash -c "curl -fsSL '$REPO_URL/uninstall-slave.sh?t=$(date +%s)' | bash"
    fi
}

show_logs() {
    echo -e "\n${CYAN}==========================================${NC}"
    echo -e "${YELLOW}Логи $SERVICE_NAME...${NC}"
    echo -e "${GREEN}Ctrl+C для выхода${NC}"
    echo -e "${CYAN}==========================================${NC}\n"
    trap 'echo -e "\n${CYAN}Возврат в меню...${NC}"' SIGINT
    journalctl -u "$SERVICE_NAME" -n 30 -f
    trap - SIGINT
}

doctor_cmd() {
    load_config
    echo -e "${CYAN}==========================================${NC}"
    echo -e "      🩺 ${YELLOW}WARPERSLAVE DOCTOR${NC}"
    echo -e "${CYAN}==========================================${NC}"
    local failed=0
    check_item() {
        local label="$1" cmd="$2"
        if eval "$cmd" >/dev/null 2>&1; then
            echo -e " ${GREEN}✔${NC} $label"
        else
            echo -e " ${RED}✘${NC} $label"
            failed=1
        fi
    }
    check_item "Конфигурация slave существует" "[ -f '$SLAVE_CONF' ]"
    check_item "Конфиг sing-box-slave существует" "[ -f '$SINGBOX_SLAVE_CONF' ]"
    check_item "Конфиг sing-box-slave валиден" "validate_singbox_config"
    check_item "Служба $SERVICE_NAME активна" "systemctl is-active --quiet '$SERVICE_NAME'"
    check_item "Автозагрузка $SERVICE_NAME включена" "systemctl is-enabled --quiet '$SERVICE_NAME'"
    check_item "Порт $SLAVE_PORT слушается" "ss -tlnp 2>/dev/null | grep -q ':${SLAVE_PORT} '"
    check_item "Права $SLAVE_CONF (600)" "[ \"\$(stat -c %a '$SLAVE_CONF' 2>/dev/null)\" = '600' ]"
    check_item "Права $SINGBOX_SLAVE_CONF (600)" "[ \"\$(stat -c %a '$SINGBOX_SLAVE_CONF' 2>/dev/null)\" = '600' ]"

    if [ "$SLAVE_MODE" = "warp" ]; then
        local has_warp=false
        if find_warp_keys >/dev/null 2>&1; then has_warp=true; fi
        if [ "$has_warp" = true ]; then
            echo -e " ${GREEN}✔${NC} WARP-ключи доступны"
        else
            echo -e " ${RED}✘${NC} WARP-ключи не найдены (режим: warp)"
            failed=1
        fi
    fi

    echo -e "${CYAN}------------------------------------------${NC}"
    if [ "$failed" -eq 0 ]; then
        echo -e "${GREEN}Проблем не обнаружено.${NC}"
    else
        echo -e "${YELLOW}Обнаружены проблемы.${NC}"
    fi
}

# ===== Главное меню =====

show_menu() {
    load_config
    clear
    local sb_status mode_display
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        sb_status="${GREEN}🟢 запущен${NC}"
    else
        sb_status="${RED}🔴 остановлен${NC}"
    fi
    if [ "$SLAVE_MODE" = "warp" ]; then
        mode_display="${CYAN}WARP${NC}"
    else
        mode_display="${GREEN}Direct${NC}"
    fi

    echo -e "${CYAN}================================================${NC}"
    echo -e "    🔧 ${YELLOW}WARPERSLAVE — Панель управления${NC} 🔧"
    echo -e "${CYAN}================================================${NC}"
    echo -e ""
    echo -e " 📡 ${CYAN}Статус:${NC}   $sb_status"
    echo -e " 🔀 ${CYAN}Режим:${NC}    $mode_display"
    echo -e " 🔌 ${CYAN}Порт:${NC}     ${YELLOW}${SLAVE_PORT}${NC}"
    echo -e " 🔑 ${CYAN}Ключ:${NC}     ${YELLOW}${SS_PASSWORD:0:8}...${NC}"
    echo -e ""
    echo -e "${CYAN}------------------------------------------------${NC}"
    echo -e " ${GREEN}1.${NC} 🔀 Переключить режим (Direct ↔ WARP)"
    echo -e " ${CYAN}2.${NC} 🔌 Изменить порт"
    echo -e " ${CYAN}3.${NC} 🔑 Изменить ключ Shadowsocks"
    echo -e " ${CYAN}4.${NC} 👁️  Показать полный ключ"
    echo -e " ${CYAN}5.${NC} 🔄 Перезапустить службу"
    echo -e " ${CYAN}6.${NC} 📄 Показать логи"
    echo -e " ${CYAN}D.${NC} 🩺 Диагностика"
    echo -e " ${CYAN}S.${NC} 📊 Статус"
    echo -e "${CYAN}------------------------------------------------${NC}"
    echo -e " ${RED}U.${NC} 🗑️  Удалить warperslave"
    echo -e " ${CYAN}0.${NC} 🚪 Выход"
    echo -e "${CYAN}================================================${NC}"
}

# ===== CLI-обработка =====

case "${1:-}" in
    status) load_config; status_cmd; exit $? ;;
    switch) switch_mode; exit $? ;;
    port) change_port; exit $? ;;
    key) change_key; exit $? ;;
    doctor) doctor_cmd; exit $? ;;
    uninstall) uninstall_cmd; exit $? ;;
    help|--help|-h)
        echo "Использование: warperslave [команда]"
        echo ""
        echo "Команды:"
        echo "  status     Показать статус"
        echo "  switch     Переключить режим (Direct ↔ WARP)"
        echo "  port       Изменить порт"
        echo "  key        Изменить ключ Shadowsocks"
        echo "  doctor     Диагностика"
        echo "  uninstall  Удалить warperslave"
        echo "  help       Показать эту справку"
        echo ""
        echo "Без аргументов — интерактивное меню."
        exit 0
        ;;
esac

# ===== Интерактивное меню =====

while true; do
    show_menu
    read -r -e -p "Выбор: " choice
    choice=$(echo "${choice:-}" | tr -d ' ')
    case "$choice" in
        1) switch_mode; read -r -p "Нажмите Enter..." ;;
        2) change_port; read -r -p "Нажмите Enter..." ;;
        3) change_key; read -r -p "Нажмите Enter..." ;;
        4) load_config; echo -e "\n${CYAN}Полный ключ Shadowsocks:${NC} ${YELLOW}${SS_PASSWORD}${NC}"; read -r -p "Нажмите Enter..." ;;
        5)
            echo -e "${YELLOW}Перезапуск $SERVICE_NAME...${NC}"
            systemctl restart "$SERVICE_NAME"
            sleep 2
            if systemctl is-active --quiet "$SERVICE_NAME"; then
                echo -e "${GREEN}Перезапущено.${NC}"
            else
                echo -e "${RED}Ошибка перезапуска!${NC}"
                journalctl -u "$SERVICE_NAME" -n 10 --no-pager 2>/dev/null || true
            fi
            read -r -p "Нажмите Enter..."
            ;;
        6) show_logs ;;
        d|D) doctor_cmd; read -r -p "Нажмите Enter..." ;;
        s|S) status_cmd; read -r -p "Нажмите Enter..." ;;
        u|U) uninstall_cmd ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
    esac
done
