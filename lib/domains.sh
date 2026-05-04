#!/bin/bash
# warper lib: domains.sh
# Работа со списком доменов: чтение, запись, синхронизация,
# включение/выключение встроенных списков (Gemini, ChatGPT).
# Подключается через source из warper.sh

# ===== Проверка блоков =====

# Проверяет наличие маркера встроенного списка в domains.txt
has_list_block() {
    local list_name="$1"
    grep -qxF "# --- ${list_name^^} ---" "$MASTER_FILE" 2>/dev/null
}

# ===== Извлечение доменов =====

# Извлекает пользовательские домены из domains.txt,
# исключая блоки Gemini/ChatGPT и комментарии
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

# Извлекает блок встроенного списка (например, GEMINI или CHATGPT)
# вместе с маркерами начала и конца
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

# ===== Пересборка мастер-файла =====

# Пересобирает domains.txt из трёх частей:
# 1) пользовательские домены
# 2) блок GEMINI (если был)
# 3) блок CHATGPT (если был)
# Обеспечивает корректный порядок и отсутствие дублей
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
        if [ -s "$user_tmp" ]; then cat "$user_tmp"; fi
        if [ -s "$gemini_tmp" ]; then echo ""; cat "$gemini_tmp"; fi
        if [ -s "$chatgpt_tmp" ]; then echo ""; cat "$chatgpt_tmp"; fi
    } > "$tmp"

    mv "$tmp" "$output_file"
    rm -f "$user_tmp" "$gemini_tmp" "$chatgpt_tmp"
}

# Вычисляет канонический хэш domains.txt после нормализации.
# Используется для определения изменений при редактировании в nano.
canonical_master_hash() {
    local tmp result
    tmp=$(mktemp)
    rebuild_master_file "$MASTER_FILE" "$tmp"
    result=$(sha256sum "$tmp" | awk '{print $1}')
    rm -f "$tmp"
    echo "$result"
}

# Добавляет домен в секцию "Пользовательские домены:" файла domains.txt.
# Не добавляет дубликаты.
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

# ===== Фильтрация и синхронизация =====

# Фильтрует файл доменов: убирает комментарии, пустые строки,
# невалидные домены; сортирует и дедуплицирует
filter_valid_domains_file() {
    local input="$1" output="$2"
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

# Синхронизирует domains.txt → warper-domains.txt (активный список для kresd)
sync_domains() {
    local tmp
    tmp=$(mktemp /tmp/warper_sync.XXXXXX)
    filter_valid_domains_file "$MASTER_FILE" "$tmp"
    mv "$tmp" "$ACTIVE_FILE"
    chmod 644 "$ACTIVE_FILE"
}

# Проверяет: соответствует ли активный список (warper-domains.txt)
# текущему содержимому domains.txt
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
    if cmp -s "$tmp_master" "$tmp_active"; then result=0; fi
    rm -f "$tmp_master" "$tmp_active"
    return "$result"
}

# ===== Управление встроенными списками =====

# Включает или выключает встроенный список доменов (gemini/chatgpt).
# action: "enable" или "disable"
enable_disable_list() {
    local action="$1" list_name="$2"
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
        { echo ""; echo "$marker"; cat "$valid_tmp"; echo "$end_marker"; } >> "${tmp}.new"
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

# Переключает состояние встроенного списка (вкл↔выкл)
# и предлагает применить изменения к DNS
toggle_list() {
    local list_name=$1
    if has_list_block "$list_name"; then
        enable_disable_list disable "$list_name"
    else
        enable_disable_list enable "$list_name"
    fi
    prompt_apply
}

# Обновляет содержимое включённых встроенных списков
# (пересоздаёт блоки из актуальных файлов в download/)
update_list_blocks() {
    for list_name in "gemini" "chatgpt"; do
        if has_list_block "$list_name"; then
            enable_disable_list disable "$list_name" >/dev/null 2>&1 || true
            enable_disable_list enable "$list_name" >/dev/null 2>&1 || true
        fi
    done
}

# ===== CLI-команды =====

# CLI: добавить домен в список маршрутизации
cli_add_domain() {
    local raw="$1"
    local domain
    domain=$(validate_domain "$raw") || {
        echo -e "${RED}Некорректный домен: $raw${NC}" >&2; return 1
    }
    if grep -qxF "$domain" "$MASTER_FILE"; then
        echo -e "${YELLOW}Домен уже есть: $domain${NC}"; return 0
    fi
    insert_user_domain "$domain"
    if is_warper_active; then
        patch_kresd >/dev/null 2>&1 || true
    else
        sync_domains
    fi
    echo -e "${GREEN}Домен добавлен: $domain${NC}"
    return 0
}

# CLI: удалить домен из списка маршрутизации
cli_remove_domain() {
    local raw="$1"
    local domain
    domain=$(validate_domain "$raw") || {
        echo -e "${RED}Некорректный домен: $raw${NC}" >&2; return 1
    }
    if grep -qxF "$domain" "$MASTER_FILE"; then
        local escaped
        escaped=$(escape_regex "$domain")
        sed -i "/^${escaped}$/d" "$MASTER_FILE"
        rebuild_master_file
        if is_warper_active; then
            patch_kresd >/dev/null 2>&1 || true
        else
            sync_domains
        fi
        echo -e "${GREEN}Домен удалён: $domain${NC}"
        return 0
    fi
    echo -e "${YELLOW}Домен не найден: $domain${NC}"
    return 0
}

# CLI: включить встроенный список (gemini/chatgpt)
cli_enable_list() {
    local list_name="$1"
    case "$list_name" in
        gemini|chatgpt)
            enable_disable_list enable "$list_name" || return 1
            if is_warper_active; then
                patch_kresd >/dev/null 2>&1 || true
            else
                sync_domains
            fi
            ;;
        *) echo -e "${RED}Неизвестный список: $list_name${NC}" >&2; return 1 ;;
    esac
}

# CLI: выключить встроенный список (gemini/chatgpt)
cli_disable_list() {
    local list_name="$1"
    case "$list_name" in
        gemini|chatgpt)
            enable_disable_list disable "$list_name" || return 1
            if is_warper_active; then
                patch_kresd >/dev/null 2>&1 || true
            else
                sync_domains
            fi
            ;;
        *) echo -e "${RED}Неизвестный список: $list_name${NC}" >&2; return 1 ;;
    esac
}
