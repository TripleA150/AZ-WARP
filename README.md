# 🚀 WARPER для AntiZapret VPN

Точечная маршрутизация сервисов вроде **Gemini**, **ChatGPT** и других доменов и IPv4-подсетей (CIDR) через **Cloudflare WARP**, **внешний донор-сервер** или **собственное WireGuard-соединение** на сервере с **AntiZapret VPN**.

Основной проект AntiZapret VPN: https://github.com/GubernievS/AntiZapret-VPN

---

## 📋 Оглавление

1. [О проекте](#about)
2. [Как это работает](#how-it-works)
3. [Режимы работы](#modes)
4. [Системные требования](#requirements)
5. [Установка WARPER](#install-warper)
6. [Установка WARPERSLAVE](#install-warperslave)
7. [Быстрая проверка](#quick-check)
8. [Команды управления](#commands)
9. [Удаление](#uninstall)
10. [FAQ](#faq)
11. [Известные ограничения](#limitations)
12. [Документация](#docs)
13. [Поддержать проект](#support)

---

<a id="about"></a>
## ℹ️ О проекте

### Проблема

У вас настроен сервер с **AntiZapret**. Заблокированные сайты открываются. Но при попытке зайти на **Gemini**, **ChatGPT** или другие сервисы — ошибка:

- сервис недоступен в вашей стране
- IP вашего VPS заблокирован
- сервис режет доступ по GEO

### Решение

WARPER позволяет **точечно направлять только нужные домены + IPv4-подсети (CIDR)** через Cloudflare WARP, внешний донор-сервер или своё WireGuard-соединение, не меняя остальной сценарий работы AntiZapret.

Гибридная схема:

- обычные блокировки → **AntiZapret**
- "проблемные" домены/подсети → **WARP**, **донор-сервер** или **WG-туннель**

---

<a id="how-it-works"></a>
## ⚙️ Как это работает

Когда вы добавляете домен в WARPER:

1. Домен попадает в список маршрутизации
2. `kresd` (только для AntiZapret-клиентов) отдаёт для него **fake-ip** из подсети `198.20.0.0/24`
3. Трафик к fake-ip перехватывает `sing-box`
4. `sing-box` отправляет его в **WARP-туннель**, на **донор-сервер** или через **WG-соединение**
5. Сайт видит IP Cloudflare/донора/WG-сервера, а не IP вашего VPS

### Маршрутизация по IP-подсетям

Помимо доменной маршрутизации, WARPER поддерживает прямую маршрутизацию по IPv4-подсетям (CIDR):

1. Вы добавляете подсеть (например `91.108.4.0/22`) в файл `ip-ranges.txt`
2. WARPER создаёт маршрут в ядре Linux: трафик к этой подсети → `singbox-tun`
3. `sing-box` отправляет его в **WARP**, на **донор-сервер** или через **WG-соединение**
4. При включённом экспорте в AntiZapret — подсеть автоматически попадает в маршруты AntiZapret-клиентов

Это полезно для сервисов, которые невозможно поймать только по доменам (Telegram, игровые серверы и т.д.).

---

<a id="modes"></a>
## 🔀 Режимы работы

### Режим WARP (локальный)

```
Клиент → AntiZapret → kresd → fake-ip → sing-box → Cloudflare WARP → Интернет
```

Трафик идёт через Cloudflare WARP напрямую с вашего сервера.

### Режим Slave (донор-сервер)

```
Сервер 1 (WARPER)                    Сервер 2 (WARPERSLAVE)
Клиент → AntiZapret → kresd →        → sing-box (ss-in) →
  fake-ip → sing-box (ss-out) ──────→   direct / WARP → Интернет
```

Трафик идёт через второй сервер (донор) по зашифрованному Shadowsocks-каналу. На доноре трафик может выходить напрямую (Direct) или через WARP.

**Когда нужен Slave:**
- IP основного сервера заблокирован сервисом
- Нужен выход через конкретную страну/IP
- WARP на основном сервере не работает

### Режим WG (WireGuard)

```
Клиент → AntiZapret → kresd → fake-ip → sing-box → WireGuard-туннель → Интернет
```

Трафик идёт через ваш собственный WireGuard-сервер. Используйте любой `.conf` файл от WG-сервера.

**Когда нужен WG:**
- Есть свой WireGuard VPN-сервер
- Нужен выход через конкретный IP без Cloudflare
- WARP не подходит, донор-сервер не нужен

### Совместимость с VPN_WARP

| Параметр | Поведение |
|---|---|
| `ANTIZAPRET_WARP=n` + `VPN_WARP=n` | WARPER работает для AntiZapret-клиентов |
| `ANTIZAPRET_WARP=n` + `VPN_WARP=y` | ✅ WARPER для AntiZapret, FullVPN через встроенный WARP |
| `ANTIZAPRET_WARP=y` | ❌ Конфликт — WARPER не работает |

### Совместимость ANTIZAPRET_WARP=y/n + VPN_WARP=y/n c IPv4-подсетями (CIDR)

Доступна работа в любом режиме, полная совместимость.

---

<a id="requirements"></a>
## 📦 Системные требования

### WARPER (основной сервер)

| Параметр | Значение |
|---|---|
| **ОС** | Ubuntu 22.04/24.04, Debian 12/13 |
| **Архитектура** | x86_64, aarch64, armv7l |
| **Права** | root |
| **Обязательно** | Установлен **AntiZapret VPN** |

### WARPERSLAVE (донор-сервер)

| Параметр | Значение |
|---|---|
| **ОС** | Ubuntu 20.04+, Debian 10+ |
| **Архитектура** | x86_64, aarch64, armv7l |
| **Права** | root |
| **Обязательно** | Открытый порт (по умолчанию 8444) |

---

<a id="install-warper"></a>
## ⚡ Установка WARPER

На сервере с AntiZapret от имени `root`:

```bash
curl -fsSL https://raw.githubusercontent.com/Liafanx/AZ-WARP/main/install.sh | bash
```

Во время установки выбираете режим маршрутизации:

- **WARP** — локальный Cloudflare WARP (потребуются ключи)
- **Slave** — внешний донор-сервер (потребуется адрес, порт и ключ)
- **WG** — WireGuard-соединение (потребуется `.conf` файл)

После установки:

```bash
warper
```

> После установки клиентам нужно переподключиться по OpenVPN. Если вы используете AWG/WG — обновите конфиг с учётом новой fake-подсети. Аналогично для роутеров, где маршруты прописываются вручную.

---

<a id="install-warperslave"></a>
## 🔧 Установка WARPERSLAVE

На **втором сервере** (донор) от имени `root`:

```bash
curl -fsSL https://raw.githubusercontent.com/Liafanx/AZ-WARP/main/install-slave.sh | bash
```

Установщик спросит:
- **Режим**: Direct (трафик через IP донора) или WARP (через Cloudflare)
- **Порт**: по умолчанию 8444
- **Ключ Shadowsocks**: сгенерировать новый или ввести существующий

После установки будут показаны данные для настройки основного сервера:

```
IP:    <IPv4 донор-сервера>
Порт:  8444
Ключ:  <ключ Shadowsocks>
```

### Подключение WARPER к донору

На основном сервере:

```bash
warper
```

→ `Настройки (9)` → `Режим маршрутизации (7)` → `Slave (2)`

Введите IP, порт и ключ донор-сервера.

### Управление донором

```bash
warperslave          # интерактивное меню
warperslave status   # статус
warperslave switch   # переключить Direct ↔ WARP
warperslave doctor   # диагностика
warperslave update   # обновление
```

---

<a id="quick-check"></a>
## ✅ Быстрая проверка

### WARPER

```bash
warper doctor    # полная диагностика
warper status    # краткий статус
```

### WARPERSLAVE

```bash
warperslave doctor
warperslave status
```

---

<a id="commands"></a>
## 🧰 Команды управления

### WARPER

```bash
warper                      # главное меню
warper add openai.com       # добавить домен
warper remove openai.com    # удалить домен
warper enable gemini        # включить список Gemini
warper enable chatgpt       # включить список ChatGPT
warper disable gemini       # выключить список
warper sync                 # синхронизировать и применить
warper patch                # переприменить патч DNS
warper doctor               # диагностика
warper status               # краткий статус
```

### IP-подсети

```bash
warper ipadd 91.108.4.0/22     # добавить подсеть
warper ipremove 91.108.4.0/22  # удалить подсеть
warper ipsync                   # синхронизировать маршруты
warper iplist                   # показать подсети из файла
warper iproutes                 # показать применённые маршруты
```
Или в главном меню: I → Управление IP-подсетями.

### WARPERSLAVE

```bash
warperslave                 # главное меню
warperslave status          # статус
warperslave switch          # переключить режим
warperslave port            # изменить порт
warperslave key             # изменить ключ
warperslave doctor          # диагностика
warperslave update          # обновление
warperslave uninstall       # удаление
```

---

<a id="uninstall"></a>
## 🗑 Удаление

### WARPER

```bash
warper
# Затем: U
```

Или:

```bash
curl -fsSL https://raw.githubusercontent.com/Liafanx/AZ-WARP/main/uninstaller.sh | bash
```

### WARPERSLAVE

```bash
warperslave
# Затем: U
```

Или:

```bash
curl -fsSL https://raw.githubusercontent.com/Liafanx/AZ-WARP/main/uninstall-slave.sh | bash
```

---

<a id="faq"></a>
## ❓ FAQ

<details>
<summary><b>Что делает WARPER?</b></summary>

WARPER — менеджер доменной маршрутизации. Когда вы добавляете домен, система возвращает для него fake-ip, перенаправляет трафик в sing-box и отправляет его в WARP, на донор-сервер или через WG-туннель. Остальной трафик работает через AntiZapret как обычно.

Примечание: WARPER не работает для типа подключения FullVPN, так как патч kresd не затрагивает `kresd@2`. Этот режим пока в разработке.
</details>

<details>
<summary><b>Можно ли использовать WARPER вместе с VPN_WARP=y?</b></summary>

Да. AntiZapret-клиенты используют WARPER, FullVPN-клиенты — встроенный WARP. WARPER патчит только `kresd@1`, не затрагивая `kresd@2`.
</details>

<details>
<summary><b>Зачем нужен WARPERSLAVE?</b></summary>

Если IP основного сервера заблокирован, или WARP не работает, или нужен выход через конкретную страну — трафик можно направить через второй сервер (донор). На доноре трафик может выходить напрямую или через WARP.
</details>

<details>
<summary><b>Что такое режим WG?</b></summary>

Режим WG позволяет направлять трафик через ваш собственный WireGuard-сервер. Вам нужен `.conf` файл от WG-соединения — установщик и меню warper найдут его автоматически в `/root/` и `/root/warper/`, или вы можете ввести данные вручную.

Важно: файлы Cloudflare WARP (wgcf-profile.conf и warp.conf) автоматически исключаются из списка — они предназначены для режима WARP, а не WG.
</details>

<details>
<summary><b>Можно ли WARPER и WARPERSLAVE на одном сервере?</b></summary>

Да. Они используют разные экземпляры sing-box с разными конфигами и портами, не конфликтуют.
</details>

<details>
<summary><b>Что значит конфликт fake-подсети?</b></summary>

Если fake-подсеть уже используется на локальных интерфейсах (кроме singbox-tun), в маршрутах или Docker-сетях — это может ломать маршрутизацию. WARPER умеет это выявлять и предупреждать.
</details>

<details>
<summary><b>Как переключаться между режимами WARP / Slave / WG?</b></summary>

`warper` → `Настройки (9)` → `Режим маршрутизации (7)`. При переключении обратно на ранее использованный режим предлагается использовать сохранённое подключение или выбрать новое.
</details>

<details>
<summary><b>Как управлять WARP-ключами?</b></summary>

`warper` → `Настройки (9)` → `Управление WARP-ключами (8)` — доступно только в режиме WARP. Можно выбрать источник ключей (системный warp.conf, локальный профиль) или сгенерировать новые.
</details>

<details>
<summary><b>Как изменить MTU / log level?</b></summary>

`warper` → `Настройки (9)` → `Изменить MTU (6)` или `Изменить log level (5)`.
</details>

<details>
<summary><b>Что такое маршрутизация по IP-подсетям?</b></summary>

Помимо доменов, WARPER может направлять трафик к конкретным IPv4-подсетям через sing-box. Вы добавляете подсеть в формате CIDR (например `91.108.4.0/22`), и весь трафик к этим адресам пойдёт через WARP/Slave/WG.

Для AntiZapret-клиентов необходимо, чтобы подсеть также присутствовала в маршрутах AntiZapret. Включите опцию "Экспорт в AntiZapret" (включена по умолчанию) — WARPER автоматически создаст файл `warper-include-ips.txt` и обновит маршруты через `doall.sh`.
</details>

<details>
<summary><b>Какие режимы применения IP-подсетей существуют?</b></summary>

- **Только AntiZapret** (по умолчанию) — маршруты действуют только для AntiZapret-клиентов через policy routing (`ip rule` + отдельная таблица маршрутизации).
- **AntiZapret + FullVPN** — маршруты действуют для обоих типов VPN-клиентов.
- **Весь трафик сервера (Beta)** — маршруты в основной таблице, затрагивают весь трафик.

Переключение: `warper` → `I` → `8`.
</details>

<details>
<summary><b>Почему IP-подсеть не работает для AntiZapret-клиентов?</b></summary>

AntiZapret — это split-tunnel VPN. Клиент отправляет на сервер только те сети, которые входят в маршруты AntiZapret (`result/route-ips.txt`). Если вашей подсети там нет, клиент просто не пошлёт этот трафик на сервер.

Решение: включите "Экспорт в AntiZapret" (`warper` → `I` → `9`). WARPER запишет ваши подсети в `/root/antizapret/config/warper-include-ips.txt`, и после `doall.sh ip` клиенты начнут маршрутизировать эти сети через VPN.

Примечание: после обновления маршрутов клиентам OPENVPN потребуется переподключение, а клиентам AWG/WG, пересборка конфига с учетом новых IPv4-подсетей (CIDR). В роутеры новые маршруты тоже нужно будет добавлять, если это требуется
</details>

---

<a id="limitations"></a>
## ⚠️ Известные ограничения

- Работает только с **IPv4**
- Ожидается стандартная структура AntiZapret в `/root/antizapret`
- **Не работает** при `ANTIZAPRET_WARP=y`
- **Совместим** с `VPN_WARP=y`
- При переключении `VPN_WARP` нужен перезапуск: `down.sh && up.sh` (или reboot сервера)
- Не работает для клиентов FullVPN (kresd@2)
- Используются `iptables`; nft-only конфигурации могут требовать адаптации
- `sing-box` работает в userspace — при высокой нагрузке CPU может быть заметным
- Для режима WG: PresharedKey обязателен — конфиги без него не принимаются
- IP-маршруты не переживают перезагрузку `sing-box` автоматически — WARPER пересинхронизирует их при каждом restart через `resync_ip_routes_if_needed`
- При `RESTRICT_FORWARD=y` WARPER автоматически добавляет CIDR в ipset `antizapret-forward`, но эти записи будут перезаписаны при следующем `doall.sh` — используйте экспорт в AntiZapret для постоянного эффекта
- Режим "Весь трафик сервера" помечен как Beta — поведение зависит от конфигурации `VPN_WARP` и наличия table 13335, в теории туда могут упасть так-же запросы от других сервисов на сервере.(Например telemt, при добавлении CIDR Telegram в warper) 
---

<a id="docs"></a>
## 📚 Документация

Расширенная документация доступна в директории [`docs/`](docs/):

- [Ручная установка WARPER](docs/manual-install.md)
- [Ручная установка WARPERSLAVE](docs/manual-install-slave.md)
- [Архитектура и совместимость с VPN_WARP](docs/architecture.md)
- [Устранение неполадок](docs/troubleshooting.md)

---

<a id="support"></a>
## ⭐ Поддержать проект

Если проект помог вам:

- поставьте ⭐ репозиторию
- расскажите другим пользователям AntiZapret
- создавайте issue и pull request'ы
- поддержать автора: [cloudtips.ru](https://pay.cloudtips.ru/p/b7e90365)
