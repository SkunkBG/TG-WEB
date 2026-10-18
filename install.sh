#!/usr/bin/env bash
#
# TGweb — интерактивная установка Telegram WEB-прокси (tproxy-server)
#         вместе с сайтом-прикрытием.
#
#   sudo bash install.sh
#
# Неинтерактивно:
#   sudo bash install.sh --hostname proxy.example.com --email you@example.com \
#                        --project Soul --yes
#
set -euo pipefail

VERSION="1.1.0"
UPSTREAM_REPO="https://github.com/telegramdesktop/tproxy-server.git"
# Проверенный коммит апстрима. Апстрим меняет поведение по умолчанию
# (например, base path с 2026-09-10), поэтому HEAD не берётся вслепую.
# Другая версия: --upstream-ref <commit|branch>.
UPSTREAM_REF="c8adb8b7c6b7fc46c12ae3acb68be9070c26a8e8"
SRC_DIR="/opt/tproxy-src"
BUILD_DIR="/opt/tgweb-site"
SITE_LIVE="/srv/tproxy-site"
STATE_DIR="/etc/tgweb"
SECRET_FILE="$STATE_DIR/secret"
INFO_FILE="$STATE_DIR/info.txt"
SITE_ENV_FILE="$STATE_DIR/site.env"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_SRC="$SCRIPT_DIR/site"
DRY_RUN="${TGWEB_DRY_RUN:-0}"

# shellcheck source=lib/webproxy.sh
. "$SCRIPT_DIR/lib/webproxy.sh" 2>/dev/null || {
  echo "Не найден lib/webproxy.sh рядом со скриптом. Запускайте из корня репозитория." >&2
  exit 1
}

# ─────────────────────────────── оформление ───────────────────────────────
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  RED=$'\033[31m'; CYAN=$'\033[36m'; OFF=$'\033[0m'
else
  BOLD=''; DIM=''; GREEN=''; YELLOW=''; RED=''; CYAN=''; OFF=''
fi
step() { printf '\n%s==> %s%s\n' "$BOLD" "$1" "$OFF"; }
ok()   { printf '  %sok%s   %s\n' "$GREEN" "$OFF" "$1"; }
warn() { printf '  %s!!%s   %s\n' "$YELLOW" "$OFF" "$1"; }
info() { printf '  %s·%s    %s\n' "$DIM" "$OFF" "$1"; }
die()  { printf '\n  %sошибка:%s %s\n\n' "$RED" "$OFF" "$1" >&2; exit 1; }

# ──────────────────────────── разбор аргументов ───────────────────────────
FQDN=""; EMAIL=""; PROJECT=""; SECRET=""; WORKERS=""; ASSUME_YES=0; SKIP_DNS=0
BASE_PATH=""

usage() {
  cat <<EOF
TGweb $VERSION — установка Telegram WEB-прокси с сайтом-прикрытием.

  sudo bash install.sh [опции]

Опции (всё, что не указано, будет спрошено интерактивно):
  --hostname FQDN      домен прокси, например proxy.example.com
  --email ADDR         email для Let's Encrypt
  --project NAME       название проекта для сайта-прикрытия
  --secret HEX         32 hex-символа (по умолчанию генерируется случайный)
  --workers N          воркеров MTProxy (по умолчанию по числу ядер, максимум 4)
  --base-path SLUG     путь relay на домене; none — корень хоста. По умолчанию:
                       новая установка — случайный путь, переустановка — прежний
  --upstream-ref REF   коммит или ветка tproxy-server (по умолчанию проверенный
                       ${UPSTREAM_REF:0:7})
  --skip-dns-check     не сверять A/AAAA-записи с внешним IP
  -y, --yes            не спрашивать подтверждение
  -h, --help           эта справка
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname) FQDN="${2:-}"; shift 2 ;;
    --email) EMAIL="${2:-}"; shift 2 ;;
    --project) PROJECT="${2:-}"; shift 2 ;;
    --secret) SECRET="${2:-}"; shift 2 ;;
    --workers) WORKERS="${2:-}"; shift 2 ;;
    --base-path) BASE_PATH="${2:-}"; [[ -n "$BASE_PATH" ]] || die "--base-path требует значение"; shift 2 ;;
    --upstream-ref) UPSTREAM_REF="${2:-}"; [[ -n "$UPSTREAM_REF" ]] || die "--upstream-ref требует значение"; shift 2 ;;
    --skip-dns-check) SKIP_DNS=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Неизвестный аргумент: $1 (см. --help)" ;;
  esac
done

printf '\n%s  TGweb %s%s  %sTelegram WEB-прокси + сайт-прикрытие%s\n' \
  "$BOLD" "$VERSION" "$OFF" "$DIM" "$OFF"

# ──────────────────────────── проверки системы ────────────────────────────
step "Проверка системы"
[[ $EUID -eq 0 || "$DRY_RUN" == "1" ]] || die "Нужны права root. Запустите: sudo bash install.sh"
[[ -d "$SITE_SRC" ]] || die "Не найден каталог site/ рядом со скриптом.
     Запускайте install.sh из корня клонированного репозитория."
[[ -f "$SITE_SRC/index.html" ]] || die "В site/ нет index.html — это обязательный файл."

if [[ "$DRY_RUN" != "1" ]]; then
  [[ "$(uname -m)" == "x86_64" ]] || die "tproxy-server собирается только под x86_64, здесь $(uname -m)."
  command -v systemctl >/dev/null || die "Нет systemd."
  if [[ -r /etc/os-release ]]; then
    # os-release читается в подоболочке: его VERSION иначе затирает версию TGweb
    # shellcheck disable=SC1091
    IFS='|' read -r OS_ID OS_VERSION_ID OS_NAME \
      < <(. /etc/os-release; printf '%s|%s|%s\n' "${ID:-}" "${VERSION_ID:-}" "${PRETTY_NAME:-}")
    case "${OS_ID}:${OS_VERSION_ID%%.*}" in
      ubuntu:2[2-9]|ubuntu:[3-9][0-9]|debian:1[2-9]|debian:[2-9][0-9])
        ok "ОС: ${OS_NAME:-$OS_ID}" ;;
      *) warn "ОС ${OS_NAME:-неизвестна} вне протестированного списка (Ubuntu 22.04+, Debian 12+)." ;;
    esac
  fi
  ok "CPU: $(nproc) ядер, RAM: $(awk '/MemTotal/{printf "%d МБ", $2/1024}' /proc/meminfo)"
else
  warn "DRY RUN: системные проверки и установка пропущены"
fi

# ───────────────────────── интерактивный опросник ─────────────────────────
interactive=0
[[ -t 0 ]] && interactive=1

need_input=0
[[ -z "$FQDN" || -z "$EMAIL" ]] && need_input=1
if [[ $need_input -eq 1 && $interactive -eq 0 ]]; then
  die "Нет терминала для вопросов. Передайте параметры флагами:
     sudo bash install.sh --hostname proxy.example.com --email you@example.com --yes"
fi

# prompt_value ИМЯ_ПЕРЕМЕННОЙ "вопрос" "значение_по_умолчанию" "регексп" "текст_ошибки"
prompt_value() {
  local var="$1" question="$2" default="${3:-}" re="${4:-.}" errmsg="${5:-Неверное значение}"
  local current="${!var}" input=""
  if [[ -n "$current" ]]; then
    [[ "$current" =~ $re ]] || die "$errmsg (получено: $current)"
    return 0
  fi
  while true; do
    if [[ -n "$default" ]]; then
      printf '  %s\n  %s[%s]%s > ' "$question" "$DIM" "$default" "$OFF"
    else
      printf '  %s\n  > ' "$question"
    fi
    IFS= read -r input || die "Ввод прерван."
    [[ -z "$input" && -n "$default" ]] && input="$default"
    if [[ "$input" =~ $re ]]; then
      printf -v "$var" '%s' "$input"
      printf '\n'
      return 0
    fi
    printf '  %s%s%s\n\n' "$RED" "$errmsg" "$OFF"
  done
}

step "Параметры установки"

prompt_value FQDN \
  "Домен прокси (A-запись должна вести на этот сервер, без https:// и без порта):" \
  "" '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' \
  "Нужен домен в нижнем регистре минимум с одной точкой, например proxy.example.com"

# Тот же регексп, что в deploy/install.sh апстрима: иначе адрес с кириллицей
# (например, «л» от русской раскладки) проходит здесь и падает уже там.
prompt_value EMAIL \
  "Email для Let's Encrypt (на него придут уведомления об истечении сертификата):" \
  "" '^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' \
  "Нужен email латиницей, например admin@example.com — проверьте раскладку"

default_project="$(printf '%s' "${FQDN%%.*}" | sed 's/^./\U&/')"
prompt_value PROJECT \
  "Название проекта для сайта-прикрытия (то, что увидит посетитель домена):" \
  "$default_project" '^[[:print:]]{2,40}$' \
  "От 2 до 40 печатных символов"

# секрет
if [[ -n "$SECRET" ]]; then
  [[ "$SECRET" =~ ^(dd)?[0-9a-f]{32}$ ]] || die "Секрет — 32 hex-символа в нижнем регистре (можно с префиксом dd)."
  info "Секрет взят из --secret"
elif [[ -s "$SECRET_FILE" ]]; then
  SECRET="$(tr -d '[:space:]' < "$SECRET_FILE")"
  info "Найден сохранённый секрет в $SECRET_FILE — переиспользую (ссылка не изменится)"
else
  SECRET="$(openssl rand -hex 16 2>/dev/null || head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  info "Сгенерирован новый случайный секрет"
fi

# воркеры
if [[ -z "$WORKERS" ]]; then
  cores="$(nproc 2>/dev/null || echo 1)"
  WORKERS=$(( cores > 4 ? 4 : cores ))
fi
[[ "$WORKERS" =~ ^[0-9]+$ ]] && (( WORKERS >= 1 && WORKERS <= 256 )) \
  || die "--workers должно быть числом от 1 до 256."

# base path: те же правила, что в deploy/install.sh апстрима
if [[ -n "$BASE_PATH" && "$BASE_PATH" != "none" ]]; then
  [[ "$BASE_PATH" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*(/[A-Za-z0-9][A-Za-z0-9_-]*)*$ ]] \
    || die "--base-path: сегменты [A-Za-z0-9][A-Za-z0-9_-]*, через /, без / в начале и конце."
  (( ${#BASE_PATH} <= 128 )) || die "--base-path: не длиннее 128 символов."
fi
[[ "$UPSTREAM_REF" =~ ^[A-Za-z0-9._/-]+$ ]] || die "--upstream-ref: недопустимые символы."

# ──────────────────────────── подтверждение ──────────────────────────────
step "Проверьте параметры"
printf '  домен          : %s%s%s\n' "$CYAN" "$FQDN" "$OFF"
printf '  email (ACME)   : %s\n' "$EMAIL"
printf '  проект на сайте: %s\n' "$PROJECT"
printf '  секрет         : %s\n' "$SECRET"
printf '  MTProxy воркеры: %s\n' "$WORKERS"
printf '  base path      : %s\n' "${BASE_PATH:-по умолчанию апстрима (новая установка — случайный, переустановка — прежний)}"
printf '  tproxy-server  : %s\n' "$UPSTREAM_REF"
printf '\n  Будет установлено: Caddy (TLS), tproxy-server (relay), MTProxy.\n'
printf '  Наружу слушает только Caddy на портах 80 и 443.\n'

if [[ $ASSUME_YES -eq 0 ]]; then
  [[ $interactive -eq 1 ]] || die "Нет терминала для подтверждения — добавьте --yes."
  printf '\n  Продолжить? [y/N] > '
  IFS= read -r answer || true
  case "${answer:-}" in
    [yYдД]|[yY]es|да) : ;;
    *) printf '\n  Отменено.\n\n'; exit 0 ;;
  esac
fi

# ─────────────────────────────── зависимости ──────────────────────────────
if [[ "$DRY_RUN" != "1" ]]; then
  step "Установка зависимостей"
  export DEBIAN_FRONTEND=noninteractive
  # плановый apt-daily на свежем сервере держит блокировку dpkg — ждём, а не падаем
  apt-get -o DPkg::Lock::Timeout=300 update -qq
  apt-get -o DPkg::Lock::Timeout=300 install -y -qq git curl ca-certificates openssl dnsutils iproute2 python3 >/dev/null
  ok "git, curl, openssl, dig, ss, python3"
fi

# ────────────────────────────── проверка DNS ──────────────────────────────
if [[ "$DRY_RUN" != "1" ]]; then
  step "Проверка A-записи"
  if [[ $SKIP_DNS -eq 1 ]]; then
    warn "Проверка пропущена (--skip-dns-check)"
  else
    myip="$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || echo '')"
    resolved="$(dig +short A "$FQDN" @1.1.1.1 2>/dev/null | tail -n1 || true)"
    if [[ -z "$resolved" ]]; then
      die "A-запись для $FQDN не найдена.
     Создайте у DNS-провайдера запись A на IP этого сервера${myip:+ ($myip)},
     дождитесь распространения и запустите скрипт снова.
     Обойти проверку: --skip-dns-check"
    fi
    ok "$FQDN -> $resolved"
    if [[ -n "$myip" && "$resolved" != "$myip" ]]; then
      warn "Внешний IP сервера $myip не совпадает с A-записью $resolved."
      warn "Если домен за Cloudflare — ОТКЛЮЧИТЕ проксирование (серая тучка, DNS only):"
      warn "через оранжевую тучку WEB-прокси не работает, Cloudflare терминирует TLS."
      if [[ $ASSUME_YES -eq 0 && $interactive -eq 1 ]]; then
        printf '\n  Всё равно продолжить? [y/N] > '
        IFS= read -r a2 || true
        case "${a2:-}" in [yYдД]|[yY]es|да) : ;; *) die "Остановлено на проверке DNS." ;; esac
      fi
    fi

    # Let's Encrypt предпочитает IPv6: AAAA-запись не на этот сервер ломает
    # выпуск сертификата, а клиенты с IPv6 уйдут мимо прокси.
    resolved6="$(dig +short AAAA "$FQDN" @1.1.1.1 2>/dev/null | grep ':' | tail -n1 || true)"
    if [[ -n "$resolved6" ]]; then
      myip6="$(curl -6 -fsS --max-time 8 https://api64.ipify.org 2>/dev/null || echo '')"
      if [[ "$resolved6" == "$myip6" ]]; then
        ok "$FQDN -> $resolved6 (AAAA совпадает с IPv6 сервера)"
      else
        warn "У $FQDN есть AAAA-запись $resolved6, но IPv6 сервера ${myip6:-не определён}."
        warn "Удалите AAAA или направьте её на этот сервер — иначе ACME и клиенты с IPv6"
        warn "пойдут на другой адрес."
        if [[ $ASSUME_YES -eq 0 && $interactive -eq 1 ]]; then
          printf '\n  Всё равно продолжить? [y/N] > '
          IFS= read -r a3 || true
          case "${a3:-}" in [yYдД]|[yY]es|да) : ;; *) die "Остановлено на проверке AAAA." ;; esac
        fi
      fi
    fi
  fi

  step "Проверка портов 80 и 443"
  for p in 80 443; do
    if ss -lnt "sport = :$p" 2>/dev/null | grep LISTEN >/dev/null; then
      holder="$(ss -lntp "sport = :$p" 2>/dev/null | awk 'NR==2{print $NF}')"
      die "Порт $p занят: ${holder:-неизвестно}
     Наружу должен слушать только Caddy. Например: systemctl disable --now nginx"
    fi
  done
  ok "80 и 443 свободны"

  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep '^Status: active' >/dev/null; then
    ufw allow 80/tcp >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
    ok "ufw активен — 80/tcp и 443/tcp разрешены"
  fi
fi

# ───────────────────────── исходники tproxy-server ───────────────────────
if [[ "$DRY_RUN" != "1" ]]; then
  step "Получение tproxy-server"
  if [[ ! -d "$SRC_DIR/.git" ]]; then
    rm -rf "$SRC_DIR"
    git init -q "$SRC_DIR"
    git -C "$SRC_DIR" remote add origin "$UPSTREAM_REPO"
  fi
  git -C "$SRC_DIR" remote set-url origin "$UPSTREAM_REPO"
  git -C "$SRC_DIR" fetch -q --depth 1 origin "$UPSTREAM_REF" \
    || die "Не удалось получить $UPSTREAM_REF из $UPSTREAM_REPO — проверьте выход в интернет и --upstream-ref."
  git -C "$SRC_DIR" reset -q --hard FETCH_HEAD
  ok "tproxy-server $(git -C "$SRC_DIR" rev-parse --short HEAD) в $SRC_DIR"
  [[ -f "$SRC_DIR/deploy/install.sh" ]] || die "В tproxy-server нет deploy/install.sh — структура изменилась, см. его README."
  [[ -x "$SRC_DIR/deploy/install.sh" ]] || chmod +x "$SRC_DIR/deploy/install.sh"
  # Баги umask 077 (go test и права /opt/MTProxy), которые TGweb 1.0 обходил
  # патчами, исправлены в апстриме 2026-09-29 (51215a2, c8adb8b).
fi

# ───────────────────────── сборка сайта-прикрытия ────────────────────────
step "Сборка сайта-прикрытия"
[[ "$DRY_RUN" == "1" ]] && BUILD_DIR="/tmp/tgweb-site-dryrun"
rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
cp -a "$SITE_SRC/." "$BUILD_DIR/"

rand_hex() { openssl rand -hex "${1:-4}" 2>/dev/null || head -c "${1:-4}" /dev/urandom | od -An -tx1 | tr -d ' \n'; }
pick() { local -n arr="$1"; printf '%s' "${arr[RANDOM % ${#arr[@]}]}"; }

# Каждая установка получает свой набор мелочей, чтобы страницы не были
# байт-в-байт одинаковыми у всех, кто поставил этот репозиторий.
# Массивы ниже читаются через nameref в pick(), поэтому shellcheck их не видит.
# shellcheck disable=SC2034
ACCENTS=("#5b9cff" "#7a8cff" "#4ea8de" "#5fb3a3" "#c98bdb" "#e08a5a" "#61b0f0" "#8fbf6a")
# shellcheck disable=SC2034
H1S=(
  "A small video pipeline you can actually host yourself."
  "Video ingest, transcode and delivery on one box."
  "Self-hosted video, without the per-minute bill."
  "One binary between your upload and an HLS playlist."
)
# shellcheck disable=SC2034
LEADS=(
  "takes an upload, normalises it, transcodes to an adaptive HLS ladder and serves the segments over HTTP. One binary, one config file, no queue broker, no object storage requirement."
  "probes what you give it, builds an adaptive HLS ladder with ffmpeg and serves the segments straight off local disk. No broker, no bucket, no control plane."
  "is a single process that watches a directory, transcodes what appears there and publishes an HLS playlist. That is the whole feature set."
)
# shellcheck disable=SC2034
WHYS=(
  "Every hosted transcoder I tried billed per minute of output and wanted my media in their bucket. For a personal archive of a few hundred hours that is absurd."
  "I wanted to re-encode an old camcorder archive without uploading it to anyone. Turns out the hard part is not the transcoding, it is all the platform around it."
  "This started as a shell script with a cron entry. It grew a state machine and an HTTP API because resuming a failed batch by hand got old."
)

# Выбор сохраняется в $SITE_ENV_FILE: переустановка не должна менять внешний
# вид сайта (живой сайт, который вдруг перекрасился, выглядит странно).
# Новый набор — удалите файл и запустите install.sh снова.
ACCENT=""; H1=""; LEAD=""; WHY=""; BUILD_ID=""; ASSET1=""; ASSET2=""; DURATION=""
if [[ "$DRY_RUN" != "1" && -r "$SITE_ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$SITE_ENV_FILE"
  info "Оформление сайта взято из $SITE_ENV_FILE"
fi
[[ -n "$ACCENT" ]]   || ACCENT="$(pick ACCENTS)"
[[ -n "$H1" ]]       || H1="$(pick H1S)"
[[ -n "$LEAD" ]]     || LEAD="$(pick LEADS)"
[[ -n "$WHY" ]]      || WHY="$(pick WHYS)"
[[ -n "$BUILD_ID" ]] || BUILD_ID="$(rand_hex 4)"
[[ -n "$ASSET1" ]]   || ASSET1="as_$(rand_hex 4)"
[[ -n "$ASSET2" ]]   || ASSET2="as_$(rand_hex 4)"
[[ -n "$DURATION" ]] || DURATION="$(( (RANDOM % 900 + 120) * 1000 + RANDOM % 999 ))"
# PROJECT_LC — имя CLI-команды и путей в примерах на сайте («magic api init
# --data /var/lib/magic api» выдало бы шаблон), поэтому это slug: [a-z0-9-].
# Кириллица и прочее не-ASCII отбрасываются; пустой результат — первая метка домена.
PROJECT_LC="$(printf '%s' "$PROJECT" | tr '[:upper:]' '[:lower:]' \
  | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
[[ -n "$PROJECT_LC" ]] || PROJECT_LC="${FQDN%%.*}"
YEAR="$(date +%Y)"

subst() {
  local f="$1"
  python3 - "$f" <<'PY'
import os, sys
path = sys.argv[1]
keys = ["HOST","PROJECT","PROJECT_LC","ACCENT","H1","LEAD","WHY",
        "BUILD","ASSET1","ASSET2","DURATION","YEAR"]
with open(path, encoding="utf-8") as fh:
    data = fh.read()
for k in keys:
    data = data.replace("__%s__" % k, os.environ.get("TGW_" + k, ""))
with open(path, "w", encoding="utf-8") as fh:
    fh.write(data)
PY
}

export TGW_HOST="$FQDN" TGW_PROJECT="$PROJECT" \
       TGW_PROJECT_LC="$PROJECT_LC" TGW_ACCENT="$ACCENT" TGW_H1="$H1" \
       TGW_LEAD="$LEAD" TGW_WHY="$WHY" TGW_BUILD="$BUILD_ID" \
       TGW_ASSET1="$ASSET1" TGW_ASSET2="$ASSET2" TGW_DURATION="$DURATION" \
       TGW_YEAR="$YEAR"

if ! command -v python3 >/dev/null; then
  die "Нужен python3 для подстановки значений в шаблоны сайта (apt-get install -y python3)."
fi
while IFS= read -r -d '' f; do subst "$f"; done \
  < <(find "$BUILD_DIR" -type f \( -name '*.html' -o -name '*.css' -o -name '*.txt' \) -print0)

if grep -rq '__[A-Z_]\{2,\}__' "$BUILD_DIR" 2>/dev/null; then
  warn "В сайте остались незаполненные заглушки:"
  grep -rho '__[A-Z_]\{2,\}__' "$BUILD_DIR" | sort -u | sed 's/^/         /'
fi

chmod -R a+rX "$BUILD_DIR"
ok "Собрано файлов: $(find "$BUILD_DIR" -type f | wc -l), акцент $ACCENT, build $BUILD_ID"

if [[ "$DRY_RUN" == "1" ]]; then
  printf '\n  DRY RUN завершён. Сайт собран в %s\n\n' "$BUILD_DIR"
  exit 0
fi

# ────────────────────────── сохранение состояния ─────────────────────────
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
umask 077
printf '%s\n' "$SECRET" > "$SECRET_FILE"; chmod 400 "$SECRET_FILE"
{
  printf '# TGweb: выбранное оформление сайта. Удалите файл для нового набора.\n'
  for v in ACCENT H1 LEAD WHY BUILD_ID ASSET1 ASSET2 DURATION; do
    printf '%s=%q\n' "$v" "${!v}"
  done
} > "$SITE_ENV_FILE"
chmod 600 "$SITE_ENV_FILE"
umask 022

# ─────────────────────── запуск установщика upstream ─────────────────────
step "Установка Caddy + relay + MTProxy"
info "Это займёт несколько минут: сборка MTProxy и выпуск сертификата."
upstream_args=(
  --hostname "$FQDN"
  --email "$EMAIL"
  --site-dir "$BUILD_DIR"
  --secret "$SECRET"
  --mtproxy-workers "$WORKERS"
  --mtproxy-max-connections 4096
)
[[ -n "$BASE_PATH" ]] && upstream_args+=(--base-path "$BASE_PATH")

# Первое обновление установки без token.key (все установки TGweb 1.0):
# как deploy/update-relay.sh, включаем временный drain старых токенов,
# иначе релей не узнает их после перезапуска (HARDENING.md апстрима).
TOKEN_DROPIN="/etc/systemd/system/tproxy-server.service.d/token-migration.conf"
if [[ -f /etc/tproxy-server/config.json && ! -e /etc/tproxy-server/token.key ]]; then
  install -d -m 0755 "$(dirname "$TOKEN_DROPIN")"
  if [[ ! -e "$TOKEN_DROPIN" ]]; then
    printf '[Service]\nEnvironment=TPROXY_LEGACY_TOKEN_DRAIN=1\n' > "$TOKEN_DROPIN"
    chmod 644 "$TOKEN_DROPIN"
  fi
  systemctl daemon-reload
  warn "Обновление старой установки: включён временный drain старых токенов ($TOKEN_DROPIN)"
fi
(cd "$SRC_DIR" && ./deploy/install.sh "${upstream_args[@]}") \
  || die "deploy/install.sh из tproxy-server завершился с ошибкой — причина в выводе выше."

# ─────────────────────── обновление сайта-прикрытия ──────────────────────
# Апстрим копирует сайт в $SITE_LIVE только при первой установке и сохраняет
# существующий при переустановке. Правки в site/ доезжают только здесь.
step "Обновление сайта-прикрытия"
if diff -rq "$BUILD_DIR" "$SITE_LIVE" >/dev/null 2>&1; then
  ok "$SITE_LIVE совпадает со сборкой"
else
  backup="$SITE_LIVE.bak.$(date +%Y%m%d%H%M%S)"
  rm -rf "$SITE_LIVE".bak.*
  cp -a "$SITE_LIVE" "$backup"
  find "$SITE_LIVE" -mindepth 1 -delete
  cp -a "$BUILD_DIR/." "$SITE_LIVE/"
  chown -R root:root "$SITE_LIVE"
  chmod -R a+rX "$SITE_LIVE"
  if /usr/local/bin/tproxy-server -config /etc/tproxy-server/config.json \
       -profiles-file /etc/tproxy-server/profiles.json -check >/dev/null; then
    # relay читает public_dir только при старте; активные сессии переподключатся сами
    systemctl restart tproxy-server
    ok "Сайт обновлён, tproxy-server перезапущен (прежняя версия: $backup)"
  else
    find "$SITE_LIVE" -mindepth 1 -delete
    cp -a "$backup/." "$SITE_LIVE/"
    die "tproxy-server -check не принял новый сайт — восстановлен прежний из $backup."
  fi
fi

# ──────────────────────────── пост-проверки ──────────────────────────────
step "Проверка сервисов"
sleep 5
failed=0
for svc in caddy tproxy-server mtproxy; do
  if systemctl is-active --quiet "$svc"; then
    ok "$svc: active"
  else
    warn "$svc НЕ активен — journalctl -u $svc -n 50 --no-pager"
    failed=1
  fi
done

step "Локальные health-эндпоинты"
curl -fsS --max-time 5 http://127.0.0.1:8081/healthz >/dev/null 2>&1 \
  && ok "/healthz отвечает" || { warn "/healthz недоступен"; failed=1; }
if curl -fsS --max-time 8 http://127.0.0.1:8081/readyz >/dev/null 2>&1; then
  ok "/readyz готов — бэкенд MTProxy на месте"
else
  warn "/readyz не готов: systemctl status mtproxy; ss -lntp | grep 2398"
  failed=1
fi

step "Проверка сайта снаружи"
code="000"
for i in 1 2 3 4 5 6; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 "https://$FQDN/" 2>/dev/null || true)"
  [[ -n "$code" ]] || code="000"
  [[ "$code" == "200" ]] && break
  info "попытка $i/6: код $code, ждём выпуск сертификата..."
  sleep 10
done
if [[ "$code" == "200" ]]; then
  ok "https://$FQDN/ отдаёт 200 — прикрытие работает"
else
  warn "https://$FQDN/ вернул $code. ACME может занять пару минут."
  warn "Смотрите: journalctl -u caddy -n 60 --no-pager"
fi

# ─────────────────────────────── итог ────────────────────────────────────
# Реквизиты считаются из фактического config.json: base path мог быть
# сгенерирован апстримом или сохранён с прошлой установки.
LIVE_BASE_PATH="$(tgweb_base_path)"
CLIENT_SERVER="$(tgweb_client_server "$FQDN" "$LIVE_BASE_PATH")"
LINK="$(tgweb_link https "$FQDN" "$LIVE_BASE_PATH" "$SECRET")"
TG_LINK="$(tgweb_link tg "$FQDN" "$LIVE_BASE_PATH" "$SECRET")"
{
  printf 'TGweb %s — установлено %s, tproxy-server %s\n\n' \
    "$VERSION" "$(date -Is)" "$(git -C "$SRC_DIR" rev-parse --short HEAD 2>/dev/null || echo '?')"
  printf 'Тип прокси   : WEB\n'
  printf 'Proxy server : %s\n' "$CLIENT_SERVER"
  printf 'Proxy secret : %s   (для ручного ввода)\n' "$SECRET"
  printf 'Base path    : %s\n\n' "${LIVE_BASE_PATH:-нет (корень хоста)}"
  printf 'Ссылка       : %s\n' "$LINK"
  printf 'tg://        : %s\n\n' "$TG_LINK"
  printf 'Сайт (сборка) : %s\nСайт (рабочий): %s\n' "$BUILD_DIR" "$SITE_LIVE"
  printf 'Конфиг relay  : /etc/tproxy-server/config.json\n'
  printf 'Профили       : /etc/tproxy-server/profiles.json\n'
} > "$INFO_FILE"
chmod 600 "$INFO_FILE"

cat <<EOF

${BOLD}──────────────────────────────── готово ────────────────────────────────${OFF}

  В Telegram выберите тип прокси ${BOLD}WEB${OFF} и введите:

    Server : ${CYAN}$CLIENT_SERVER${OFF}
    Secret : ${CYAN}$SECRET${OFF}

  Или откройте ссылку (secret в ней ${LIVE_BASE_PATH:+в другой, }закодированной форме — это нормально):

    ${GREEN}$LINK${OFF}

  Нужен клиент Telegram с поддержкой WEB-прокси.${LIVE_BASE_PATH:+
  Адрес с путём (base path) понимают только клиенты с его поддержкой: старый
  клиент сообщит о неподдерживаемом типе прокси и попросит обновиться.
  Для таких клиентов переустановите с --base-path none (ссылка изменится).}

  Реквизиты сохранены в $INFO_FILE (chmod 600).
$( [[ -e "$TOKEN_DROPIN" ]] && printf '\n%s  Drain токенов включён.%s Когда клиенты переподключатся (обычно через\n  несколько дней), выключите его:\n    rm %s && systemctl daemon-reload && systemctl restart tproxy-server\n' "$YELLOW" "$OFF" "$TOKEN_DROPIN" )

  Управление:
    bash status.sh                       состояние и ссылка
    systemctl status tproxy-server caddy mtproxy
    journalctl -u tproxy-server -f
    curl -s http://127.0.0.1:8081/metrics
    cd $SRC_DIR && sudo ./deploy/update-relay.sh

${YELLOW}  Важно:${OFF} отредактируйте тексты в site/ под себя и запустите install.sh
  заново. Одинаковый сайт у многих операторов сам становится сигнатурой
  для активного зондирования — это прямая рекомендация авторов tproxy-server.

EOF

exit "$failed"
