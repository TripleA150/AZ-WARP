# 🏗 Архитектура WARPER

## Общая схема

```
AntiZapret-клиенты → kresd@1 → WARPER-домены → sing-box → WARP / Slave / WG
                             → остальное → обычная маршрутизация

FullVPN-клиенты → kresd@2 → всё → встроенный WARP автора (при VPN_WARP=y)
```

## Компоненты

| Компонент | Расположение | Назначение |
|---|---|---|
| warper.sh | /root/warper/ | Основной скрипт управления |
| sing-box | /usr/bin/sing-box | Прокси-ядро (tun + DNS + WireGuard/SS) |
| kresd | /etc/knot-resolver/ | DNS-резолвер AntiZapret |
| config.json | /etc/sing-box/ | Конфиг sing-box |
| warper-domains.txt | /etc/knot-resolver/ | Активный список доменов |
| domains.txt | /root/warper/ | Мастер-файл доменов |
| warper.conf | /root/warper/ | Настройки (подсеть, TUN IP) |
| slave_mode.conf | /root/warper/ | Настройки режима (WARP/Slave/WG) |
| wg_mode.conf | /root/warper/ | Параметры WG-соединения |

## Режим WARP

```
kresd@1 → fake-ip (198.20.0.0/24) → singbox-tun → WireGuard endpoint → Cloudflare WARP
```

## Режим Slave

```
kresd@1 → fake-ip → singbox-tun → Shadowsocks outbound → slave-сервер:8444
```

## Режим WG

```
kresd@1 → fake-ip → singbox-tun → WireGuard endpoint → WG-сервер
```

## WARPERSLAVE

| Компонент | Расположение |
|---|---|
| warperslave.sh | /root/warperslave/ |
| slave.conf | /root/warperslave/ |
| config.json | /etc/sing-box-slave/ |
| sing-box-slave.service | /etc/systemd/system/ |

## Шаблоны конфигураций

| Шаблон | Назначение |
|---|---|
| templates/config.json.template | WARPER в режиме WARP |
| templates/config-slave-master.json.template | WARPER в режиме Slave |
| templates/config-wg.json.template | WARPER в режиме WG |
| templates/config-slave-direct.json.template | WARPERSLAVE в режиме Direct |
| templates/config-slave-warp.json.template | WARPERSLAVE в режиме WARP |

## Управление WARP-ключами

Источники ключей проверяются в порядке приоритета:
1. `/etc/wireguard/warp.conf` — системный файл AntiZapret (только с ключом Cloudflare)
2. `/root/warper/wgcf/wgcf-profile.conf` — локальный профиль WARPER
3. `/root/wgcf-profile.conf` — профиль в корне

Файлы WireGuard-соединений (не от Cloudflare) автоматически исключаются из поиска WARP-ключей.

## Патчинг kresd.conf

WARPER вставляет блок `[WARP-MOD-START]...[WARP-MOD-END]` только в секцию `kresd@1`. Блок читает `/etc/knot-resolver/warper-domains.txt` и направляет DNS-запросы для этих доменов на `127.0.0.1:40000` (sing-box DNS-in).
