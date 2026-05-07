# AZ-WARP Web Panel

Веб-интерфейс управления WARPER на Flask + HTMX.

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/Liafanx/AZ-WARP/1.3.2/web/install-web.sh | bash
```

## Удаление

```bash
curl -fsSL https://raw.githubusercontent.com/Liafanx/AZ-WARP/1.3.2/web/uninstall-web.sh | bash
```

## Стек

- Flask 3 + Flask-Login + Flask-Bcrypt
- HTMX 2 (без сборки)
- Tailwind CSS (CDN-build, офлайн)
- Gunicorn под systemd
- Nginx как reverse proxy

## Команды на сервере

```bash
systemctl status warper-web
systemctl restart warper-web
journalctl -u warper-web -f
cat /root/warper/web_admin_pass.txt
```
