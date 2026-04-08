#!/bin/bash

set -u

WARPER_DIR="/root/warper"
DOWNLOAD_DIR="$WARPER_DIR/download"
WGCF_DIR="$WARPER_DIR/wgcf"
MASTER_FILE="$WARPER_DIR/domains.txt"
ACTIVE_FILE="/etc/knot-resolver/warper-domains.txt"
KRESD_CONF="/etc/knot-resolver/kresd.conf"
KRESD_BACKUP="/etc/knot-resolver/kresd.conf.warper.bak"
AZ_INC="/root/antizapret/config/include-ips.txt"
SINGBOX_CONF="/etc/sing-box/config.json"
SINGBOX_TEMPLATE="$WARPER_DIR/config.json.template"
REPO_URL="https://raw.githubusercontent.com/Liafanx/AZ-WARP/main"
LOCAL_VER=$(cat "$WARPER_DIR/version" 2>/dev/null | tr -d '\r\n' || echo "0.0.0")
CONF_FILE="$WARPER_DIR/warper.conf"

SUBNET="198.18.0.0/24"
TUN_IP="198.18.0.1/24"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

REMOTE_VER_CACHE=""
REMOTE_VER_TIME=0

if [ ! -f "$MASTER_FILE" ]; then
cat << 'EOF' > "$MASTER_FILE"
# ==========================================
# СПИСОК ДОМЕНОВ ДЛЯ МАРШРУТИЗАЦИИ WARP
# Строки, начинающиеся с '#', игнорируются.
# ⚠️ НЕ удаляйте служебные маркеры блоков GEMINI/CHATGPT
# ==========================================

# Пользовательские домены:
EOF
fi

load_config() {
    if [ ! -f "$CONF_FILE" ]; then
        return 0
    fi

    local value
    value=$(grep -E '^SUBNET=' "$CONF_FILE" | tail -n1 | cut -d'=' -f2- | tr -d '"'\''[:space:]')
    if [ -n "$value" ] && validate_subnet "$value"; then
        SUBNET="$value"
    fi

    value=$(grep -E '^TUN_IP=' "$CONF_FILE" | tail -n1 | cut -d'=' -f2- | tr -d '"'\''[:space:]')
    if [ -n "$value" ]; then
        TUN_IP="$value"
    else
        TUN_IP=$(calculate_tun_ip "$SUBNET")
    fi
}

escape_regex() {
    printf '%s' "$1" | sed 's/[.[\*^$()+?{|\\]/\\&/g'
}

validate_domain() {
    local domain="$1"
    domain=$(echo "$domain" | xargs)
    domain="${domain%.}"
    domain=$(echo "$domain" | tr '[:upper:]' '[:lower:]')

    if [ -z "$domain" ]; then
        return 1
    fi
    if [[ ! "$domain" =~ \. ]]; then
        return 1
    fi
    if [[ "$domain" =~ \.\. ]]; then
        return 1
    fi
    if [[ "$domain" =~ ^- || "$domain" =~ -$ ]]; then
        return 1
    fi
    if [[ ! "$domain" =~ ^[a-z0-9._-]+$ ]]; then
        return 1
    fi

    IFS='.' read -r -a labels <<< "$domain"
    local label
    for label in "${labels[@]}"; do
        if [ -z "$label" ] || [ ${#label} -gt 63 ]; then
            return 1
        fi
        if [[ "$label" =~ ^- || "$label" =~ -$ ]]; then
            return 1
        fi
        if [[ ! "$label" =~ ^[a-z0-9_-]+$ ]]; then
            return 1
        fi
    done

    echo "$domain"
    return 0
}

validate_subnet() {
    local subnet="$1"
    if [[ ! "$subnet" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.0/([0-9]{1,2})$ ]]; then
        return 1
    fi
    local o1="${BASH_REMATCH[1]}" o2="${BASH_REMATCH[2]}" o3="${BASH_REMATCH[3]}" mask="${BASH_REMATCH[4]}"
    if (( o1 > 255 || o2 > 255 || o3 > 255 || mask < 1 || mask > 32 )); then
        return 1
    fi
    return 0
}

validate_mtu() {
    local mtu="$1"
    if [[ ! "$mtu" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    if (( mtu < 1280 || mtu > 1500 )); then
        return 1
    fi
    return 0
}

calculate_tun_ip() {
    local subnet="$1"
    local base="${subnet%.*}"
    local mask="${subnet##*/}"
    echo "${base}.1/${mask}"
}

has_list_block() {
    local list_name="$1"
    grep -qxF "# --- ${list_name^^} ---" "$MASTER_FILE" 2>/dev/null
}

normalize_include_ips() {
    local file="$1"
    local tmp
    [ -f "$file" ] || return 0
    tmp=$(mktemp)
    awk 'NF && !seen[$0]++' "$file" > "$tmp" && mv "$tmp" "$file"
}

extract_user_domains() {
    local input="$1"
    awk '
    BEGIN { in_block=0 }
    /^# --- [A-Z0-9_]+ ---$/ { in_block=1; next }
    /^# --- END [A-Z0-9_]+ ---$/ { in_block=0; next }
    {
        if (in_block) next
        if ($0 ~ /^\s*$/) next
        if ($0 ~ /^\s*#/) next
        print
    }
    ' "$input" | while IFS= read -r line; do
        validate_domain "$line" 2>/dev/null || true
    done | sort -u
}

extract_block() {
    local input="$1"
    local list_name="$2"
    local marker="# --- ${list_name^^} ---"
    local end_marker="# --- END ${list_name^^} ---"

    awk -v start="$marker" -v end="$end_marker" '
    $0 == start { in_block=1 }
    in_block { print }
    $0 == end { in_block=0 }
    ' "$input"
}

rebuild_master_file() {
    local source_file="${1:-$MASTER_FILE}"
    local output_file="${2:-$MASTER_FILE}"
    local tmp user_tmp gemini_tmp chatgpt_tmp
    tmp=$(mktemp)
    user_tmp=$(mktemp)
    gemini_tmp=$(mktemp)
    chatgpt_tmp=$(mktemp)

    extract_user_domains "$source_file" > "$user_tmp"
    extract_block "$source_file" "gemini" > "$gemini_tmp"
    extract_block "$source_file" "chatgpt" > "$chatgpt_tmp"

    {
        cat << 'EOF'
# ==========================================
# СПИСОК ДОМЕНОВ ДЛЯ МАРШРУТИЗАЦИИ WARP
# Строки, начинающиеся с '#', игнорируются.
# ⚠️ НЕ удаляйте служебные маркеры блоков GEMINI/CHATGPT
# ==========================================

# Пользовательские домены:
EOF

        if [ -s "$user_tmp" ]; then
            cat "$user_tmp"
        fi

        if [ -s "$gemini_tmp" ]; then
            echo ""
            cat "$gemini_tmp"
        fi

        if [ -s "$chatgpt_tmp" ]; then
            echo ""
            cat "$chatgpt_tmp"
        fi
    } > "$tmp"

    mv "$tmp" "$output_file"
    rm -f "$user_tmp" "$gemini_tmp" "$chatgpt_tmp"
}

canonical_master_hash() {
    local tmp
    tmp=$(mktemp)
    rebuild_master_file "$MASTER_FILE" "$tmp"
    sha256sum "$tmp" | awk '{print $1}'
    rm -f "$tmp"
}

insert_user_domain() {
    local domain="$1"
    local tmp
    tmp=$(mktemp)
    rebuild_master_file "$MASTER_FILE" "$tmp"

    if extract_user_domains "$tmp" | grep -qxF "$domain"; then
        mv "$tmp" "$MASTER_FILE"
        return 0
    fi

    awk -v domain="$domain" '
    BEGIN { inserted=0 }
    {
        print
        if ($0 == "# Пользовательские домены:" && inserted == 0) {
            print domain
            inserted=1
        }
    }
    ' "$tmp" > "${tmp}.new"

    mv "${tmp}.new" "$tmp"
    rebuild_master_file "$tmp" "$MASTER_FILE"
    rm -f "$tmp"
}

get_log_level() {
    if [ -f "$SINGBOX_CONF" ] && command -v jq >/dev/null 2>&1; then
        jq -r '.log.level // "info"' "$SINGBOX_CONF" 2>/dev/null || echo "info"
    else
        echo "info"
    fi
}

set_log_level() {
    local new_level="$1"

    case "$new_level" in
        debug|info|warn|error) ;;
        *)
            echo -e "${RED}Некорректный log level: $new_level${NC}"
            return 1
            ;;
    esac

    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${RED}jq не найден. Невозможно безопасно изменить log level.${NC}"
        return 1
    fi

    if [ ! -f "$SINGBOX_CONF" ]; then
        echo -e "${RED}Файл $SINGBOX_CONF не найден.${NC}"
        return 1
    fi

    local backup tmp old_level
    backup=$(mktemp /tmp/singbox_config_backup.XXXXXX)
    tmp=$(mktemp /tmp/singbox_config_new.XXXXXX)

    cp -a "$SINGBOX_CONF" "$backup" || {
        rm -f "$backup" "$tmp"
        echo -e "${RED}Не удалось создать backup config.json.${NC}"
        return 1
    }

    old_level=$(get_log_level)

    if [ "$old_level" = "$new_level" ]; then
        rm -f "$backup" "$tmp"
        echo -e "${YELLOW}log level уже установлен: $new_level${NC}"
        return 0
    fi

    if ! jq --arg lvl "$new_level" '.log.level = $lvl' "$SINGBOX_CONF" > "$tmp"; then
        rm -f "$backup" "$tmp"
        echo -e "${RED}Не удалось обновить log level в config.json.${NC}"
        return 1
    fi

    mv "$tmp" "$SINGBOX_CONF"
    chmod 600 "$SINGBOX_CONF"

    if ! validate_singbox_config; then
        cp -a "$backup" "$SINGBOX_CONF"
        chmod 600 "$SINGBOX_CONF"
        rm -f "$backup"
        echo -e "${RED}Новый config.json не прошёл валидацию, выполнен откат.${NC}"
        return 1
    fi

    systemctl restart sing-box
    if ! ensure_singbox_running; then
        cp -a "$backup" "$SINGBOX_CONF"
        chmod 600 "$SINGBOX_CONF"
        systemctl restart sing-box >/dev/null 2>&1 || true
        rm -f "$backup"
        echo -e "${RED}sing-box не запустился после смены log level, выполнен откат.${NC}"
        return 1
    fi

    ensure_iptables_rule FORWARD -o singbox-tun
    ensure_iptables_rule FORWARD -i singbox-tun
    systemctl restart kresd@1 kresd@2 >/dev/null 2>&1 || true

    rm -f "$backup"
    echo -e "${GREEN}log level изменён: ${old_level} → ${new_level}${NC}"
    return 0
}

get_mtu() {
    if [ -f "$SINGBOX_CONF" ] && command -v jq >/dev/null 2>&1; then
        jq -r '.endpoints[0].mtu // 1420' "$SINGBOX_CONF" 2>/dev/null || echo "1420"
    else
        echo "1420"
    fi
}

set_mtu() {
    local new_mtu="$1"

    if ! validate_mtu "$new_mtu"; then
        echo -e "${RED}Некорректный MTU: $new_mtu (допустимо 1280-1500)${NC}"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${RED}jq не найден. Невозможно безопасно изменить MTU.${NC}"
        return 1
    fi

    if [ ! -f "$SINGBOX_CONF" ]; then
        echo -e "${RED}Файл $SINGBOX_CONF не найден.${NC}"
        return 1
    fi

    local backup tmp old_mtu
    backup=$(mktemp /tmp/singbox_config_backup.XXXXXX)
    tmp=$(mktemp /tmp/singbox_config_new.XXXXXX)

    cp -a "$SINGBOX_CONF" "$backup" || {
        rm -f "$backup" "$tmp"
        echo -e "${RED}Не удалось создать backup config.json.${NC}"
        return 1
    }

    old_mtu=$(get_mtu)

    if [ "$old_mtu" = "$new_mtu" ]; then
        rm -f "$backup" "$tmp"
        echo -e "${YELLOW}MTU уже установлен: $new_mtu${NC}"
        return 0
    fi

    if ! jq --argjson mtu "$new_mtu" '.endpoints[0].mtu = $mtu' "$SINGBOX_CONF" > "$tmp"; then
        rm -f "$backup" "$tmp"
        echo -e "${RED}Не удалось обновить MTU в config.json.${NC}"
        return 1
    fi

    mv "$tmp" "$SINGBOX_CONF"
    chmod 600 "$SINGBOX_CONF"

    if ! validate_singbox_config; then
        cp -a "$backup" "$SINGBOX_CONF"
        chmod 600 "$SINGBOX_CONF"
        rm -f "$backup"
        echo -e "${RED}Новый config.json не прошёл валидацию, выполнен откат.${NC}"
        return 1
    fi

    systemctl restart sing-box
    if ! ensure_singbox_running; then
        cp -a "$backup" "$SINGBOX_CONF"
        chmod 600 "$SINGBOX_CONF"
        systemctl restart sing-box >/dev/null 2>&1 || true
        rm -f "$backup"
        echo -e "${RED}sing-box не запустился после смены MTU, выполнен откат.${NC}"
        return 1
    fi

    ensure_iptables_rule FORWARD -o singbox-tun
    ensure_iptables_rule FORWARD -i singbox-tun
    systemctl restart kresd@1 kresd@2 >/dev/null 2>&1 || true

    rm -f "$backup"
    echo -e "${GREEN}MTU изменён: ${old_mtu} → ${new_mtu}${NC}"
    return 0
}

version_gt() {
    [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" != "$1" ]
}

get_remote_version() {
    local now
    now=$(date +%s)
    if (( now - REMOTE_VER_TIME > 300 )) || [ -z "$REMOTE_VER_CACHE" ]; then
        REMOTE_VER_CACHE=$(curl -s --max-time 2 "$REPO_URL/version?t=$now" | tr -d '\r\n')
        REMOTE_VER_TIME=$now
    fi
    echo "${REMOTE_VER_CACHE:-$LOCAL_VER}"
}

download_file_safe() {
    local url="$1" dest="$2" desc="$3"
    local tmp
    tmp=$(mktemp)

    if ! curl -fsSL -o "$tmp" "${url}?t=$(date +%s)"; then
        echo -e "${RED}Ошибка загрузки: ${desc}${NC}"
        rm -f "$tmp"
        return 1
    fi

    if [ ! -s "$tmp" ]; then
        echo -e "${RED}Загруженный файл пуст: ${desc}${NC}"
        rm -f "$tmp"
        return 1
    fi

    mv "$tmp" "$dest"
    return 0
}

filter_valid_domains_file() {
    local input="$1"
    local output="$2"
    : > "$output"

    while IFS= read -r line; do
        local trimmed clean
        trimmed=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$trimmed" ] && continue
        [[ "$trimmed" =~ ^# ]] && continue
        clean=$(validate_domain "$trimmed" 2>/dev/null || true)
        [ -n "$clean" ] && echo "$clean" >> "$output"
    done < "$input"

    sort -u -o "$output" "$output"
}

sync_domains() {
    local tmp
    tmp=$(mktemp /tmp/warper_sync.XXXXXX)
    filter_valid_domains_file "$MASTER_FILE" "$tmp"
    mv "$tmp" "$ACTIVE_FILE"
    chmod 644 "$ACTIVE_FILE"
}

domains_in_sync() {
    local tmp_master tmp_active
    tmp_master=$(mktemp /tmp/warper_master_compare.XXXXXX)
    tmp_active=$(mktemp /tmp/warper_active_compare.XXXXXX)

    filter_valid_domains_file "$MASTER_FILE" "$tmp_master"
    if [ -f "$ACTIVE_FILE" ]; then
        filter_valid_domains_file "$ACTIVE_FILE" "$tmp_active"
    else
        : > "$tmp_active"
    fi

    local result=1
    if cmp -s "$tmp_master" "$tmp_active"; then
        result=0
    fi

    rm -f "$tmp_master" "$tmp_active"
    return "$result"
}

subnet_conflicts() {
    local subnet="$1"
    local line iface route_net

    while IFS= read -r line; do
        iface=$(echo "$line" | awk '{print $2}')
        route_net=$(echo "$line" | awk '{print $4}')
        [ "$route_net" = "$subnet" ] || continue
        [ "$iface" = "singbox-tun" ] && continue
        return 0
    done < <(ip -o -4 addr show 2>/dev/null)

    while IFS= read -r line; do
        route_net=$(echo "$line" | awk '{print $1}')
        [ "$route_net" = "$subnet" ] || continue
        echo "$line" | grep -q "dev singbox-tun" && continue
        return 0
    done < <(ip route 2>/dev/null)

    if command -v docker >/dev/null 2>&1; then
        local ids
        ids=$(docker network ls -q 2>/dev/null || true)
        if [ -n "$ids" ]; then
            docker network inspect $ids 2>/dev/null | grep -qF "\"Subnet\": \"$subnet\"" && return 0
        fi
    fi

    return 1
}

validate_singbox_config() {
    if ! command -v sing-box >/dev/null 2>&1; then
        echo -e "${RED}sing-box не найден.${NC}"
        return 1
    fi
    if ! sing-box check -c "$SINGBOX_CONF" >/dev/null 2>&1; then
        echo -e "${RED}Конфигурация sing-box не прошла проверку.${NC}"
        return 1
    fi
    return 0
}

ensure_singbox_running() {
    if ! systemctl is-active --quiet sing-box; then
        echo -e "${RED}Служба sing-box не запустилась.${NC}"
        journalctl -u sing-box -n 30 --no-pager 2>/dev/null || true
        return 1
    fi
    return 0
}

ensure_iptables_rule() {
    local chain="$1" iface_flag="$2" iface_name="$3"
    iptables -C "$chain" "$iface_flag" "$iface_name" -j ACCEPT 2>/dev/null || \
        iptables -I "$chain" "$iface_flag" "$iface_name" -j ACCEPT
}

remove_iptables_rule() {
    local chain="$1" iface_flag="$2" iface_name="$3"
    iptables -C "$chain" "$iface_flag" "$iface_name" -j ACCEPT 2>/dev/null && \
        iptables -D "$chain" "$iface_flag" "$iface_name" -j ACCEPT
}

get_warp_credentials() {
    local address="" private_key=""

    if command -v jq >/dev/null 2>&1 && [ -f "$SINGBOX_CONF" ]; then
        address=$(jq -r '.endpoints[] | select(.tag=="warp") | .address[0] // empty' "$SINGBOX_CONF" 2>/dev/null || true)
        private_key=$(jq -r '.endpoints[] | select(.tag=="warp") | .private_key // empty' "$SINGBOX_CONF" 2>/dev/null || true)
    fi

    if [ -z "$address" ] || [ -z "$private_key" ]; then
        if [ -f "$SINGBOX_CONF" ]; then
            address=$(grep -o '"address": \[ "[^"]*"' "$SINGBOX_CONF" | head -1 | sed 's/.*"\([^"]*\)".*/\1/' || true)
            private_key=$(grep -o '"private_key": "[^"]*"' "$SINGBOX_CONF" | head -1 | sed 's/.*"\([^"]*\)".*/\1/' || true)
        fi
    fi

    if [ -z "$address" ] || [ -z "$private_key" ] || [ "$address" = "__WARP_ADDRESS__" ]; then
        local wgcf_profile="$WGCF_DIR/wgcf-profile.conf"
        if [ -f "$wgcf_profile" ]; then
            address=$(grep -m 1 '^Address = ' "$wgcf_profile" | awk '{print $3}' | tr -d '\r\n')
            private_key=$(grep -m 1 '^PrivateKey = ' "$wgcf_profile" | awk '{print $3}' | tr -d '\r\n')
        fi
    fi

    if [ -z "$address" ] || [ -z "$private_key" ]; then
        return 1
    fi

    echo "$address"
    echo "$private_key"
    return 0
}

rebuild_config() {
    local template="$1"

    local creds
    creds=$(get_warp_credentials) || {
        echo -e "${RED}Ошибка: Не удалось извлечь WARP-ключи!${NC}"
        echo -e "${YELLOW}Проверьте наличие файла $WGCF_DIR/wgcf-profile.conf${NC}"
        return 1
    }

    local warp_address warp_private_key
    warp_address=$(echo "$creds" | sed -n '1p')
    warp_private_key=$(echo "$creds" | sed -n '2p')

    sed \
        -e "s|__WARP_ADDRESS__|$warp_address|g" \
        -e "s|__WARP_PRIVATE_KEY__|$warp_private_key|g" \
        -e "s|__SUBNET__|$SUBNET|g" \
        -e "s|__TUN_IP__|$TUN_IP|g" \
        "$template" > "$SINGBOX_CONF"

    chmod 600 "$SINGBOX_CONF"

    if ! validate_singbox_config; then
        return 1
    fi

    echo -e "${GREEN}Конфигурация sing-box успешно обновлена.${NC}"
    return 0
}

backup_kresd() {
    if [ -f "$KRESD_CONF" ] && [ ! -f "$KRESD_BACKUP" ]; then
        cp -a "$KRESD_CONF" "$KRESD_BACKUP" || return 1
        chmod 644 "$KRESD_BACKUP" 2>/dev/null || true
    fi
    return 0
}

restore_kresd_backup() {
    if [ -f "$KRESD_BACKUP" ]; then
        cp -a "$KRESD_BACKUP" "$KRESD_CONF" || return 1
        chmod 644 "$KRESD_CONF" 2>/dev/null || true
        systemctl restart kresd@1 kresd@2 || return 1
        return 0
    fi
    return 1
}

file_mode_is_600() {
    local file="$1"
    [ -f "$file" ] || return 1
    [ "$(stat -c %a "$file" 2>/dev/null || true)" = "600" ]
}

status_cmd() {
    load_config

    local sb_run sb_en kr_stat dom_stat az_stat ap_stat subnet_conflict log_level mtu
    if systemctl is-active --quiet sing-box; then sb_run="running"; else sb_run="stopped"; fi
    if systemctl is-enabled --quiet sing-box 2>/dev/null; then sb_en="enabled"; else sb_en="disabled"; fi
    if grep -q "WARP-MOD-START" "$KRESD_CONF" 2>/dev/null; then kr_stat="patched"; else kr_stat="not patched"; fi
    if domains_in_sync; then dom_stat="synced"; else dom_stat="not synced"; fi
    if grep -qF "$SUBNET" "$AZ_INC" 2>/dev/null; then az_stat="present"; else az_stat="missing"; fi
    if systemctl is-enabled --quiet warper-autopatch 2>/dev/null; then ap_stat="enabled"; else ap_stat="disabled"; fi
    if subnet_conflicts "$SUBNET"; then subnet_conflict="yes"; else subnet_conflict="no"; fi
    log_level=$(get_log_level)
    mtu=$(get_mtu)

    echo "Version: $LOCAL_VER"
    echo "sing-box: $sb_run"
    echo "sing-box autostart: $sb_en"
    echo "sing-box log level: $log_level"
    echo "sing-box MTU: $mtu"
    echo "kresd patch: $kr_stat"
    echo "domains: $dom_stat"
    echo "subnet in AntiZapret: $az_stat"
    echo "autopatch: $ap_stat"
    echo "subnet conflict: $subnet_conflict"
}

prompt_apply() {
    echo -e "\n${YELLOW}Применить изменения и перезапустить DNS?${NC}"
    read -r -e -p "Выбор [Y/n] (по умолчанию Y): " apply_choice
    if [[ -z "$apply_choice" || "$apply_choice" == "Y" || "$apply_choice" == "y" ]]; then
        if patch_kresd > /dev/null 2>&1; then
            echo -e "${GREEN}Изменения успешно применены!${NC}"
        else
            echo -e "${RED}Не удалось применить изменения к DNS.${NC}"
        fi
    else
        echo -e "${YELLOW}Домены сохранены в файл, но НЕ применены к DNS.${NC}"
    fi
    read -r -p "Нажмите Enter для продолжения..."
}

prompt_confirm() {
    read -r -e -p "Вы уверены? [y/N] (по умолчанию N): " conf_choice
    if [[ "$conf_choice" == "y" || "$conf_choice" == "Y" ]]; then return 0; else return 1; fi
}

show_logs() {
    echo -e "\n${CYAN}==========================================${NC}"
    echo -e "${YELLOW}Чтение логов sing-box...${NC}"
    echo -e "${GREEN}Для выхода обратно в меню нажмите Ctrl+C${NC}"
    echo -e "${CYAN}==========================================${NC}\n"
    trap 'echo -e "\n${CYAN}Возврат в меню...${NC}"' SIGINT
    journalctl -u sing-box -n 20 -f
    trap - SIGINT
}

patch_kresd() {
    sync_domains

    if [ ! -f "$KRESD_CONF" ]; then
        echo -e "${RED}Файл $KRESD_CONF не найден.${NC}"
        return 1
    fi

    backup_kresd || {
        echo -e "${RED}Не удалось создать backup $KRESD_CONF.${NC}"
        return 1
    }

    local clean_tmp tmpfile
    clean_tmp=$(mktemp /tmp/kresd.clean.XXXXXX)
    tmpfile=$(mktemp /tmp/kresd.conf.XXXXXX)

    sed '/-- \[WARP-MOD-START\]/,/-- \[WARP-MOD-END\]/d' "$KRESD_CONF" > "$clean_tmp"

    awk '
    BEGIN {
        in_inst1=0
        in_inst2=0
        inserted1=0
        inserted2=0
    }

    function print_warp_block() {
        print "\t-- [WARP-MOD-START]"
        print "\tlocal warp_domains = {}"
        print "\tlocal wfile = io.open(\"/etc/knot-resolver/warper-domains.txt\", \"r\")"
        print "\tif wfile then"
        print "\t\tfor line in wfile:lines() do"
        print "\t\t\tlocal clean = line:gsub(\"%s+\", \"\")"
        print "\t\t\tif clean ~= \"\" and clean:sub(1,1) ~= \"#\" then table.insert(warp_domains, clean .. \".\") end"
        print "\t\tend"
        print "\t\twfile:close()"
        print "\t\tif #warp_domains > 0 then"
        print "\t\t\tpolicy.add(policy.suffix(policy.STUB(\"127.0.0.1@40000\"), policy.todnames(warp_domains)))"
        print "\t\tend"
        print "\tend"
        print "\t-- [WARP-MOD-END]"
    }

    /^if string.match\(systemd_instance, '\''\^1'\''\) then$/ {
        in_inst1=1
        in_inst2=0
        print
        next
    }

    /^elseif string.match\(systemd_instance, '\''\^2'\''\) then$/ {
        in_inst1=0
        in_inst2=1
        print
        next
    }

    /^else panic/ {
        in_inst1=0
        in_inst2=0
        print
        next
    }

    in_inst1 && /^[[:space:]]*-- Resolve non-blocked domains$/ && inserted1==0 {
        print_warp_block()
        inserted1=1
        print
        next
    }

    in_inst2 && /^[[:space:]]*-- Resolve blocked domains$/ && inserted2==0 {
        print_warp_block()
        inserted2=1
        print
        next
    }

    {
        print
    }

    END {
        if (inserted1 == 0 || inserted2 == 0) exit 42
    }
    ' "$clean_tmp" > "$tmpfile"
    local awk_rc=$?

    rm -f "$clean_tmp"

    if [ "$awk_rc" -ne 0 ]; then
        rm -f "$tmpfile"
        if [ "$awk_rc" -eq 42 ]; then
            echo -e "${RED}Не удалось найти корректные точки вставки в $KRESD_CONF.${NC}"
        else
            echo -e "${RED}Ошибка при патчинге $KRESD_CONF.${NC}"
        fi
        return 1
    fi

    if ! mv "$tmpfile" "$KRESD_CONF"; then
        rm -f "$tmpfile"
        echo -e "${RED}Не удалось записать обновлённый $KRESD_CONF.${NC}"
        return 1
    fi

    chmod 644 "$KRESD_CONF"

    if ! systemctl restart kresd@1 kresd@2; then
        echo -e "${RED}Не удалось перезапустить kresd.${NC}"
        return 1
    fi

    return 0
}

unpatch_kresd() {
    if [ -f "$KRESD_BACKUP" ]; then
        restore_kresd_backup && return 0
    fi

    if grep -q "WARP-MOD-START" "$KRESD_CONF" 2>/dev/null; then
        sed -i '/-- \[WARP-MOD-START\]/,/-- \[WARP-MOD-END\]/d' "$KRESD_CONF"
        chmod 644 "$KRESD_CONF"
        systemctl restart kresd@1 kresd@2 || return 1
    fi
    return 0
}

doctor() {
    load_config

    echo -e "${CYAN}==========================================${NC}"
    echo -e "        🩺 ${YELLOW}WARPER DOCTOR${NC}"
    echo -e "${CYAN}==========================================${NC}"

    local failed=0

    check_item() {
        local label="$1"
        local cmd="$2"
        if eval "$cmd" >/dev/null 2>&1; then
            echo -e " ${GREEN}✔${NC} $label"
        else
            echo -e " ${RED}✘${NC} $label"
            failed=1
        fi
    }

    check_item "AntiZapret установлен" "[ -x /root/antizapret/doall.sh ] && [ -f /root/antizapret/config/include-ips.txt ]"
    check_item "Файл конфигурации warper существует" "[ -f '$CONF_FILE' ]"
    check_item "Файл списка доменов существует" "[ -f '$MASTER_FILE' ]"
    check_item "Активный список доменов существует" "[ -f '$ACTIVE_FILE' ]"
    check_item "Конфиг sing-box существует" "[ -f '$SINGBOX_CONF' ]"
    check_item "Конфиг sing-box валиден" "validate_singbox_config"
    check_item "Служба sing-box активна" "systemctl is-active --quiet sing-box"
    check_item "Автозагрузка sing-box включена" "systemctl is-enabled --quiet sing-box"
    check_item "Службы kresd активны" "systemctl is-active --quiet kresd@1 && systemctl is-active --quiet kresd@2"
    check_item "Автопатч warper включен" "systemctl is-enabled --quiet warper-autopatch"
    check_item "kresd.conf пропатчен" "grep -q 'WARP-MOD-START' '$KRESD_CONF'"
    check_item "В kresd.conf ровно 2 WARP-блока" "[ \"\$(grep -c 'WARP-MOD-START' '$KRESD_CONF' 2>/dev/null)\" -eq 2 ]"
    check_item "Права /etc/sing-box/config.json ограничены" "file_mode_is_600 '$SINGBOX_CONF'"
    check_item "Права /root/warper/warper.conf ограничены" "file_mode_is_600 '$CONF_FILE'"
    check_item "Резервная копия kresd.conf существует" "[ -f '$KRESD_BACKUP' ]"
    check_item "Домены синхронизированы" "domains_in_sync"
    check_item "Подсеть $SUBNET есть в include-ips.txt" "grep -qF '$SUBNET' '$AZ_INC'"
    check_item "Интерфейс singbox-tun существует" "ip link show singbox-tun"
    check_item "Правило iptables FORWARD -o singbox-tun существует" "iptables -C FORWARD -o singbox-tun -j ACCEPT"
    check_item "Правило iptables FORWARD -i singbox-tun существует" "iptables -C FORWARD -i singbox-tun -j ACCEPT"

    if [ -f "$WGCF_DIR/wgcf-profile.conf" ]; then
        check_item "Права wgcf-profile.conf ограничены" "file_mode_is_600 '$WGCF_DIR/wgcf-profile.conf'"
    fi

    if subnet_conflicts "$SUBNET"; then
        echo -e " ${YELLOW}!${NC} Обнаружен возможный конфликт fake-подсети $SUBNET"
        failed=1
    else
        echo -e " ${GREEN}✔${NC} Конфликт fake-подсети не обнаружен"
    fi

    echo -e "${CYAN}------------------------------------------${NC}"
    if [ "$failed" -eq 0 ]; then
        echo -e "${GREEN}Диагностика завершена: проблем не обнаружено.${NC}"
        return 0
    else
        echo -e "${YELLOW}Диагностика завершена: обнаружены проблемы. Проверьте статусы выше.${NC}"
        return 1
    fi
}

toggle_warper() {
    local action="ВКЛЮЧИТЬ"
    if systemctl is-active --quiet sing-box || grep -q "WARP-MOD-START" "$KRESD_CONF" 2>/dev/null; then
        action="ВЫКЛЮЧИТЬ"
    fi

    if [ "$action" == "ВЫКЛЮЧИТЬ" ]; then
        echo -e "\n${YELLOW}Вы уверены что хотите выключить warper? (Y/n)${NC}"
    else
        echo -e "\n${YELLOW}Вы уверены что хотите включить warper? (Y/n)${NC}"
    fi

    read -r -e -p "Выбор: " conf
    if [[ -z "$conf" || "$conf" == "Y" || "$conf" == "y" ]]; then
        if [ "$action" == "ВЫКЛЮЧИТЬ" ]; then
            echo -e "${YELLOW}Отключение WARPER...${NC}"
            systemctl stop sing-box
            systemctl disable sing-box 2>/dev/null
            systemctl disable warper-autopatch 2>/dev/null
            remove_iptables_rule FORWARD -o singbox-tun
            remove_iptables_rule FORWARD -i singbox-tun
            unpatch_kresd || {
                echo -e "${RED}Ошибка при удалении патча DNS.${NC}"
                sleep 2
                return
            }
            echo -e "${GREEN}WARPER успешно отключен! Трафик идет по умолчанию.${NC}"
        else
            echo -e "${YELLOW}Включение WARPER...${NC}"
            if ! validate_singbox_config; then
                sleep 2
                return
            fi
            systemctl enable sing-box 2>/dev/null
            systemctl start sing-box
            if ! ensure_singbox_running; then
                sleep 2
                return
            fi
            systemctl enable warper-autopatch 2>/dev/null
            ensure_iptables_rule FORWARD -o singbox-tun
            ensure_iptables_rule FORWARD -i singbox-tun
            if ! patch_kresd >/dev/null 2>&1; then
                echo -e "${RED}Не удалось применить патч DNS.${NC}"
                sleep 2
                return
            fi
            echo -e "${GREEN}WARPER успешно включен!${NC}"
        fi
        sleep 2
    fi
}

enable_disable_list() {
    local action="$1"
    local list_name="$2"
    local list_file="$DOWNLOAD_DIR/${list_name}.txt"
    local marker="# --- ${list_name^^} ---"
    local end_marker="# --- END ${list_name^^} ---"

    if [ ! -f "$list_file" ]; then
        echo -e "${RED}Файл списка $list_file не найден!${NC}"
        return 1
    fi

    local valid_tmp tmp
    valid_tmp=$(mktemp /tmp/warper_valid_list.XXXXXX)
    tmp=$(mktemp /tmp/warper_master.XXXXXX)
    filter_valid_domains_file "$list_file" "$valid_tmp"

    rebuild_master_file "$MASTER_FILE" "$tmp"

    if [ "$action" = "enable" ]; then
        if extract_block "$tmp" "$list_name" | grep -qxF "$marker"; then
            rm -f "$valid_tmp" "$tmp"
            echo -e "${YELLOW}Список ${list_name^^} уже включен.${NC}"
            return 0
        fi

        cp "$tmp" "${tmp}.new"
        {
            echo ""
            echo "$marker"
            cat "$valid_tmp"
            echo "$end_marker"
        } >> "${tmp}.new"

        rebuild_master_file "${tmp}.new" "$MASTER_FILE"
        rm -f "$valid_tmp" "$tmp" "${tmp}.new"
        echo -e "${GREEN}Список ${list_name^^} включен.${NC}"
        return 0
    fi

    if [ "$action" = "disable" ]; then
        if extract_block "$tmp" "$list_name" | grep -qxF "$marker"; then
            awk -v start="$marker" -v end="$end_marker" '
            $0 == start { skip=1; next }
            $0 == end { skip=0; next }
            !skip { print }
            ' "$tmp" > "${tmp}.new"

            rebuild_master_file "${tmp}.new" "$MASTER_FILE"
            rm -f "$valid_tmp" "$tmp" "${tmp}.new"
            echo -e "${YELLOW}Список ${list_name^^} выключен.${NC}"
            return 0
        fi

        rm -f "$valid_tmp" "$tmp"
        echo -e "${YELLOW}Список ${list_name^^} уже выключен.${NC}"
        return 0
    fi

    rm -f "$valid_tmp" "$tmp"
    return 1
}

toggle_list() {
    local list_name=$1
    if has_list_block "$list_name"; then
        enable_disable_list disable "$list_name"
    else
        enable_disable_list enable "$list_name"
    fi
    prompt_apply
}

update_list_blocks() {
    for list_name in "gemini" "chatgpt"; do
        if has_list_block "$list_name"; then
            enable_disable_list disable "$list_name" >/dev/null 2>&1 || true
            enable_disable_list enable "$list_name" >/dev/null 2>&1 || true
        fi
    done
}

update_warper() {
    echo -e "\n${CYAN}Скачивание обновления с GitHub...${NC}"
    mkdir -p "$DOWNLOAD_DIR"

    download_file_safe "$REPO_URL/warper.sh" "$WARPER_DIR/warper.sh" "warper.sh" || return 1
    download_file_safe "$REPO_URL/uninstaller.sh" "$WARPER_DIR/uninstaller.sh" "uninstaller.sh" || return 1
    download_file_safe "$REPO_URL/sing-box.service" "/etc/systemd/system/sing-box.service" "sing-box.service" || return 1
    download_file_safe "$REPO_URL/warper-autopatch.service" "/etc/systemd/system/warper-autopatch.service" "warper-autopatch.service" || return 1
    download_file_safe "$REPO_URL/version" "$WARPER_DIR/version" "version" || return 1
    download_file_safe "$REPO_URL/config.json.template" "$SINGBOX_TEMPLATE" "config.json.template" || return 1
    download_file_safe "$REPO_URL/download/gemini.txt" "$DOWNLOAD_DIR/gemini.txt" "gemini.txt" || return 1
    download_file_safe "$REPO_URL/download/chatgpt.txt" "$DOWNLOAD_DIR/chatgpt.txt" "chatgpt.txt" || return 1

    chmod +x "$WARPER_DIR/warper.sh" "$WARPER_DIR/uninstaller.sh"
    systemctl daemon-reload
    systemctl enable warper-autopatch >/dev/null 2>&1

    if [ -f "$SINGBOX_TEMPLATE" ] && [ -s "$SINGBOX_TEMPLATE" ]; then
        echo -e "${CYAN}Обновление конфигурации sing-box из шаблона...${NC}"
        if rebuild_config "$SINGBOX_TEMPLATE"; then
            systemctl restart sing-box
            if ensure_singbox_running; then
                echo -e "${GREEN}Служба sing-box перезапущена с обновлённым конфигом.${NC}"
            else
                echo -e "${YELLOW}Конфиг обновлён, но служба sing-box не запустилась корректно.${NC}"
            fi
        else
            echo -e "${YELLOW}Конфигурация sing-box не обновлена (ошибка извлечения ключей или валидации).${NC}"
        fi
    fi

    rebuild_master_file
    update_list_blocks

    echo -e "${GREEN}Утилита и списки успешно обновлены!${NC}"
    read -r -e -p "Нажмите Enter для перезапуска WARPER..."
    exec /usr/local/bin/warper
}

settings_menu() {
    while true; do
        clear
        echo -e "${CYAN}==========================================${NC}"
        echo -e "          ⚙️  ${YELLOW}НАСТРОЙКИ WARPER${NC} ⚙️"
        echo -e "${CYAN}==========================================${NC}"

        local AP_STAT GEM_STAT GPT_STAT LOG_LEVEL MTU
        LOG_LEVEL=$(get_log_level)
        MTU=$(get_mtu)

        if systemctl is-enabled --quiet warper-autopatch 2>/dev/null; then AP_STAT="${GREEN}ВКЛЮЧЕНО${NC}"; else AP_STAT="${RED}ВЫКЛЮЧЕНО${NC}"; fi
        if has_list_block "gemini"; then GEM_STAT="${GREEN}ВКЛЮЧЕНО${NC}"; else GEM_STAT="${RED}ВЫКЛЮЧЕНО${NC}"; fi
        if has_list_block "chatgpt"; then GPT_STAT="${GREEN}ВКЛЮЧЕНО${NC}"; else GPT_STAT="${RED}ВЫКЛЮЧЕНО${NC}"; fi

        echo -e " ${CYAN}1.${NC} Автопатч DNS при перезагрузке:  [$AP_STAT]"
        echo -e " ${CYAN}2.${NC} Интеграция доменов Gemini:      [$GEM_STAT]"
        echo -e " ${CYAN}3.${NC} Интеграция доменов ChatGPT:     [$GPT_STAT]"
        echo -e " ${CYAN}4.${NC} Изменить фейковую подсеть:      [Текущая: $SUBNET]"
        echo -e " ${CYAN}5.${NC} Изменить log level sing-box:    [Текущий: $LOG_LEVEL]"
        echo -e " ${CYAN}6.${NC} Изменить MTU sing-box:          [Текущий: $MTU]"
        echo -e " ${CYAN}0.${NC} Назад в главное меню"
        echo -e "${CYAN}==========================================${NC}"
        read -r -e -p "Выбор [0-6]: " set_choice
        case "${set_choice:-}" in
            1)
                if systemctl is-enabled --quiet warper-autopatch 2>/dev/null; then
                    systemctl disable warper-autopatch >/dev/null 2>&1
                    echo -e "${YELLOW}Автопатч отключен.${NC}"; sleep 1
                else
                    systemctl enable warper-autopatch >/dev/null 2>&1
                    echo -e "${GREEN}Автопатч включен.${NC}"; sleep 1
                fi
                ;;
            2) toggle_list "gemini" ;;
            3) toggle_list "chatgpt" ;;
            4)
                echo -e "\n${YELLOW}Внимание! Изменение подсети обновит конфигурации и перезапустит службы.${NC}"
                read -r -e -p "Вы уверены? [y/N]: " conf_sub
                if [[ "$conf_sub" == "y" || "$conf_sub" == "Y" ]]; then
                    while true; do
                        read -r -e -p "Введите новую подсеть (X.X.X.0/XX) или оставьте пустым для отмены: " new_subnet
                        if [ -z "$new_subnet" ]; then
                            echo -e "${YELLOW}Отмена.${NC}"; sleep 1; break
                        elif validate_subnet "$new_subnet"; then
                            if subnet_conflicts "$new_subnet"; then
                                echo -e "${YELLOW}Предупреждение: подсеть $new_subnet уже может использоваться локально или Docker.${NC}"
                                read -r -e -p "Использовать её всё равно? [y/N]: " force_subnet
                                if [[ ! "$force_subnet" =~ ^[Yy]$ ]]; then
                                    continue
                                fi
                            fi

                            local old_subnet old_tun new_tun
                            old_subnet="$SUBNET"
                            old_tun="$TUN_IP"
                            new_tun=$(calculate_tun_ip "$new_subnet")

                            SUBNET="$new_subnet"
                            TUN_IP="$new_tun"

                            if [ -f "$SINGBOX_TEMPLATE" ] && [ -s "$SINGBOX_TEMPLATE" ]; then
                                if ! rebuild_config "$SINGBOX_TEMPLATE"; then
                                    SUBNET="$old_subnet"
                                    TUN_IP="$old_tun"
                                    echo -e "${RED}Не удалось пересобрать конфиг sing-box.${NC}"
                                    sleep 2
                                    break
                                fi
                            else
                                sed -i "s|\"$old_subnet\"|\"$new_subnet\"|g" "$SINGBOX_CONF"
                                sed -i "s|\"$old_tun\"|\"$new_tun\"|g" "$SINGBOX_CONF"
                                if ! validate_singbox_config; then
                                    sed -i "s|\"$new_subnet\"|\"$old_subnet\"|g" "$SINGBOX_CONF"
                                    sed -i "s|\"$new_tun\"|\"$old_tun\"|g" "$SINGBOX_CONF"
                                    SUBNET="$old_subnet"
                                    TUN_IP="$old_tun"
                                    echo -e "${RED}Получился некорректный конфиг sing-box, откат выполнен.${NC}"
                                    sleep 2
                                    break
                                fi
                            fi

                            sed -i "\|$old_subnet|d" "$AZ_INC" 2>/dev/null
                            grep -qxF "$new_subnet" "$AZ_INC" 2>/dev/null || echo "$new_subnet" >> "$AZ_INC"
                            normalize_include_ips "$AZ_INC"

                            {
                                echo "SUBNET=$new_subnet"
                                echo "TUN_IP=$new_tun"
                            } > "$CONF_FILE"
                            chmod 600 "$CONF_FILE"

                            echo -e "${YELLOW}⏳ Обновление маршрутов AntiZapret (подождите)...${NC}"
                            export DEBIAN_FRONTEND=noninteractive
                            export SYSTEMD_PAGER=""
                            bash /root/antizapret/doall.sh </dev/null >/dev/null 2>&1

                            echo -e "${CYAN}Перезапуск службы sing-box для применения правил...${NC}"
                            systemctl restart sing-box
                            if ! ensure_singbox_running; then
                                echo -e "${RED}Служба sing-box не запустилась после смены подсети.${NC}"
                                sleep 2
                                break
                            fi

                            ensure_iptables_rule FORWARD -o singbox-tun
                            ensure_iptables_rule FORWARD -i singbox-tun

                            echo -e "${GREEN}Подсеть успешно изменена!${NC}"
                            sleep 2
                            break
                        else
                            echo -e "${RED}Некорректная подсеть! Ожидается формат X.X.X.0/XX с валидными октетами (0-255) и маской (1-32).${NC}"
                        fi
                    done
                fi
                ;;
            5)
                echo -e "\n${CYAN}Доступные уровни логирования:${NC}"
                echo -e " ${CYAN}1.${NC} debug"
                echo -e " ${CYAN}2.${NC} info"
                echo -e " ${CYAN}3.${NC} warn"
                echo -e " ${CYAN}4.${NC} error"
                echo -e " ${CYAN}0.${NC} Отмена"
                read -r -e -p "Выбор [0-4]: " log_choice
                case "${log_choice:-}" in
                    1) set_log_level "debug"; sleep 2 ;;
                    2) set_log_level "info"; sleep 2 ;;
                    3) set_log_level "warn"; sleep 2 ;;
                    4) set_log_level "error"; sleep 2 ;;
                    0) ;;
                    *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
                esac
                ;;
            6)
                echo -e "\n${CYAN}Текущий MTU: $(get_mtu)${NC}"
                echo -e "${YELLOW}Допустимые значения: 1280-1500${NC}"
                echo -e "${YELLOW}Рекомендуется: 1420 (по умолчанию)${NC}"
                read -r -e -p "Введите новый MTU (или оставьте пустым для отмены): " new_mtu
                if [ -n "$new_mtu" ]; then
                    set_mtu "$new_mtu"
                    sleep 2
                fi
                ;;
            0) return ;;
            *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
        esac
    done
}

singbox_menu() {
    while true; do
        clear
        echo -e "${CYAN}==========================================${NC}"
        echo -e "       ⚙️  ${YELLOW}УПРАВЛЕНИЕ SING-BOX${NC} ⚙️"
        echo -e "${CYAN}==========================================${NC}"
        if systemctl is-active --quiet sing-box; then echo -e "Текущий статус: ${GREEN}ЗАПУЩЕН 🟢${NC}"; else echo -e "Текущий статус: ${RED}ОСТАНОВЛЕН 🔴${NC}"; fi
        if systemctl is-enabled --quiet sing-box 2>/dev/null; then echo -e "Автозагрузка: ${GREEN}ВКЛЮЧЕНА${NC}"; else echo -e "Автозагрузка: ${RED}ВЫКЛЮЧЕНА${NC}"; fi
        echo -e "${CYAN}------------------------------------------${NC}"
        echo -e " ${GREEN}1.${NC} Запустить службу"
        echo -e " ${RED}2.${NC} Остановить службу"
        echo -e " ${GREEN}3.${NC} Включить в автозагрузку"
        echo -e " ${RED}4.${NC} Выключить из автозагрузки"
        echo -e " ${YELLOW}5.${NC} Посмотреть логи"
        echo -e " ${CYAN}0.${NC} Назад в главное меню"
        echo -e "${CYAN}==========================================${NC}"
        read -r -e -p "Выбор [0-5]: " sb_choice
        case "${sb_choice:-}" in
            1)
                if prompt_confirm; then
                    if ! validate_singbox_config; then
                        sleep 2
                        continue
                    fi
                    systemctl start sing-box
                    if ensure_singbox_running; then
                        echo -e "${GREEN}Запущено.${NC}"
                    fi
                    sleep 1
                fi
                ;;
            2)
                if prompt_confirm; then
                    systemctl stop sing-box
                    echo -e "${YELLOW}Остановлено.${NC}"
                    sleep 1
                fi
                ;;
            3)
                if prompt_confirm; then
                    systemctl enable sing-box
                    echo -e "${GREEN}Добавлено в автозапуск.${NC}"
                    sleep 1
                fi
                ;;
            4)
                if prompt_confirm; then
                    systemctl disable sing-box
                    echo -e "${YELLOW}Убрано из автозапуска.${NC}"
                    sleep 1
                fi
                ;;
            5) show_logs ;;
            0) return ;;
            *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
        esac
    done
}

show_main_menu() {
    clear
    local REMOTE_VER
    REMOTE_VER=$(get_remote_version)

    echo -e "${CYAN}==========================================${NC}"
    echo -e "       🚀 ${YELLOW}Панель управления Warper${NC} 🚀"
    echo -e "${CYAN}==========================================${NC}"

    local VER_STR SB_RUN SB_EN KR_STAT DOM_STAT AZ_STAT AP_STAT UPDATE_AVAILABLE LOG_LEVEL MTU
    UPDATE_AVAILABLE=false
    LOG_LEVEL=$(get_log_level)
    MTU=$(get_mtu)

    if version_gt "$REMOTE_VER" "$LOCAL_VER"; then
        VER_STR="${YELLOW}$LOCAL_VER (Доступно: $REMOTE_VER)${NC}"
        UPDATE_AVAILABLE=true
    else
        VER_STR="${GREEN}$LOCAL_VER (Актуальная)${NC}"
    fi

    if systemctl is-active --quiet sing-box; then SB_RUN="${GREEN}запущен${NC}"; else SB_RUN="${RED}выключен${NC}"; fi
    if systemctl is-enabled --quiet sing-box 2>/dev/null; then SB_EN="${GREEN}включена автозагрузка${NC}"; else SB_EN="${RED}отключена автозагрузка${NC}"; fi
    if grep -q "WARP-MOD-START" "$KRESD_CONF" 2>/dev/null; then KR_STAT="${GREEN}пропатчен${NC}"; else KR_STAT="${RED}не пропатчен${NC}"; fi
    if domains_in_sync; then DOM_STAT="${GREEN}синхронизированы${NC}"; else DOM_STAT="${RED}не синхронизированы${NC}"; fi
    if grep -qF "$SUBNET" "$AZ_INC" 2>/dev/null; then AZ_STAT="${GREEN}добавлена${NC}"; else AZ_STAT="${RED}не добавлена${NC}"; fi
    if systemctl is-enabled --quiet warper-autopatch 2>/dev/null; then AP_STAT="${GREEN}включено${NC}"; else AP_STAT="${RED}отключено${NC}"; fi

    echo -e " - Версия: $VER_STR"
    echo -e " - Sing-box ($SB_RUN, $SB_EN)"
    echo -e " - Sing-box log: ${CYAN}$LOG_LEVEL${NC}, MTU: ${CYAN}$MTU${NC}"
    echo -e " - Kresd.conf ($KR_STAT)"
    echo -e " - 📁 Домены: $MASTER_FILE ($DOM_STAT)"
    echo -e " - Fake подсеть $SUBNET в include-ips ($AZ_STAT)"
    echo -e " - Автовосстановление DNS ($AP_STAT)"

    echo -e "${CYAN}------------------------------------------${NC}"
    echo -e " ${GREEN}1.${NC} Добавить домен в WARP"
    echo -e " ${RED}2.${NC} Удалить домен из WARP"
    echo -e " ${YELLOW}3.${NC} Посмотреть список доменов"
    echo -e " ${CYAN}4.${NC} Отредактировать список (через nano)"
    echo -e " ${CYAN}5.${NC} 🔧 Пропатчить DNS / Синхронизация"
    echo -e " ${CYAN}6.${NC} ⚙️ Управление sing-box"
    echo -e " ${CYAN}7.${NC} 📄 Показать логи"
    echo -e " ${CYAN}D.${NC} 🩺 Диагностика (doctor)"
    echo -e " ${CYAN}S.${NC} 📊 Краткий статус"

    if systemctl is-active --quiet sing-box || grep -q "WARP-MOD-START" "$KRESD_CONF" 2>/dev/null; then
        echo -e " ${RED}8. ⏹ Отключить WARPER${NC}"
    else
        echo -e " ${GREEN}8. ▶ Включить WARPER${NC}"
    fi

    echo -e " ${CYAN}9.${NC} 🛠 Настройки (Автопатч, Подсеть, Списки, Log, MTU)"

    if [ "$UPDATE_AVAILABLE" = true ]; then
        echo -e " ${YELLOW}10. ⚡ Обновить WARPER до $REMOTE_VER${NC}"
    else
        echo -e " ${CYAN}10.${NC} 🔄 Проверить и обновить списки доменов"
    fi

    echo -e " ${RED}U. Удалить warper полностью${NC}"
    echo -e " ${CYAN}0.${NC} Выход"
    echo -e "${CYAN}==========================================${NC}"

    MENU_UPDATE_AVAILABLE=$UPDATE_AVAILABLE
    MENU_REMOTE_VER=$REMOTE_VER
}

cli_add_domain() {
    local raw="$1"
    local domain
    domain=$(validate_domain "$raw") || {
        echo -e "${RED}Некорректный домен: $raw${NC}"
        return 1
    }

    if grep -qxF "$domain" "$MASTER_FILE"; then
        echo -e "${YELLOW}Домен уже есть в списке: $domain${NC}"
        return 0
    fi

    insert_user_domain "$domain"
    patch_kresd >/dev/null 2>&1 || true
    echo -e "${GREEN}Домен добавлен и применён: $domain${NC}"
    return 0
}

cli_remove_domain() {
    local raw="$1"
    local domain
    domain=$(validate_domain "$raw") || {
        echo -e "${RED}Некорректный домен: $raw${NC}"
        return 1
    }

    if grep -qxF "$domain" "$MASTER_FILE"; then
        local escaped
        escaped=$(escape_regex "$domain")
        sed -i "/^${escaped}$/d" "$MASTER_FILE"
        rebuild_master_file
        patch_kresd >/dev/null 2>&1 || true
        echo -e "${GREEN}Домен удалён и изменения применены: $domain${NC}"
        return 0
    fi

    echo -e "${YELLOW}Домен не найден: $domain${NC}"
    return 0
}

cli_enable_list() {
    local list_name="$1"
    case "$list_name" in
        gemini|chatgpt)
            enable_disable_list enable "$list_name" || return 1
            patch_kresd >/dev/null 2>&1 || true
            ;;
        *)
            echo -e "${RED}Неизвестный список: $list_name${NC}"
            return 1
            ;;
    esac
}

cli_disable_list() {
    local list_name="$1"
    case "$list_name" in
        gemini|chatgpt)
            enable_disable_list disable "$list_name" || return 1
            patch_kresd >/dev/null 2>&1 || true
            ;;
        *)
            echo -e "${RED}Неизвестный список: $list_name${NC}"
            return 1
            ;;
    esac
}

load_config
rebuild_master_file

case "${1:-}" in
    patch)
        patch_kresd >/dev/null 2>&1
        exit $?
        ;;
    doctor)
        doctor
        exit $?
        ;;
    status)
        status_cmd
        exit $?
        ;;
    sync)
        patch_kresd
        exit $?
        ;;
    add)
        [ -n "${2:-}" ] || { echo "Использование: warper add DOMAIN"; exit 1; }
        cli_add_domain "$2"
        exit $?
        ;;
    remove)
        [ -n "${2:-}" ] || { echo "Использование: warper remove DOMAIN"; exit 1; }
        cli_remove_domain "$2"
        exit $?
        ;;
    enable)
        [ -n "${2:-}" ] || { echo "Использование: warper enable gemini|chatgpt"; exit 1; }
        cli_enable_list "$2"
        exit $?
        ;;
    disable)
        [ -n "${2:-}" ] || { echo "Использование: warper disable gemini|chatgpt"; exit 1; }
        cli_disable_list "$2"
        exit $?
        ;;
esac

MENU_UPDATE_AVAILABLE=false
MENU_REMOTE_VER="$LOCAL_VER"

while true; do
    show_main_menu
    read -r -e -p "Выбор: " choice

    choice=$(echo "${choice:-}" | tr -d ' ')

    case "$choice" in
        1)
            echo -e "\n${CYAN}Введите домен (например, openai.com):${NC}"
            read -r -e -p "> " raw_domain
            new_domain=$(validate_domain "${raw_domain:-}") || {
                echo -e "${RED}Некорректный формат домена! Домен должен содержать точку (например, openai.com).${NC}"
                sleep 2
                continue
            }
            if grep -qxF "$new_domain" "$MASTER_FILE"; then
                echo -e "${YELLOW}Домен уже есть в списке!${NC}"
                sleep 1
            else
                insert_user_domain "$new_domain"
                echo -e "${GREEN}Домен '$new_domain' добавлен!${NC}"
                prompt_apply
            fi
            ;;
        2)
            echo -e "\n${CYAN}Введите домен для удаления:${NC}"
            read -r -e -p "> " raw_del_domain
            del_domain=$(validate_domain "${raw_del_domain:-}") || {
                echo -e "${RED}Некорректный формат домена!${NC}"
                sleep 2
                continue
            }
            if grep -qxF "$del_domain" "$MASTER_FILE"; then
                escaped=$(escape_regex "$del_domain")
                sed -i "/^${escaped}$/d" "$MASTER_FILE"
                rebuild_master_file
                echo -e "${GREEN}Домен '$del_domain' удалён!${NC}"
                prompt_apply
            else
                echo -e "${RED}Домен не найден в списке!${NC}"
                sleep 1
            fi
            ;;
        3)
            rebuild_master_file
            echo -e "\n${CYAN}--- Домены в WARP ---${NC}"
            if [ -s "$MASTER_FILE" ]; then cat "$MASTER_FILE"; else echo -e "${YELLOW}Список пуст.${NC}"; fi
            echo -e "${CYAN}---------------------${NC}"
            read -r -p "Нажмите Enter..."
            ;;
        4)
            before_hash=$(canonical_master_hash)
            nano "$MASTER_FILE"
            after_hash=$(canonical_master_hash)

            if [ "$before_hash" != "$after_hash" ]; then
                rebuild_master_file
                prompt_apply
            else
                rebuild_master_file
                echo -e "${YELLOW}Изменений не обнаружено.${NC}"
                sleep 1
            fi
            ;;
        5)
            echo -e "\n${YELLOW}Запуск синхронизации...${NC}"
            rebuild_master_file
            if patch_kresd; then
                echo -e "${GREEN}Готово!${NC}"
            else
                echo -e "${RED}Синхронизация завершилась с ошибкой.${NC}"
            fi
            sleep 1
            ;;
        6) singbox_menu ;;
        7) show_logs ;;
        8) toggle_warper ;;
        9) settings_menu ;;
        10)
            if [ "$MENU_UPDATE_AVAILABLE" = true ]; then
                update_warper
            else
                echo -e "\n${CYAN}Проверка обновлений списков...${NC}"
                mkdir -p "$DOWNLOAD_DIR"

                download_file_safe "$REPO_URL/download/gemini.txt" "/tmp/gemini.txt" "gemini.txt" || {
                    echo -e "${RED}Не удалось обновить gemini.txt${NC}"
                    sleep 2
                    continue
                }
                download_file_safe "$REPO_URL/download/chatgpt.txt" "/tmp/chatgpt.txt" "chatgpt.txt" || {
                    echo -e "${RED}Не удалось обновить chatgpt.txt${NC}"
                    rm -f /tmp/gemini.txt
                    sleep 2
                    continue
                }

                LISTS_CHANGED=false

                if ! cmp -s /tmp/gemini.txt "$DOWNLOAD_DIR/gemini.txt" 2>/dev/null; then
                    mv /tmp/gemini.txt "$DOWNLOAD_DIR/gemini.txt"
                    LISTS_CHANGED=true
                else
                    rm -f /tmp/gemini.txt
                fi

                if ! cmp -s /tmp/chatgpt.txt "$DOWNLOAD_DIR/chatgpt.txt" 2>/dev/null; then
                    mv /tmp/chatgpt.txt "$DOWNLOAD_DIR/chatgpt.txt"
                    LISTS_CHANGED=true
                else
                    rm -f /tmp/chatgpt.txt
                fi

                if [ "$LISTS_CHANGED" = true ]; then
                    update_list_blocks
                    echo -e "${GREEN}Найдены новые домены! Списки успешно обновлены.${NC}"
                    prompt_apply
                else
                    echo -e "${GREEN}Версия и файлы актуальны, обновление не требуется.${NC}"
                    sleep 2
                fi
            fi
            ;;
        d|D)
            doctor
            read -r -p "Нажмите Enter..."
            ;;
        s|S)
            status_cmd
            read -r -p "Нажмите Enter..."
            ;;
        u|U)
            if [ -f "$WARPER_DIR/uninstaller.sh" ]; then
                exec bash "$WARPER_DIR/uninstaller.sh"
            else
                exec curl -fsSL "$REPO_URL/uninstaller.sh?t=$(date +%s)" | bash
            fi
            ;;
        0)
                    clear
            exit 0
            ;;
        *)
            echo -e "${RED}Неверный выбор.${NC}"
            sleep 1
            ;;
    esac
done
            
