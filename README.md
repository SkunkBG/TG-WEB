# TGweb

Интерактивная установка **Telegram WEB-прокси** на свой VPS — вместе с сайтом-прикрытием,
который делает домен похожим на обычный веб-проект.

Обёртка над официальным [telegramdesktop/tproxy-server](https://github.com/telegramdesktop/tproxy-server):
скрипт спрашивает домен, email и название проекта, проверяет окружение, собирает сайт,
запускает установщик и печатает готовую ссылку для Telegram.

---

## Что такое WEB-прокси

Новый тип прокси, появившийся в Telegram Desktop 7.1.1 (август 2026) и затем в других клиентах. В отличие от MTProto,
где DPI видит «странный» TCP-поток на нестандартный порт, здесь весь трафик MTProxy
заворачивается в **обычный HTTPS/WebSocket к обычному домену на 443 порт**. Для провайдера это
выглядит как посещение сайта.

Как это работает:

1. Клиент устанавливает MTProxy-соединение по обычным правилам — шифрование не меняется.
2. Готовый зашифрованный поток отдаётся локальному WEB-адаптеру внутри Telegram.
3. Адаптер поднимает **WebView** с bridge-страницей на вашем домене и гонит данные через неё.
4. Свой мультиплекс-протокол (кадры `OPEN` / `DATA` / `WINDOW` / `CLOSE` / `PING`-`PONG` /
   `HELLO`-`WELCOME`) укладывает несколько логических соединений в один веб-канал.
5. На сервере relay распаковывает и отдаёт в локальный MTProxy на `127.0.0.1:2398`.

Сервер **не может** расшифровать ваш трафик — он только транспорт, и не работает как открытый
прокси на произвольные адреса.

---

## Требования

| Что | Подробности |
|---|---|
| Сервер | x86_64, Ubuntu 22.04+ или Debian 12+, публичный IPv4, systemd, root |
| Домен | отдельный субдомен в нижнем регистре, A-запись напрямую на IP сервера |
| Порты | входящие TCP 80 и 443 свободны и открыты |
| Ресурсы | 1 vCPU / 1 GB RAM хватает для личного использования |

> **Cloudflare:** проксирование (оранжевая тучка) должно быть **отключено** — только DNS only.
> Cloudflare терминирует TLS и разорвёт транспорт, плюс Let's Encrypt не сможет выпустить
> сертификат напрямую. Скрипт предупредит, если увидит несовпадение IP.

---

## Пошагово: новый сервер с нуля

Полный путь от купленного VPS до рабочего прокси. Хостер обычно выдаёт root с паролем;
вход по паролю можно оставить — от перебора защищает fail2ban (шаг 4).

**1. DNS.** У регистратора или в Cloudflare создайте A-запись субдомена на IP сервера
(в Cloudflare — серая тучка, DNS only). AAAA не создавайте, если у сервера нет рабочего
IPv6. Проверка с вашего компьютера:

```bash
dig +short A proxy.example.com      # должен вернуть IP сервера
```

**2. Вход по ключу (по желанию).** Удобнее и надёжнее пароля; на своём компьютере, один раз:

```bash
ssh-keygen -t ed25519               # только если ключа ещё нет (~/.ssh/id_ed25519)
ssh-copy-id root@IP_СЕРВЕРА         # спросит пароль от хостера
ssh root@IP_СЕРВЕРА                 # должен войти БЕЗ пароля
```

На Windows (PowerShell) вместо `ssh-copy-id`:

```powershell
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh root@IP_СЕРВЕРА "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"
```

**3. Установка прокси** — на сервере:

```bash
apt-get update && apt-get install -y git
git clone https://github.com/SkunkBG/TG-WEB.git && cd TG-WEB
bash install.sh --hostname proxy.example.com --email admin@example.com --project "My Project" --yes
```

Email — только контакт для Let's Encrypt, писем об истечении сертификатов он больше не
шлёт; подойдёт адрес на вашем же домене, ящик не нужен. В конце скрипт напечатает ссылку —
проверьте её в Telegram.

**4. Подготовка и защита сервера** — одной командой (подробно — в разделе
[Защита и настройка сервера](#защита-и-настройка-сервера)):

```bash
bash harden.sh -y --auto-reboot 04:00
```

Обновит систему, включит ufw (наружу только SSH, 80, 443), fail2ban, BBR и сетевой
тюнинг по объёму RAM, отключит IPv6, создаст своп и включит автообновления. Можно
запускать и до установки прокси, и после.

**5. Только ключи (по желанию).** Если на шаге 2 настроили ключ и хотите запретить вход
по паролю — запустите ещё раз с `--harden-ssh`. Скрипт сделает это, только если ключи
уже лежат в `authorized_keys`, и проверит итог через `sshd -T`. Сессию не закрывайте,
пока не проверите вход по ключу в новом окне. Вернуть пароль:
`rm /etc/ssh/sshd_config.d/000-tgweb-hardening.conf && systemctl reload ssh`.

**6. Резервная копия.** Сохраните к себе каталоги с секретами — без них при переезде
поменяются ссылки у всех пользователей:

```bash
ssh root@IP_СЕРВЕРА 'tar czf - /etc/tgweb /etc/tproxy-server' > tgweb-backup.tar.gz
```

Храните архив как пароль: в нём секреты прокси.

---

## Установка

На минимальных образах Debian/Ubuntu `git` не предустановлен — поставьте его первым:

```bash
apt-get update && apt-get install -y git
git clone https://github.com/SkunkBG/TG-WEB.git
cd TG-WEB
sudo bash install.sh
```

Без git — архивом:

```bash
apt-get update && apt-get install -y curl unzip
curl -fsSL -o tgweb.zip https://github.com/SkunkBG/TG-WEB/archive/refs/heads/main.zip
unzip -q tgweb.zip && cd TG-WEB-main
bash install.sh
```

Скрипт задаст четыре вопроса:

```
Домен прокси (A-запись должна вести на этот сервер):
> proxy.example.com

Email для Let's Encrypt:
> you@example.com

Название проекта для сайта-прикрытия:
[Proxy] > Soul

Продолжить? [y/N] > y
```

Секрет генерируется автоматически (`openssl rand -hex 16`) и сохраняется в
`/etc/tgweb/secret` с правами 400. При повторном запуске он переиспользуется — ссылка
на прокси не меняется.

### Неинтерактивно

```bash
sudo bash install.sh \
  --hostname proxy.example.com \
  --email you@example.com \
  --project Soul \
  --yes
```

Все опции:

| Опция | Назначение |
|---|---|
| `--hostname FQDN` | домен прокси |
| `--email ADDR` | контакт для Let's Encrypt |
| `--project NAME` | название проекта на сайте-прикрытии |
| `--secret HEX` | свой секрет, 32 hex-символа (по умолчанию случайный) |
| `--workers N` | воркеров MTProxy (по умолчанию по числу ядер, максимум 4) |
| `--base-path SLUG` | путь relay на домене, например `my-app` или `a/b`; `none` — корень хоста. По умолчанию новая установка получает случайный путь, переустановка сохраняет прежний |
| `--upstream-ref REF` | коммит или ветка `tproxy-server`. По умолчанию — проверенный коммит, зашитый в `install.sh` |
| `--skip-dns-check` | не сверять A- и AAAA-записи |
| `-y`, `--yes` | без подтверждений |

### Проверить сборку сайта, ничего не устанавливая

```bash
TGWEB_DRY_RUN=1 bash install.sh --hostname test.example.com --email admin@example.com --project Demo --yes
```

Соберёт сайт в `/tmp/tgweb-site-dryrun` и выйдет. root для этого не нужен. Можно посмотреть глазами:
`cd /tmp/tgweb-site-dryrun && python3 -m http.server 8000`.

---

## Подключение в Telegram

С сентября 2026 апстрим по умолчанию прячет relay под **base path** — случайный путь
на домене. Тогда адрес сервера включает путь, а secret в ссылке выглядит иначе, чем hex.
После установки скрипт печатает:

```
Server : proxy.example.com/phcf2vfe7zgbrslg
Secret : 8561944064fc730cbfa4473562d8ec59

https://t.me/webproxy?server=proxy.example.com%2Fphcf2vfe7zgbrslg&secret=cIVhlEBk_HMMv6RHNWLY7Fk
```

- **Вручную:** в настройках Telegram выберите тип прокси **WEB**, в поле server введите
  домен вместе с путём, в поле secret — hex. Без `https://` и без порта: HTTPS и 443 у
  этого типа зафиксированы.
- **Ссылкой:** под base path secret в ссылке закодирован (`base64url(0x70 ‖ secret)`) —
  так задумано апстримом, чтобы старый клиент не принял ссылку за прокси без пути.
  Не подставляйте в ссылку hex-секрет руками.
- **Без пути** (`--base-path none`, и все установки TGweb 1.0): server — просто домен,
  в ссылке тот же hex.

Ссылку и реквизиты можно посмотреть позже:

```bash
sudo bash status.sh
```

**Клиенты.** Нужен клиент Telegram с поддержкой WEB-прокси. Адрес с путём понимают
только клиенты с поддержкой base path; старый клиент сообщит о неподдерживаемом типе
прокси и попросит обновиться. Если кому-то из ваших пользователей обновиться нельзя —
ставьте с `--base-path none`. Если `t.me/webproxy` не открывается — введите значения
руками.

---

## Сайт-прикрытие

В `site/` лежит шаблон: лендинг, API-документация, changelog, статус, privacy, 404.
Легенда — небольшой self-hosted видео-пайплайн (ingest → transcode → HLS delivery).

Почему именно такая:

- **Объясняет трафик.** Отдача видео-сегментов делает естественными и большой объём,
  и долгие соединения, и рваные чанки — то самое, что генерирует WEB-прокси.
- **Личный проект не обязан иметь посетителей.** «Сервис» без живых пользователей выглядит
  странно, хобби-проект с одним пользователем — нормально.
- **Ничего лишнего.** Нет форм входа, нет платежей, нет чужого брендинга.
- **Полностью автономна.** Ни CDN, ни внешних шрифтов, ни аналитики — системные шрифты и
  один локальный CSS. Нечему утекать и нечему отваливаться.

Установщик подставляет в шаблоны домен, название проекта, а также **случайные** акцентный
цвет, build-id, идентификаторы примеров и вариант заголовка — чтобы страницы у разных
пользователей этого репозитория не были байт-в-байт одинаковыми.

### Обязательно перепишите тексты

Авторы `tproxy-server` пишут прямо:

> The repository deliberately does not include a deployable public website. If many operators
> installed the same starter, its body and assets would become an easy active-probing signature.

Случайных мелочей мало. Отредактируйте `site/*.html` под себя — заголовки, названия
эндпоинтов, «known issues», добавьте пару своих страниц — и запустите `install.sh` заново.
Скрипт сам обновит рабочую копию `/srv/tproxy-site` (апстрим при переустановке её не трогает),
прежнюю версию сохранит в `/srv/tproxy-site.bak.<дата>` и перезапустит relay, только если
сайт действительно изменился.

Случайные значения (цвет, вариант заголовка, build-id) запоминаются в
`/etc/tgweb/site.env`, поэтому переустановка не меняет внешний вид живого сайта.
Нужен новый набор — удалите этот файл и запустите `install.sh` снова.
Чем меньше сайт похож на шаблон из репозитория, тем лучше.

Доступные подстановки в шаблонах:

| Заглушка | Значение |
|---|---|
| `__HOST__` | домен |
| `__PROJECT__` / `__PROJECT_LC__` | название проекта / в нижнем регистре |
| `__ACCENT__` | случайный акцентный цвет |
| `__H1__` / `__LEAD__` / `__WHY__` | случайный вариант текста |
| `__BUILD__` | случайный build-id |
| `__ASSET1__` / `__ASSET2__` / `__DURATION__` | случайные значения в примерах |
| `__YEAR__` | текущий год |

Единственный обязательный файл — `index.html`.

---

## Что и куда ставится

Наружу слушает **только Caddy**. Relay, MTProxy и админка — на loopback.

```
Telegram → WEB-адаптер → WebView → Caddy :443 → relay → MTProxy 127.0.0.1:2398
```

| Путь | Что |
|---|---|
| `/opt/tproxy-src` | исходники tproxy-server |
| `/opt/tgweb-site` | собранный сайт (источник для установщика) |
| `/srv/tproxy-site` | рабочая копия сайта |
| `/etc/tproxy-server/config.json` | конфиг relay |
| `/etc/tproxy-server/profiles.json` | профили и секреты, chmod 400 |
| `/etc/mtproxy/mtproxy.env` | окружение MTProxy |
| `/etc/caddy/Caddyfile*` | конфиг Caddy |
| `/etc/tgweb/secret` | секрет, chmod 400 |
| `/etc/tgweb/info.txt` | реквизиты подключения, chmod 600 |
| `/etc/tgweb/site.env` | выбранное оформление сайта, chmod 600 |
| `/etc/tproxy-server/token.key` | ключ подписи токенов relay, chmod 400 — сохраняйте в бэкапе |

Сервисы: `caddy`, `tproxy-server`, `mtproxy`, `tproxy-firewall`, `refresh-mtproxy-config`.

---

## Эксплуатация

```bash
sudo bash status.sh                       # сервисы, health, метрики, ссылка
sudo bash harden.sh                       # файрвол, fail2ban, тюнинг
systemctl status tproxy-server caddy mtproxy
journalctl -u tproxy-server -f
curl -s http://127.0.0.1:8081/metrics     # только с самого сервера

```

### Обновление

```bash
cd TG-WEB && git pull
sudo bash install.sh        # те же ответы; домен, секрет и путь сохранятся
```

`install.sh` берёт зафиксированный проверенный коммит `tproxy-server`, пересобирает relay,
обновляет Caddy и юниты, сохраняет секрет и base path — ссылки у пользователей не меняются.
`deploy/update-relay.sh` апстрима обновляет только бинарник relay, без Caddy и юнитов.

**Установки TGweb 1.0** работают без пути и без `token.key`. При первом обновлении
скрипт, как и `update-relay.sh`, включает временный drain старых токенов и напомнит его
выключить, когда клиенты переподключатся:

```bash
sudo rm /etc/systemd/system/tproxy-server.service.d/token-migration.conf
sudo systemctl daemon-reload && sudo systemctl restart tproxy-server
```

Путь при этом не появляется. Перейти на base path можно переустановкой с
`--base-path <slug>`, но старые ссылки перестанут работать — раздайте новые.

Loopback-эндпоинты: `/healthz` (живость), `/readyz` (готовность вместе с бэкендом),
`/metrics` (счётчики) на `127.0.0.1:8081`.

### Несколько пользователей

Каждому — свой секрет отдельным профилем в `/etc/tproxy-server/profiles.json`:

```json
{
  "profiles": [
    { "name": "alpha", "secret": "0123456789abcdef0123456789abcdef",
      "backend": "127.0.0.1:2398", "carrier_mode": "https" }
  ]
}
```

`carrier_mode`: `https`, `https-lanes`, `websocket`, `websocket-lanes`. Файл должен быть 0400.
После правки — `systemctl restart tproxy-server`.

### Удаление

```bash
sudo bash uninstall.sh
```

---

## Защита и настройка сервера

`harden.sh` готовит сервер одной командой — как базовый скрипт для VPN-нод, но под
этот прокси: наружу открыты только SSH, 80 и 443.

```bash
sudo bash harden.sh -y --auto-reboot 04:00   # всё, вход по паролю остаётся
sudo bash harden.sh -y --harden-ssh          # + вход только по ключу
# без клонирования репозитория:
curl -fsSL https://raw.githubusercontent.com/SkunkBG/TG-WEB/main/harden.sh | bash -s -- -y
```

Без `-y` скрипт спрашивает подтверждение перед каждым блоком. Проверено на Debian 13
(trixie), включая перезагрузку: всё поднимается само. Рассчитан на Debian 12+ и Ubuntu 22.04+.

| Флаг | Что делает |
|---|---|
| `-y` | без вопросов |
| `--harden-ssh` | вход только по ключу (если ключи есть) |
| `--auto-reboot ЧЧ:ММ` | перезагрузка после автообновления ядра в это время (время сервера, обычно UTC) |
| `--allow-port P` | открыть ещё порт, например `8443/tcp`; можно несколько раз |
| `--keep-ipv6` | не отключать IPv6 |
| `--reset-firewall` | сбросить все существующие правила ufw |
| `--skip-upgrade`, `--skip-firewall`, `--skip-fail2ban`, `--skip-tuning`, `--skip-extras` | пропустить блок |

### 1. Пакеты, своп, журнал, время

`apt upgrade` (конфиги не перезаписываются, `--force-confold`), затем ufw, fail2ban,
chrony, conntrack. Если плановый `apt-daily` держит блокировку dpkg, скрипт ждёт до
5 минут, а не падает. Своп: 2 ГБ при RAM меньше 2 ГБ, иначе 1 ГБ — и только если на `/`
остаётся запас 3 ГБ. journald ограничен 200 МБ и неделей.

### 2. Файрвол (ufw)

Входящие запрещены, исходящие разрешены, открыты SSH (`ufw limit`), 80 и 443.
**Существующие правила сохраняются** — скрипт их показывает и только добавляет свои;
начать с чистого листа — `--reset-firewall`.

Порт SSH определяется через `sshd -T` (учитывает `Include` и `Match`) и дополнительно
берётся из `SSH_CONNECTION` текущей сессии, после применения проверяется в
`ufw status` — чтобы не запереть себя снаружи. Таблица nftables `tproxy_backend`
(закрывает MTProxy 2398/8888) с ufw не конфликтует.

### 3. fail2ban

Jail `sshd` с `backend = systemd`: на Debian 12/13 и свежих Ubuntu файла
`/var/log/auth.log` нет, и штатный файловый backend молча не стартует. Скрипт проверяет
импорт `python3-systemd` и при проблеме переходит на файловый backend с явным путём.
Бан через ufw на 1 час, повторные — вдвое дольше, до недели; ваш текущий IP — в
`ignoreip`. Прежний `jail.local` сохраняется как `.bak.<дата>`.

```bash
fail2ban-client status sshd
fail2ban-client set sshd unbanip 203.0.113.10
```

### 4. Сеть

`/etc/sysctl.d/99-tgweb.conf`, буферы и очереди — по объёму RAM:

| Параметр | Зачем |
|---|---|
| `bbr` + `fq` | если ядро умеет BBR (проверяется) |
| `somaxconn`, `netdev_max_backlog`, `tcp_max_syn_backlog`, `rmem/wmem` | очереди и буферы: до 1.5 ГБ RAM — 16k/8 МБ, до 3 ГБ — 32k/8 МБ, больше — 64k/16 МБ |
| `tcp_slow_start_after_idle=0`, keepalive, `tcp_fin_timeout`, `tcp_tw_reuse`, `ip_local_port_range` | долгие HTTPS-сессии и исходящие к Telegram |
| `tcp_fastopen=1` | только исходящий TFO: серверный отличал бы нас от обычного веб-сервера |
| `tcp_mtu_probing=1`, `tcp_base_mss`, `tcp_mtu_probe_floor` | страховка от ICMP black hole у операторов |
| `tcp_min_snd_mss=536` | CVE-2019-11479 |
| `nf_conntrack_max` + hashsize | conntrack использует ufw: 64k/128k/256k по RAM |
| `fs.file-max` | пишется, только если сейчас меньше 1048576 — на современных ядрах он выше, и запись бы его понизила |
| `disable_ipv6` | IPv6 отключён; если у сервера есть IPv6 — уберите AAAA-записи, или `--keep-ipv6` |

Плюс лимит дескрипторов 1048576 (`limits.d` и `DefaultLimitNOFILE`). Если ядро не
принимает часть значений (контейнеры, OpenVZ), скрипт показывает, какие именно.

### 5. Автообновления

`unattended-upgrades` ставит обновления безопасности каждый день. **Исправления ядра
действуют только после перезагрузки**, поэтому есть `--auto-reboot 04:00`: сервер
перезагрузится сам, и только когда новое ядро действительно установлено (прокси
поднимается автоматически, клиенты переподключаются). Без флага перезагружайте вручную.

В итоге скрипт сравнивает работающее ядро с новейшим установленным и пишет
«НУЖНА ПЕРЕЗАГРУЗКА», если они различаются — например, сразу после `apt upgrade`.

### 6. SSH: только ключи (`--harden-ssh`)

По умолчанию вход по паролю **не трогается**. С флагом скрипт пишет
`/etc/ssh/sshd_config.d/000-tgweb-hardening.conf` (`PasswordAuthentication no`,
`PermitRootLogin prohibit-password`, `MaxAuthTries 3`) — только если в `authorized_keys`
есть ключи. Имя `000-…` важно: в sshd побеждает первое значение, а у хостеров бывает
`00password.conf` с `PasswordAuthentication yes`, который перебил бы файл `99-…`.
Результат проверяется через `sshd -T`; при ошибке `sshd -t` изменения откатываются.

---

## Известные проблемы апстрима

Оба бага `umask 077`, которые TGweb 1.0 обходил патчами (`go test` падал на
`TestLoadAcceptsSystemdCredentialReadPermissions`, а `mtproxy.service` уходил в
`status=203/EXEC`), **исправлены в апстриме 2026-09-29** (`51215a2`, `c8adb8b`).
TGweb 1.1 больше не правит файлы апстрима, а переменная `TGWEB_SKIP_UPSTREAM_TESTS`
удалена.

Если `mtproxy` на старой установке всё ещё в рестарт-лупе — просто обновитесь
(`sudo bash install.sh`): апстримовый `install-mtproxy.sh` теперь сам нормализует права
`/opt/MTProxy` при каждом запуске.

---

## Диагностика

| Симптом | Куда смотреть |
|---|---|
| Сертификат не выпускается | A-запись ведёт напрямую на сервер? Cloudflare в DNS only? 80 и 443 доходят до Caddy? `journalctl -u caddy -n 60` |
| `/readyz` отдаёт 503 | `systemctl status mtproxy`, `ss -lntp \| grep 2398` |
| В WebView открывается публичный сайт | server (с путём!) и secret в клиенте не совпадают с сервером; сверьте с `sudo bash status.sh` |
| Клиент пишет «неподдерживаемый тип прокси» | клиент не знает base path — обновите его или переустановите с `--base-path none` |
| Сертификат не выпускается, A-запись верная | есть AAAA-запись на другой адрес — Let's Encrypt идёт по IPv6 |
| Порт 80 или 443 занят | остановите свой веб-сервер: `systemctl disable --now nginx` |
| Permission denied на профилях | `chmod 400 /etc/tproxy-server/profiles.json` |
| Забанил себя в fail2ban | С другого IP: `fail2ban-client set sshd unbanip <ваш IP>`, либо через консоль хостера |
| Jail sshd не стартует | `python3 -c 'from systemd import journal'` — если падает, `apt-get install --reinstall python3-systemd` |

---

## Безопасность

- **Секрет в списке процессов.** `install.sh` передаёт `--secret` флагом, чтобы установка
  прошла без лишних вопросов. Upstream предупреждает, что это «places the value in the invoking
  process list». На одиночном VPS это приемлемо; если нужно строже — уберите строку
  `--secret "$SECRET"` из вызова, и установщик спросит секрет интерактивно без эха.
- **Чужим WEB-прокси доверять не стоит.** Telegram Desktop 7.1.2 показывает предупреждение:
  *«this web proxy runs a web page from its provider in the background while you're connected»*.
  Владелец прокси крутит у вас в фоне свой код. Свой сервер решает эту проблему.
- **Bridge-страница сильно ограничена** самим Telegram: запрещены cookies, localStorage,
  IndexedDB, Service Workers, камера/микрофон и внешние ресурсы; разрешены только inline-скрипты
  и соединения к своему же домену.
- **Не выносите сайт из-под relay.** Relay должен остаться единственным публичным входом на
  этом домене, иначе заголовки и тайминги выдадут отдельную транспортную поверхность.

---

## Статус

`tproxy-server` — proof-of-concept от авторов Telegram Desktop. Протокол и раскладка на диске
могут меняться. Этот репозиторий — обёртка вокруг него, а не форк: сам relay всегда берётся
свежим из upstream при установке.

## Ссылки

- [telegramdesktop/tproxy-server](https://github.com/telegramdesktop/tproxy-server) — официальный сервер
- [Telegram Desktop 7.1.1 — появился WEB-прокси](https://habr.com/ru/news/1073330/)
- [Telegram Desktop 7.1.2 — доработки](https://habr.com/ru/news/1074112/)
- [Технические подробности WEB-прокси](https://kod.ru/telegram-web-proxy-tproxy-server-podrobnosti)

## Лицензия

MIT — см. [LICENSE](LICENSE).
