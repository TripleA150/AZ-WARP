"""
auth.py
Безопасная авторизация:
- Хеш пароля хранится в БД (web/data/users.json) с правами 600
- SECRET_KEY в отдельном файле web/data/secret.key (600)
- Защита от brute-force: 5 попыток → блокировка IP на 15 минут
- Валидация логина регулярным выражением
- Сравнение паролей с защитой от timing-атак
- Аудит-лог входов/неудач
"""

import hmac
import json
import logging
import os
import re
import secrets
import time
from datetime import datetime
from pathlib import Path
from threading import Lock

from flask import Flask, request
from flask_bcrypt import Bcrypt
from flask_login import LoginManager, UserMixin


bcrypt = Bcrypt()
login_manager = LoginManager()
logger = logging.getLogger(__name__)

# Пути к файлам данных
DATA_DIR = Path(__file__).parent / "data"
USERS_FILE = DATA_DIR / "users.json"
SECRET_FILE = DATA_DIR / "secret.key"
AUTH_LOG = DATA_DIR / "auth.log"
ADMIN_PASS_FILE = Path("/root/warper/web_admin_pass.txt")

# Защита от brute-force
MAX_ATTEMPTS = 5
BLOCK_DURATION = 15 * 60  # 15 минут
_attempts_lock = Lock()
_failed_attempts: dict[str, list[float]] = {}  # IP -> [timestamp, ...]
_blocked_ips: dict[str, float] = {}  # IP -> unblock_at

# Валидация логина: 3-32 символа, латиница/цифры/_-
LOGIN_RE = re.compile(r"^[A-Za-z0-9_-]{3,32}$")
PASSWORD_MIN_LEN = 6
PASSWORD_MAX_LEN = 256


def _ensure_data_dir() -> None:
    """Создаёт data/ с правильными правами (700)."""
    DATA_DIR.mkdir(mode=0o700, exist_ok=True)
    # На случай если папка уже была с другими правами
    try:
        os.chmod(DATA_DIR, 0o700)
    except OSError:
        pass


def _audit_log(event: str, ip: str, username: str = "", extra: str = "") -> None:
    """Аудит-лог авторизации."""
    try:
        _ensure_data_dir()
        with open(AUTH_LOG, "a", encoding="utf-8") as f:
            ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            user_part = f" user={username}" if username else ""
            extra_part = f" {extra}" if extra else ""
            f.write(f"{ts} ip={ip} event={event}{user_part}{extra_part}\n")
        os.chmod(AUTH_LOG, 0o600)
    except OSError:
        pass


def get_or_create_secret_key() -> str:
    """
    Читает SECRET_KEY из web/data/secret.key или создаёт новый.
    Файл всегда с правами 600.
    Приоритет: файл → переменная окружения → новый.
    """
    _ensure_data_dir()

    if SECRET_FILE.exists():
        try:
            key = SECRET_FILE.read_text(encoding="utf-8").strip()
            if len(key) >= 32:
                return key
        except OSError:
            pass

    # Миграция: если есть в .env, переносим в файл
    env_key = os.environ.get("SECRET_KEY", "").strip()
    if env_key and len(env_key) >= 32:
        try:
            SECRET_FILE.write_text(env_key + "\n", encoding="utf-8")
            os.chmod(SECRET_FILE, 0o600)
            return env_key
        except OSError:
            return env_key  # хоть так

    # Генерируем новый
    new_key = secrets.token_hex(32)
    try:
        SECRET_FILE.write_text(new_key + "\n", encoding="utf-8")
        os.chmod(SECRET_FILE, 0o600)
    except OSError as e:
        logger.error("Не удалось сохранить SECRET_KEY: %s", e)
    return new_key


def _load_users() -> dict:
    """Читает БД пользователей. Возвращает {} если файла нет."""
    if not USERS_FILE.exists():
        return {}
    try:
        with open(USERS_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def _save_users(users: dict) -> bool:
    """Сохраняет БД пользователей с правами 600."""
    _ensure_data_dir()
    try:
        # Атомарная запись через временный файл
        tmp = USERS_FILE.with_suffix(".tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(users, f, indent=2, ensure_ascii=False)
        os.chmod(tmp, 0o600)
        tmp.replace(USERS_FILE)
        os.chmod(USERS_FILE, 0o600)
        return True
    except OSError as e:
        logger.error("Не удалось сохранить users.json: %s", e)
        return False


def _migrate_from_env() -> None:
    """
    Однократная миграция: если БД пуста, но в .env есть ADMIN_USER/ADMIN_PASSWORD —
    переносим в БД, потом затираем из памяти. После этого пользователь должен
    удалить пароль из .env вручную (мы выведем warning).
    """
    users = _load_users()
    if users:
        return  # уже есть БД, ничего не делаем

    env_user = os.environ.get("ADMIN_USER", "").strip()
    env_pass = os.environ.get("ADMIN_PASSWORD", "").strip()

    if not env_user or not env_pass:
        # Нет данных для миграции — создаём дефолтного admin/admin (требует смены)
        env_user = env_user or "admin"
        if not env_pass:
            env_pass = "admin"
            logger.warning(
                "Учётные данные не настроены. Создан admin/admin. "
                "СМЕНИТЕ ПАРОЛЬ через настройки веб-панели!"
            )

    if not LOGIN_RE.match(env_user):
        logger.error("Некорректный ADMIN_USER в .env: %s. Использую 'admin'.", env_user)
        env_user = "admin"

    # Хешируем (если уже хеш — оставляем)
    if env_pass.startswith(("$2b$", "$2a$", "$2y$")):
        pass_hash = env_pass
    else:
        pass_hash = bcrypt.generate_password_hash(env_pass).decode("utf-8")

    users = {
        env_user: {
            "password_hash": pass_hash,
            "created_at": datetime.now().isoformat(timespec="seconds"),
            "last_login": None,
        }
    }

    if _save_users(users):
        logger.warning(
            "Учётные данные мигрированы из .env в %s. "
            "УДАЛИТЕ строки ADMIN_USER и ADMIN_PASSWORD из .env вручную для безопасности.",
            USERS_FILE,
        )
        # Затираем из окружения процесса
        os.environ.pop("ADMIN_PASSWORD", None)


class AdminUser(UserMixin):
    """Пользователь системы."""

    def __init__(self, username: str):
        self.id = username
        self.username = username


def init_auth(app: Flask) -> None:
    """Инициализирует Flask-Login и Flask-Bcrypt + миграцию."""
    _ensure_data_dir()
    bcrypt.init_app(app)
    login_manager.init_app(app)
    login_manager.login_view = "login"
    login_manager.login_message = "Требуется авторизация"
    login_manager.login_message_category = "warning"

    # Миграция из .env при первом запуске
    _migrate_from_env()

    @login_manager.user_loader
    def load_user(user_id: str) -> AdminUser | None:
        if not LOGIN_RE.match(user_id):
            return None
        users = _load_users()
        if user_id in users:
            return AdminUser(user_id)
        return None


# ===== Brute-force защита =====

def _cleanup_old_attempts(now: float) -> None:
    """Удаляет старые попытки и истёкшие блокировки."""
    # Чистим блокировки
    expired = [ip for ip, until in _blocked_ips.items() if until <= now]
    for ip in expired:
        del _blocked_ips[ip]

    # Чистим попытки старше окна
    window = BLOCK_DURATION
    for ip in list(_failed_attempts.keys()):
        _failed_attempts[ip] = [t for t in _failed_attempts[ip] if now - t < window]
        if not _failed_attempts[ip]:
            del _failed_attempts[ip]


def is_ip_blocked(ip: str) -> tuple[bool, int]:
    """Возвращает (blocked, seconds_left)."""
    with _attempts_lock:
        now = time.time()
        _cleanup_old_attempts(now)
        if ip in _blocked_ips:
            return True, int(_blocked_ips[ip] - now)
        return False, 0


def _register_failed_attempt(ip: str) -> tuple[int, bool]:
    """
    Регистрирует неудачную попытку.
    Возвращает (попыток_сделано, заблокирован_сейчас).
    """
    with _attempts_lock:
        now = time.time()
        _cleanup_old_attempts(now)
        attempts = _failed_attempts.setdefault(ip, [])
        attempts.append(now)
        if len(attempts) >= MAX_ATTEMPTS:
            _blocked_ips[ip] = now + BLOCK_DURATION
            del _failed_attempts[ip]
            return MAX_ATTEMPTS, True
        return len(attempts), False


def _clear_attempts(ip: str) -> None:
    """Сбрасывает счётчик попыток для IP (при успешном входе)."""
    with _attempts_lock:
        _failed_attempts.pop(ip, None)


def _get_client_ip() -> str:
    """Получает реальный IP клиента (с учётом X-Forwarded-For от nginx)."""
    xff = request.headers.get("X-Forwarded-For", "")
    if xff:
        # Берём первый IP из цепочки
        return xff.split(",")[0].strip()
    return request.remote_addr or "unknown"


# ===== Валидация и проверка =====

def _safe_str_compare(a: str, b: str) -> bool:
    """Сравнение строк за константное время (защита от timing-атак)."""
    return hmac.compare_digest(a.encode("utf-8"), b.encode("utf-8"))


def verify_credentials(username: str, password: str) -> tuple[bool, str]:
    """
    Проверяет логин и пароль.
    Возвращает (успех, сообщение_об_ошибке_если_не_успех).
    Учитывает brute-force защиту.
    """
    ip = _get_client_ip()

    # Проверка блокировки
    blocked, seconds_left = is_ip_blocked(ip)
    if blocked:
        minutes = (seconds_left + 59) // 60
        _audit_log("blocked_attempt", ip, username)
        return False, f"Слишком много попыток. Попробуйте через {minutes} мин."

    # Валидация формата (не выдаём конкретику, чтобы не помогать атакующему)
    if not username or not password:
        _register_failed_attempt(ip)
        _audit_log("empty_credentials", ip)
        return False, "Неверный логин или пароль"

    username = username.strip()
    if not LOGIN_RE.match(username):
        _register_failed_attempt(ip)
        _audit_log("invalid_login_format", ip, username)
        return False, "Неверный логин или пароль"

    if not (PASSWORD_MIN_LEN <= len(password) <= PASSWORD_MAX_LEN):
        _register_failed_attempt(ip)
        _audit_log("invalid_password_length", ip, username)
        return False, "Неверный логин или пароль"

    # Загружаем пользователя
    users = _load_users()
    user_data = users.get(username)

    # Чтобы атакующий не мог различить "юзера нет" и "пароль неверный" по времени,
    # всегда выполняем bcrypt-проверку (даже если юзера нет — с фейковым хешем).
    fake_hash = "$2b$12$fakefakefakefakefakefakefakefakefakefakefakefakefakefakefa"
    stored_hash = user_data["password_hash"] if user_data else fake_hash

    try:
        password_ok = bcrypt.check_password_hash(stored_hash, password)
    except ValueError:
        password_ok = False

    if not user_data or not password_ok:
        attempts, just_blocked = _register_failed_attempt(ip)
        if just_blocked:
            _audit_log("blocked_now", ip, username, f"after {MAX_ATTEMPTS} attempts")
            return False, f"Превышено число попыток. IP заблокирован на {BLOCK_DURATION // 60} мин."
        _audit_log("login_failed", ip, username, f"attempt={attempts}/{MAX_ATTEMPTS}")
        remaining = MAX_ATTEMPTS - attempts
        return False, f"Неверный логин или пароль (осталось попыток: {remaining})"

    # Успех — обновляем last_login
    user_data["last_login"] = datetime.now().isoformat(timespec="seconds")
    users[username] = user_data
    _save_users(users)

    # Сбрасываем счётчик попыток
    _clear_attempts(ip)
    _audit_log("login_success", ip, username)

    # Удаляем web_admin_pass.txt при первом успешном входе
    if ADMIN_PASS_FILE.exists():
        try:
            ADMIN_PASS_FILE.unlink()
            logger.info("web_admin_pass.txt удалён после первого входа")
        except OSError:
            pass

    return True, ""


def update_credentials(new_username: str, new_password: str, current_username: str) -> tuple[bool, str]:
    """
    Меняет логин и пароль текущего пользователя.
    Удаляет старого пользователя и создаёт нового.
    """
    new_username = new_username.strip()

    if not LOGIN_RE.match(new_username):
        return False, "Логин: 3-32 символа, только латиница, цифры, _ и -"

    if not new_password or len(new_password) < PASSWORD_MIN_LEN:
        return False, f"Пароль должен быть минимум {PASSWORD_MIN_LEN} символов"

    if len(new_password) > PASSWORD_MAX_LEN:
        return False, f"Пароль слишком длинный (максимум {PASSWORD_MAX_LEN})"

    users = _load_users()

    # Хешируем новый пароль
    try:
        new_hash = bcrypt.generate_password_hash(new_password).decode("utf-8")
    except Exception as e:
        return False, f"Ошибка хеширования: {e}"

    # Удаляем текущего, создаём нового
    users.pop(current_username, None)
    users[new_username] = {
        "password_hash": new_hash,
        "created_at": datetime.now().isoformat(timespec="seconds"),
        "last_login": None,
    }

    if not _save_users(users):
        return False, "Ошибка сохранения учётных данных"

    ip = _get_client_ip()
    _audit_log("credentials_changed", ip, current_username, f"new={new_username}")

    return True, "Учётные данные обновлены. Войдите заново."
