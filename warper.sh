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
REPO_URL="https://raw.githubusercontent.com/Liafanx/AZ-WARP/1.1.0pre"
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

check_antizapret_warp() {
    local setup_file="/root/antizapret/setup"
    if [ -f "$setup_file" ]; then
        local az_warp
        az_warp=$(grep -E '^ANTIZAPRET_WARP=' "$setup_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"'\''[:space:]')
        if [ "$az_warp" = "y" ]; then
            return 0  # ANTIZAPRET_WARP включён
        fi
    fi
    return 1  # ANTIZAPRET_WARP выключен или не найден
}

show_antizapret_warp_warning() {
    echo -e "${RED}================================================${NC}"
    echo -e "${RED}⚠️  ANTIZAPRET_WARP=y включён!${NC}"
    echo -e "${RED}================================================${NC}"
    echo -e "${YELLOW}WARPER не может работать при включённом ANTIZAPRET_WARP,${NC}"
    echo -e "${YELLOW}так как встроенный WARP AntiZapret конфликтует с WARPER.${NC}"
    echo -e ""
    echo -e "${CYAN}Для использования WARPER:${NC}"
    echo -e "1. Установите ANTIZAPRET_WARP=n в /root/antizapret/setup"
    echo -e "2. Выполните: /root/antizapret/doall.sh"
    echo -e "3. Запустите: warper"
    echo -e "${RED}================================================${NC}"
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

    local sb_run sb_en kr_stat dom_stat az_stat ap_stat subnet_conflict log_level mtu az_warp_stat
    if systemctl is-active --quiet sing-box; then sb_run="running"; else sb_run="stopped"; fi
    if systemctl is-enabled --quiet sing-box 2>/dev/null; then sb_en="enabled"; else sb_en="disabled"; fi
    if grep -q "WARP-MOD-START" "$KRESD_CONF" 2>/dev/null; then kr_stat="patched"; else kr_stat="not patched"; fi
    if domains_in_sync; then dom_stat="synced"; else dom_stat="not synced"; fi
    if grep -qF "$SUBNET" "$AZ_INC" 2>/dev/null; then az_stat="present"; else az_stat="missing"; fi
    if systemctl is-enabled --quiet warper-autopatch 2>/dev/null; then ap_stat="enabled"; else ap_stat="disabled"; fi
    if subnet_conflicts "$SUBNET"; then subnet_conflict="yes"; else subnet_conflict="no"; fi
    if check_antizapret_warp; then az_warp_stat="ENABLED (conflict!)"; else az_warp_stat="disabled"; fi
    log_level=$(get_log_level)
    mtu=$(get_mtu)

    echo "Version: $LOCAL_VER"
    echo "ANTIZAPRET_WARP: $az_warp_stat"
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
    # Проверка ANTIZAPRET_WARP
    if check_antizapret_warp; then
        echo -e "\n${RED}⚠️  ANTIZAPRET_WARP=y — изменения НЕ будут применены к DNS.${NC}"
        echo -e "${YELLOW}Домены сохранены в файл, но патч kresd не применён.${NC}"
        read -r -p "Нажмите Enter для продолжения..."
        return
    fi

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
    # Проверка ANTIZAPRET_WARP
    if check_antizapret_warp; then
        echo -e "${RED}ANTIZAPRET_WARP=y — патч kresd.conf не может быть применён.${NC}"
        return 1
    fi

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

    # Удаляем старые WARP-блоки
    sed '/-- \[WARP-MOD-START\]/,/-- \[WARP-MOD-END\]/d' "$KRESD_CONF" > "$clean_tmp"

    # Вставляем блок ТОЛЬКО в kresd@1 (перед "-- Resolve blocked domains using Proxy Resolver")
    awk '
    BEGIN {
        in_inst1=0
        inserted1=0
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
        print ""
    }

    /^if string.match\(systemd_instance, '\''\^1'\''\) then$/ {
        in_inst1=1
        print
        next
    }

    /^elseif string.match\(systemd_instance, '\''\^2'\''\) then$/ {
        in_inst1=0
        print
        next
    }

    # Вставляем блок только в kresd@1 перед "-- Resolve blocked domains using Proxy Resolver"
    in_inst1 && /^[[:space:]]*-- Resolve blocked domains using Proxy Resolver$/ && inserted1==0 {
        print_warp_block()
        inserted1=1
        print
        next
    }

    {
        print
    }

    END {
        if (inserted1 == 0) exit 42
    }
    ' "$clean_tmp" > "$tmpfile"
    local awk_rc=$?

    rm -f "$clean_tmp"

    if [ "$awk_rc" -ne 0 ]; then
        rm -f "$tmpfile"
        if [ "$awk_rc" -eq 42 ]; then
            echo -e "${RED}Не удалось найти точку вставки в kresd@1.${NC}"
            echo -e "${YELLOW}Ожидалась строка: '-- Resolve blocked domains using Proxy Resolver'${NC}"
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

    check_warning() {
        local label="$1"
        local cmd="$2"
        if eval "$cmd" >/dev/null 2>&1; then
            echo -e " ${YELLOW}!${NC} $label"
        else
            echo -e " ${GREEN}✔${NC} $label"
        fi
    }

    # Проверка ANTIZAPRET_WARP
    if check_antizapret_warp; then
        echo -e " ${RED}✘${NC} ANTIZAPRET_WARP=n (сейчас: ANTIZAPRET_WARP=y — WARPER не работает!)"
        failed=1
    else
        echo -e " ${GREEN}✔${NC} ANTIZAPRET_WARP=n"
    fi

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
    check_item "В kresd.conf ровно 1 WARP-блок (в kresd@1)" "[ \"\$(grep -c 'WARP-MOD-START' '$KRESD_CONF' 2>/dev/null)\" -eq 1 ]"
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
    # Проверка ANTIZAPRET_WARP
    if check_antizapret_warp; then
        show_antizapret_warp_warning
        read -r -p "Нажмите Enter для продолжения..."
        return
    fi

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
