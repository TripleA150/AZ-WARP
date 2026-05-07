def toggle_warper() -> tuple[bool, str]:
    """Включает или выключает WARPER целиком."""
    ok, out, err = _run_warper("toggle", timeout=180)  # было 60
    return ok, (out or err).strip()


def set_subnet(subnet: str) -> tuple[bool, str]:
    """Меняет fake-подсеть."""
    if not re.match(r"^\d{1,3}\.\d{1,3}\.\d{1,3}\.0/\d{1,2}$", subnet):
        return False, "Формат: X.X.X.0/M (например 198.20.0.0/24)"
    ok, out, err = _run_warper("subnet", subnet, timeout=300)  # было 120
    return ok, (out or err).strip()


def switch_to_warp(key_source: str = "") -> tuple[bool, str]:
    """key_source: '' | 'system' | 'wgcf' | 'root' | 'generate'."""
    args = ["mode", "warp"]
    if key_source:
        if key_source not in ("system", "wgcf", "root", "generate"):
            return False, "Недопустимый источник ключей"
        args.append(key_source)
    timeout = 180 if key_source == "generate" else 120  # было 90/60
    ok, out, err = _run_warper(*args, timeout=timeout)
    return ok, (out or err).strip()


def switch_to_slave(server: str, port: str | int, password: str) -> tuple[bool, str]:
    """Переключает на режим Slave."""
    server = server.strip()
    password = password.strip()

    # Валидация порта
    try:
        port_int = int(str(port).strip())
    except ValueError:
        return False, "Порт должен быть числом"
    if not 1 <= port_int <= 65535:
        return False, "Порт должен быть от 1 до 65535"

    # Валидация сервера
    if not server:
        return False, "Адрес сервера не может быть пустым"
    # IP или валидный домен (RFC 1123)
    ip_re = r"^(?:\d{1,3}\.){3}\d{1,3}$"
    domain_re = r"^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$"
    if re.match(ip_re, server):
        # Проверка октетов
        octets = server.split(".")
        for o in octets:
            if int(o) > 255:
                return False, "Некорректный IP-адрес"
    elif not re.match(domain_re, server):
        return False, "Некорректный адрес — IP или домен (example.com)"

    # Валидация ключа Shadowsocks
    if not password:
        return False, "Ключ Shadowsocks не может быть пустым"
    # Минимум 16 символов (короткие ключи небезопасны)
    if len(password) < 16:
        return False, "Ключ Shadowsocks должен быть минимум 16 символов"
    if len(password) > 256:
        return False, "Ключ Shadowsocks слишком длинный (>256 симв.)"

    ok, out, err = _run_warper("mode", "slave", server, str(port_int), password, timeout=120)
    return ok, (out or err).strip()


def switch_to_wg(conf_path: str) -> tuple[bool, str]:
    """Переключает на WG режим из указанного конфига."""
    conf_path = conf_path.strip()
    if not conf_path:
        return False, "Не указан путь к конфигу"
    if not os.path.isfile(conf_path):
        return False, f"Файл не найден: {conf_path}"
    ok, out, err = _run_warper("mode", "wg", conf_path, timeout=120)  # было 60
    return ok, (out or err).strip()


def remove_domain(domain: str) -> tuple[bool, str]:
    """Удаляет домен через `warper remove`."""
    ok, out, err = _run_warper("remove", domain, timeout=60)  # было 30
    return ok, (out or err).strip()


def toggle_list(list_name: str, enable: bool) -> tuple[bool, str]:
    """Включает или выключает встроенный список (gemini/chatgpt)."""
    if list_name not in ("gemini", "chatgpt"):
        return False, "Неизвестный список"
    cmd = "enable" if enable else "disable"
    ok, out, err = _run_warper(cmd, list_name, timeout=60)  # было 30
    return ok, (out or err).strip()


def sync_domains() -> tuple[bool, str]:
    """Синхронизирует домены и патчит kresd."""
    ok, out, err = _run_warper("sync", timeout=120)  # было 60
    return ok, (out or err).strip()


def singbox_action(action: str) -> tuple[bool, str]:
    """start / stop / restart / enable / disable."""
    if action not in ("start", "stop", "restart", "enable", "disable"):
        return False, "Недопустимое действие"
    rc, out, err = _run(["systemctl", action, "sing-box"], timeout=60)  # было 30
    return rc == 0, (out or err).strip() or f"sing-box {action} ok"
