"""
warper_api.py
Обёртка над CLI командами утилиты warper.
Возвращает структурированные данные (dict) с обработкой ошибок.
"""

import json
import os
import re
import subprocess
import shlex
from typing import Any


WARPER_BIN = "/usr/local/bin/warper"
SINGBOX_LOG_UNIT = "sing-box"


# ===== Базовые помощники =====

def _run(cmd: list[str], timeout: int = 60) -> tuple[int, str, str]:
    """Запускает команду, возвращает (rc, stdout, stderr)."""
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "Команда не завершилась за отведённое время"
    except FileNotFoundError as e:
        return 127, "", f"Файл не найден: {e}"
    except Exception as e:
        return 1, "", str(e)


def _run_warper(*args: str, timeout: int = 60) -> tuple[bool, str, str]:
    """Запускает warper с аргументами. Возвращает (ok, stdout, stderr)."""
    cmd = [WARPER_BIN, *args]
    rc, out, err = _run(cmd, timeout=timeout)
    return rc == 0, out.strip(), err.strip()


# ===== Статус =====

def get_status() -> dict[str, Any]:
    """
    Возвращает полный статус WARPER через `warper status json`.
    """
    ok, out, err = _run_warper("status", "json", timeout=30)
    if not ok:
        return {"error": err or "не удалось получить статус", "raw": out}
    try:
        return json.loads(out)
    except json.JSONDecodeError as e:
        return {"error": f"невалидный JSON: {e}", "raw": out}


def get_doctor() -> list[dict[str, Any]]:
    """
    Запускает `warper doctor` и парсит результат построчно.
    Возвращает список { 'status': 'ok'|'warn'|'error'|'info', 'text': '...' }.
    """
    ok, out, _ = _run_warper("doctor", timeout=60)
    results: list[dict[str, Any]] = []
    # Удаляем ANSI-цвета
    ansi = re.compile(r"\x1b\[[0-9;]*m")
    for raw_line in out.splitlines():
        line = ansi.sub("", raw_line).strip()
        if not line:
            continue
        # Игнорируем рамки и заголовки
        if line.startswith("==") or line.startswith("--") or "WARPER DOCTOR" in line:
            continue
        if "Диагностика завершена" in line:
            continue

        status = "info"
        if line.startswith("✔"):
            status = "ok"
        elif line.startswith("✘"):
            status = "error"
        elif line.startswith("!"):
            status = "warn"

        # Убираем символ статуса
        text = re.sub(r"^[✔✘!]\s*", "", line)
        results.append({"status": status, "text": text})
    return results


# ===== Логи =====

def get_logs(lines: int = 100, level_filter: str | None = None) -> list[dict[str, Any]]:
    """
    Возвращает логи sing-box. level_filter: None | 'INFO' | 'WARN' | 'ERROR'.
    """
    if lines < 1:
        lines = 100
    if lines > 2000:
        lines = 2000

    ok, out, _ = _run_warper("logs", str(lines), timeout=15)
    if not ok:
        return []

    parsed: list[dict[str, Any]] = []
    for raw in out.splitlines():
        line = raw.strip()
        if not line:
            continue

        # Определяем уровень
        level = "INFO"
        upper = line.upper()
        if "ERROR" in upper or " ERR " in upper:
            level = "ERROR"
        elif "WARN" in upper:
            level = "WARN"
        elif "DEBUG" in upper:
            level = "DEBUG"

        if level_filter and level != level_filter:
            continue

        parsed.append({"level": level, "text": line})
    return parsed


# ===== Домены =====

def get_domains(filter_type: str | None = None, search: str | None = None) -> list[dict[str, Any]]:
    """
    Возвращает список доменов через `warper domainslist`.
    filter_type: None | 'user' | 'gemini' | 'chatgpt'.
    """
    ok, out, _ = _run_warper("domainslist", timeout=10)
    if not ok:
        return []

    domains = []
    for raw in out.splitlines():
        line = raw.strip()
        if not line:
            continue
        parts = line.split("|")
        if len(parts) != 3:
            continue
        name, dtype, enabled = parts
        if filter_type and dtype != filter_type:
            continue
        if search and search.lower() not in name.lower():
            continue
        domains.append({
            "name": name,
            "type": dtype,
            "enabled": enabled == "1",
        })
    return domains


def add_domain(domain: str) -> tuple[bool, str]:
    """Добавляет домен через `warper add`."""
    domain = domain.strip().lower()
    if not _validate_domain_format(domain):
        return False, f"Некорректный формат домена: {domain}"
    ok, out, err = _run_warper("add", domain, timeout=30)
    msg = (out or err).strip()
    return ok, msg


def add_domains_bulk(domains: list[str]) -> dict[str, Any]:
    """Массово добавляет домены."""
    added: list[str] = []
    skipped: list[str] = []
    errors: list[dict[str, str]] = []

    for raw in domains:
        d = raw.strip().lower()
        if not d or d.startswith("#"):
            continue
        if not _validate_domain_format(d):
            errors.append({"domain": d, "error": "некорректный формат"})
            continue
        ok, out, err = _run_warper("add", d, timeout=15)
        if ok:
            if "уже есть" in out.lower() or "already" in out.lower():
                skipped.append(d)
            else:
                added.append(d)
        else:
            errors.append({"domain": d, "error": (err or out).strip()[:200]})

    return {
        "added_count": len(added),
        "skipped_count": len(skipped),
        "error_count": len(errors),
        "added": added,
        "skipped": skipped,
        "errors": errors,
    }


def remove_domain(domain: str) -> tuple[bool, str]:
    """Удаляет домен через `warper remove`."""
    ok, out, err = _run_warper("remove", domain, timeout=30)
    return ok, (out or err).strip()


def toggle_list(list_name: str, enable: bool) -> tuple[bool, str]:
    """Включает или выключает встроенный список (gemini/chatgpt)."""
    if list_name not in ("gemini", "chatgpt"):
        return False, "Неизвестный список"
    cmd = "enable" if enable else "disable"
    ok, out, err = _run_warper(cmd, list_name, timeout=30)
    return ok, (out or err).strip()


def sync_domains() -> tuple[bool, str]:
    """Синхронизирует домены и патчит kresd."""
    ok, out, err = _run_warper("sync", timeout=60)
    return ok, (out or err).strip()


def _validate_domain_format(domain: str) -> bool:
    """
    Проверяет формат домена:
    - минимум 2 уровня (example.com)
    - только латиница, цифры, точка, дефис
    - не начинается/заканчивается дефисом или точкой
    """
    if not domain or len(domain) > 253:
        return False
    if "." not in domain:
        return False
    parts = domain.split(".")
    if len(parts) < 2:
        return False
    if len(parts[-1]) < 2:  # TLD минимум 2 символа
        return False
    for part in parts:
        if not part or len(part) > 63:
            return False
        if part.startswith("-") or part.endswith("-"):
            return False
        if not re.match(r"^[a-z0-9_-]+$", part):
            return False
    return True


# ===== IP-подсети =====

def get_ip_ranges(search: str | None = None) -> list[dict[str, str]]:
    """Возвращает список CIDR из ip-ranges.txt."""
    ok, out, _ = _run_warper("iplist", timeout=10)
    if not ok:
        return []
    ranges = []
    for line in out.splitlines():
        cidr = line.strip()
        if not cidr:
            continue
        if search and search not in cidr:
            continue
        ranges.append({"cidr": cidr})
    return ranges


def get_active_ip_routes() -> list[str]:
    """Возвращает список применённых маршрутов."""
    ok, out, _ = _run_warper("iproutes", timeout=10)
    if not ok:
        return []
    return [line.strip() for line in out.splitlines() if line.strip()]


def add_ip_range(cidr: str) -> tuple[bool, str]:
    """Добавляет CIDR. Если без маски — добавится /32."""
    cidr = cidr.strip()
    # Если без маски - предполагаем /32
    if "/" not in cidr:
        cidr = f"{cidr}/32"
    if not _validate_cidr_format(cidr):
        return False, f"Некорректный формат CIDR: {cidr}"
    ok, out, err = _run_warper("ipadd", cidr, timeout=30)
    return ok, (out or err).strip()


def add_ip_ranges_bulk(cidrs: list[str]) -> dict[str, Any]:
    """Массово добавляет CIDR."""
    added: list[str] = []
    skipped: list[str] = []
    errors: list[dict[str, str]] = []

    for raw in cidrs:
        c = raw.strip()
        if not c or c.startswith("#"):
            continue
        if "/" not in c:
            c = f"{c}/32"
        if not _validate_cidr_format(c):
            errors.append({"cidr": c, "error": "некорректный формат"})
            continue
        ok, out, err = _run_warper("ipadd", c, timeout=15)
        if ok:
            if "уже есть" in out.lower():
                skipped.append(c)
            else:
                added.append(c)
        else:
            errors.append({"cidr": c, "error": (err or out).strip()[:200]})

    return {
        "added_count": len(added),
        "skipped_count": len(skipped),
        "error_count": len(errors),
        "added": added,
        "skipped": skipped,
        "errors": errors,
    }


def remove_ip_range(cidr: str) -> tuple[bool, str]:
    """Удаляет CIDR."""
    ok, out, err = _run_warper("ipremove", cidr, timeout=30)
    return ok, (out or err).strip()


def sync_ip_ranges() -> tuple[bool, str]:
    """Синхронизирует kernel routes с файлом."""
    ok, out, err = _run_warper("ipsync", timeout=60)
    return ok, (out or err).strip()


def set_ip_route_mode(mode: str) -> tuple[bool, str]:
    """Меняет режим IP-маршрутов: antizapret | all_vpn | all."""
    if mode not in ("antizapret", "all_vpn", "all"):
        return False, "Недопустимый режим"
    ok, out, err = _run_warper("iproutemode", mode, timeout=30)
    return ok, (out or err).strip()


def set_ip_export(enable: bool) -> tuple[bool, str]:
    """Включает/выключает экспорт CIDR в AntiZapret."""
    val = "on" if enable else "off"
    ok, out, err = _run_warper("ipexport", val, timeout=30)
    return ok, (out or err).strip()


def _validate_cidr_format(cidr: str) -> bool:
    """Проверяет формат A.B.C.D/M с валидными октетами."""
    m = re.match(r"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})$", cidr)
    if not m:
        return False
    octets = [int(x) for x in m.groups()[:4]]
    mask = int(m.group(5))
    for o in octets:
        if o > 255:
            return False
    if not 1 <= mask <= 32:
        return False
    # Не loopback / multicast / link-local
    if octets[0] in (0, 127) or octets[0] >= 224:
        return False
    if octets[0] == 169 and octets[1] == 254:
        return False
    return True


# ===== Sing-box =====

def singbox_action(action: str) -> tuple[bool, str]:
    """start / stop / restart / enable / disable."""
    if action not in ("start", "stop", "restart", "enable", "disable"):
        return False, "Недопустимое действие"
    rc, out, err = _run(["systemctl", action, "sing-box"], timeout=30)
    return rc == 0, (out or err).strip() or f"sing-box {action} ok"


# ===== WARPER toggle =====

def toggle_warper() -> tuple[bool, str]:
    """Включает или выключает WARPER целиком."""
    ok, out, err = _run_warper("toggle", timeout=60)
    return ok, (out or err).strip()


def patch_kresd() -> tuple[bool, str]:
    """Применяет патч DNS."""
    ok, out, err = _run_warper("patch", timeout=30)
    return ok, (out or err or "kresd пропатчен").strip()


# ===== Настройки =====

def set_log_level(level: str) -> tuple[bool, str]:
    if level not in ("debug", "info", "warn", "error"):
        return False, "Недопустимый log level"
    ok, out, err = _run_warper("loglevel", level, timeout=30)
    return ok, (out or err).strip()


def set_mtu(mtu: int) -> tuple[bool, str]:
    if not 1280 <= mtu <= 1500:
        return False, "MTU должен быть от 1280 до 1500"
    ok, out, err = _run_warper("mtu", str(mtu), timeout=30)
    return ok, (out or err).strip()


def set_subnet(subnet: str) -> tuple[bool, str]:
    """Меняет fake-подсеть."""
    if not re.match(r"^\d{1,3}\.\d{1,3}\.\d{1,3}\.0/\d{1,2}$", subnet):
        return False, "Формат: X.X.X.0/M"
    ok, out, err = _run_warper("subnet", subnet, timeout=120)
    return ok, (out or err).strip()


def set_autopatch(enable: bool) -> tuple[bool, str]:
    val = "on" if enable else "off"
    ok, out, err = _run_warper("autopatch", val, timeout=15)
    return ok, (out or err).strip()


def set_fullvpn(enable: bool) -> tuple[bool, str]:
    val = "on" if enable else "off"
    ok, out, err = _run_warper("fullvpn", val, timeout=30)
    return ok, (out or err).strip()


# ===== Режим маршрутизации =====

def switch_to_warp(key_source: str = "") -> tuple[bool, str]:
    """key_source: '' | 'system' | 'wgcf' | 'root' | 'generate'."""
    args = ["mode", "warp"]
    if key_source:
        if key_source not in ("system", "wgcf", "root", "generate"):
            return False, "Недопустимый источник ключей"
        args.append(key_source)
    timeout = 90 if key_source == "generate" else 60
    ok, out, err = _run_warper(*args, timeout=timeout)
    return ok, (out or err).strip()


def switch_to_slave(server: str, port: str | int, password: str) -> tuple[bool, str]:
    """Переключает на режим Slave."""
    server = server.strip()
    password = password.strip()
    try:
        port_int = int(str(port).strip())
    except ValueError:
        return False, "Порт должен быть числом"
    if not 1 <= port_int <= 65535:
        return False, "Порт должен быть от 1 до 65535"
    if not server:
        return False, "Адрес сервера не может быть пустым"
    if not password:
        return False, "Ключ Shadowsocks не может быть пустым"
    if not re.match(r"^[0-9a-zA-Z._:-]+$", server):
        return False, "Некорректный адрес сервера"

    ok, out, err = _run_warper("mode", "slave", server, str(port_int), password, timeout=60)
    return ok, (out or err).strip()


def switch_to_wg(conf_path: str) -> tuple[bool, str]:
    """Переключает на WG режим из указанного конфига."""
    conf_path = conf_path.strip()
    if not conf_path:
        return False, "Не указан путь к конфигу"
    if not os.path.isfile(conf_path):
        return False, f"Файл не найден: {conf_path}"
    ok, out, err = _run_warper("mode", "wg", conf_path, timeout=60)
    return ok, (out or err).strip()


# ===== WARP-ключи =====

def list_warp_keys() -> list[dict[str, Any]]:
    """Возвращает доступные источники WARP-ключей."""
    ok, out, _ = _run_warper("warpkey", "list", timeout=10)
    if not ok:
        return []
    keys = []
    for line in out.splitlines():
        parts = line.strip().split("|")
        if len(parts) != 4:
            continue
        keys.append({
            "source": parts[0],
            "path": parts[1],
            "address": parts[2],
            "is_current": parts[3] == "1",
        })
    return keys


# ===== WG-конфиги =====

def list_wg_configs() -> list[dict[str, str]]:
    """Возвращает список WG-конфигов в /root/ и /root/warper/."""
    ok, out, _ = _run_warper("wgconfig", "list", timeout=10)
    if not ok:
        return []
    configs = []
    for line in out.splitlines():
        parts = line.strip().split("|")
        if len(parts) != 2:
            continue
        configs.append({
            "path": parts[0],
            "endpoint": parts[1],
            "name": os.path.basename(parts[0]),
        })
    return configs


def upload_wg_config(filename: str, content: str) -> tuple[bool, str, str]:
    """
    Сохраняет загруженный WG-конфиг в /root/warper/<safe_name>.
    Возвращает (ok, message, saved_path).
    """
    # Очищаем имя файла
    safe_name = re.sub(r"[^A-Za-z0-9._-]", "_", os.path.basename(filename))
    if not safe_name.endswith(".conf"):
        safe_name += ".conf"

    target_dir = "/root/warper"
    os.makedirs(target_dir, exist_ok=True)
    target_path = os.path.join(target_dir, safe_name)

    # Базовая валидация содержимого
    if "[Peer]" not in content or "Endpoint" not in content or "PublicKey" not in content:
        return False, "Файл не похож на WireGuard конфиг", ""

    # Cloudflare WARP - запрещено
    cf_markers = [
        "engage.cloudflareclient.com",
        "162.159.192.1",
        "162.159.193.1",
        "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
    ]
    for m in cf_markers:
        if m in content:
            return False, "Это Cloudflare WARP конфиг, не подходит для режима WG", ""

    try:
        with open(target_path, "w", encoding="utf-8") as f:
            f.write(content)
        os.chmod(target_path, 0o600)
    except OSError as e:
        return False, f"Ошибка сохранения: {e}", ""

    return True, f"Конфиг сохранён: {target_path}", target_path
