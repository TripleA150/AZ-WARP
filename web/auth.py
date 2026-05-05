"""
auth.py
Простая авторизация с одним пользователем.
Хеш пароля и логин читаются из .env, изменяются через UI -> .env.
"""

import os
import re
from pathlib import Path

from flask import Flask
from flask_bcrypt import Bcrypt
from flask_login import LoginManager, UserMixin


bcrypt = Bcrypt()
login_manager = LoginManager()


class AdminUser(UserMixin):
    """Единственный администратор системы."""

    def __init__(self, username: str):
        self.id = username
        self.username = username


def init_auth(app: Flask) -> None:
    """Инициализирует Flask-Login и Flask-Bcrypt."""
    bcrypt.init_app(app)
    login_manager.init_app(app)
    login_manager.login_view = "login"
    login_manager.login_message = "Требуется авторизация"
    login_manager.login_message_category = "warning"

    @login_manager.user_loader
    def load_user(user_id: str) -> AdminUser | None:
        if user_id == _get_admin_user():
            return AdminUser(user_id)
        return None


def _get_admin_user() -> str:
    return os.environ.get("ADMIN_USER", "admin").strip() or "admin"


def _get_admin_password() -> str:
    return os.environ.get("ADMIN_PASSWORD", "").strip()


def verify_credentials(username: str, password: str) -> bool:
    """Проверяет логин и пароль."""
    if username.strip() != _get_admin_user():
        return False

    stored = _get_admin_password()
    if not stored:
        return False

    # Если пароль уже захеширован bcrypt — проверяем хеш
    if stored.startswith("$2b$") or stored.startswith("$2a$") or stored.startswith("$2y$"):
        try:
            return bcrypt.check_password_hash(stored, password)
        except ValueError:
            return False

    # Иначе сравниваем как plain (первый запуск, потом захешируем)
    return stored == password


def update_credentials(new_username: str, new_password: str) -> tuple[bool, str]:
    """
    Обновляет логин и пароль в .env файле.
    Пароль сохраняется в виде bcrypt-хеша.
    """
    new_username = new_username.strip()
    if not new_username:
        return False, "Логин не может быть пустым"
    if not re.match(r"^[A-Za-z0-9_-]{3,32}$", new_username):
        return False, "Логин: 3-32 символа, латиница/цифры/_-"
    if not new_password or len(new_password) < 6:
        return False, "Пароль должен быть минимум 6 символов"

    hashed = bcrypt.generate_password_hash(new_password).decode("utf-8")
    env_path = Path(__file__).parent / ".env"

    try:
        if env_path.exists():
            lines = env_path.read_text(encoding="utf-8").splitlines()
        else:
            lines = []

        # Обновляем или добавляем строки
        out_lines: list[str] = []
        seen_user = False
        seen_pass = False
        for line in lines:
            if line.startswith("ADMIN_USER="):
                out_lines.append(f"ADMIN_USER={new_username}")
                seen_user = True
            elif line.startswith("ADMIN_PASSWORD="):
                out_lines.append(f"ADMIN_PASSWORD={hashed}")
                seen_pass = True
            else:
                out_lines.append(line)
        if not seen_user:
            out_lines.append(f"ADMIN_USER={new_username}")
        if not seen_pass:
            out_lines.append(f"ADMIN_PASSWORD={hashed}")

        env_path.write_text("\n".join(out_lines) + "\n", encoding="utf-8")
        os.chmod(env_path, 0o600)

        # Обновляем переменные окружения текущего процесса
        os.environ["ADMIN_USER"] = new_username
        os.environ["ADMIN_PASSWORD"] = hashed

        return True, "Учётные данные обновлены"
    except OSError as e:
        return False, f"Ошибка записи: {e}"
