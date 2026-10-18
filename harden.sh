#!/usr/bin/env bash
#
# TGweb — подготовка и защита сервера под WEB-прокси одной командой.
#
#   sudo bash harden.sh -y                      # всё, кроме SSH-hardening
#   sudo bash harden.sh -y --harden-ssh         # + вход только по ключу
#
# Без клонирования репозитория:
#   curl -fsSL https://raw.githubusercontent.com/SkunkBG/TG-WEB/main/harden.sh | bash -s -- -y
#
# Что делает (каждый блок отключается флагом --skip-*):
#   1. Пакеты: apt upgrade, ufw, fail2ban, chrony, conntrack.
#   2. Своп (по RAM и свободному месту), лимит journald.
#   3. Файрвол ufw: входящие запрещены, открыты SSH (rate limit), 80, 443.
#   4. fail2ban для SSH через journald.
#   5. Сеть: BBR + fq, буферы и очереди по объёму RAM, conntrack, PLPMTUD,
#      защита от микро-MSS, отключение IPv6, лимиты дескрипторов.
#   6. Автообновления безопасности.
#   7. --harden-ssh: вход только по ключу (если ключи есть) с проверкой.
#
# Правила tproxy-firewall от установщика прокси (nftables, inet tproxy_backend,
# закрывает 2398/8888 снаружи) скрипт не трогает: ufw живёт в другой таблице.
#
set -euo pipefail
# Под pipefail «cmd | grep -q» ложно проваливается: grep выходит на первом
# совпадении, cmd получает SIGPIPE, и статус пайпа ненулевой. Поэтому в
# пайпах ниже grep читает вход целиком (>/dev/null вместо -q).

SYSCTL_FILE="/etc/sysctl.d/99-tgweb.conf"
JOURNALD_FILE="/etc/systemd/journald.conf.d/99-tgweb.conf"
JAIL_FILE="/etc/fail2ban/jail.local"
MODPROBE_FILE="/etc/modprobe.d/99-tgweb-conntrack.conf"
MODULES_FILE="/etc/modules-load.d/99-tgweb.conf"
LIMITS_FILE="/etc/security/limits.d/99-tgweb-nofile.conf"
SYSTEMD_LIMITS_FILE="/etc/systemd/system.conf.d/99-tgweb-limits.conf"
# 000-… читается раньше хостерских 00password.conf / 50-cloud-init.conf и при
# strcmp, и при сортировке по локали; в sshd побеждает ПЕРВОЕ значение.
SSHD_DROPIN="/etc/ssh/sshd_config.d/000-tgweb-hardening.conf"
SWAPFILE="/swapfile"

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  RED=$'\033[31m'; OFF=$'\033[0m'
else
  BOLD=''; DIM=''; GREEN=''; YELLOW=''; RED=''; OFF=''
fi
step() { printf '\n%s==> %s%s\n' "$BOLD" "$1" "$OFF"; }
ok()   { printf '  %sok%s   %s\n' "$GREEN" "$OFF" "$1"; }
warn() { printf '  %s!!%s   %s\n' "$YELLOW" "$OFF" "$1"; }
info() { printf '  %s·%s    %s\n' "$DIM" "$OFF" "$1"; }
die()  { printf '\n  %sошибка:%s %s\n\n' "$RED" "$OFF" "$1" >&2; exit 1; }

DO_UPGRADE=1; DO_FIREWALL=1; DO_FAIL2BAN=1; DO_TUNING=1
DO_EXTRAS=1; DISABLE_IPV6=1; HARDEN_SSH=0; RESET_FIREWALL=0; ASSUME_YES=0
EXTRA_PORTS=()
usage() {
  cat <<EOF
TGweb harden — подготовка и защита сервера.

  sudo bash harden.sh [опции]

  -y, --yes          без вопросов (иначе спрашивает перед каждым блоком)
  --harden-ssh       вход по SSH только по ключу; выполняется, только если
                     в authorized_keys есть ключи, с проверкой через sshd -T
  --allow-port P     открыть ещё порт, например 8443/tcp (можно несколько раз)
  --keep-ipv6        не отключать IPv6
  --reset-firewall   сбросить ВСЕ существующие правила ufw
  --skip-upgrade     не делать apt upgrade
  --skip-firewall    не настраивать ufw
  --skip-fail2ban    не настраивать fail2ban
  --skip-tuning      не менять sysctl, conntrack и лимиты
  --skip-extras      не трогать своп, журнал, chrony и автообновления
  -h, --help         справка
EOF
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)         ASSUME_YES=1; shift ;;
    --harden-ssh)     HARDEN_SSH=1; shift ;;
    --allow-port)
      [[ "${2:-}" =~ ^[0-9]{1,5}(/(tcp|udp))?$ ]] || die "--allow-port: ожидается ПОРТ или ПОРТ/tcp|udp"
      EXTRA_PORTS+=("$2"); shift 2 ;;
    --keep-ipv6)      DISABLE_IPV6=0; shift ;;
    --reset-firewall) RESET_FIREWALL=1; shift ;;
    --skip-upgrade)   DO_UPGRADE=0; shift ;;
    --skip-firewall)  DO_FIREWALL=0; shift ;;
    --skip-fail2ban)  DO_FAIL2BAN=0; shift ;;
    --skip-tuning)    DO_TUNING=0; shift ;;
    --skip-extras)    DO_EXTRAS=0; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) die "Неизвестный аргумент: $1 (см. --help)" ;;
  esac
done

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  [[ -t 0 ]] || die "Нет терминала для подтверждения — добавьте -y."
  printf '  %s [y/N] > ' "$1"
  local a; IFS= read -r a || return 1
  case "${a:-}" in [yYдД]|[yY]es|да) return 0 ;; *) return 1 ;; esac
}

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
# На свежем сервере плановый apt-daily держит блокировку dpkg — ждём, а не падаем.
APT=(apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confold)
apt_updated=0
apt_install() {
  if [[ $apt_updated -eq 0 ]]; then "${APT[@]}" update -qq; apt_updated=1; fi
  "${APT[@]}" install -y -qq "$@" >/dev/null
}

printf '\n%s  TGweb harden%s  %sподготовка и защита сервера%s\n' "$BOLD" "$OFF" "$DIM" "$OFF"

# ─────────────────────────────── окружение ────────────────────────────────
step "Проверка окружения"
[[ $EUID -eq 0 ]] || die "Нужны права root: sudo bash harden.sh"
command -v systemctl >/dev/null || die "Нет systemd."
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  ok "ОС: ${PRETTY_NAME:-${ID:-неизвестна}}, ядро $(uname -r)"
  case "${ID:-}" in
    debian|ubuntu) : ;;
    *) warn "Скрипт рассчитан на Debian и Ubuntu. Продолжаю, но проверяйте вывод." ;;
  esac
fi
mem_mb="$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)"
ok "RAM ${mem_mb} МБ, ядер $(nproc)"

# Параметры сети по объёму RAM (как в базовом скрипте нод)
if   (( mem_mb < 1500 )); then NET_BACKLOG=16384; SOCK_BUF=8388608;  CONNTRACK_MAX=65536
elif (( mem_mb < 3000 )); then NET_BACKLOG=32768; SOCK_BUF=8388608;  CONNTRACK_MAX=131072
else                           NET_BACKLOG=65536; SOCK_BUF=16777216; CONNTRACK_MAX=262144
fi
SYN_BACKLOG=$(( NET_BACKLOG / 2 )); (( SYN_BACKLOG > 65535 )) && SYN_BACKLOG=65535

# порты SSH: sshd -T учитывает Include и Match, это самый надёжный источник
ssh_ports=()
if command -v sshd >/dev/null; then
  while IFS= read -r p; do [[ -n "$p" ]] && ssh_ports+=("$p"); done \
    < <(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' || true)
fi
if [[ ${#ssh_ports[@]} -eq 0 ]] && command -v ss >/dev/null; then
  while IFS= read -r p; do [[ -n "$p" ]] && ssh_ports+=("$p"); done \
    < <(ss -lntpH 2>/dev/null | awk '/sshd/{sub(/.*:/,"",$4); print $4}' | sort -u || true)
fi
[[ ${#ssh_ports[@]} -eq 0 ]] && ssh_ports=(22)

# порт, через который мы сейчас подключены — его закрыть нельзя ни в каком случае
admin_ip=""; live_port=""
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  read -r admin_ip _ _ live_port <<<"$SSH_CONNECTION"
  [[ -n "$live_port" ]] && ok "Текущая SSH-сессия: порт $live_port, ваш IP $admin_ip"
  if [[ -n "$live_port" ]] && ! printf '%s\n' "${ssh_ports[@]}" | grep -x "$live_port" >/dev/null; then
    ssh_ports+=("$live_port")
    warn "Порт $live_port не нашёлся в конфиге sshd — добавляю принудительно"
  fi
else
  warn "Не вижу SSH_CONNECTION (локальная консоль?). Порты SSH: ${ssh_ports[*]}"
fi
ok "Порты SSH к разрешению: ${ssh_ports[*]}"

if [[ $DISABLE_IPV6 -eq 1 ]] && ip -6 addr show scope global 2>/dev/null | grep inet6 >/dev/null; then
  warn "У сервера есть глобальный IPv6 — он будет отключён. Удалите AAAA-записи доменов,"
  warn "иначе клиенты и Let's Encrypt пойдут на мёртвый адрес. Оставить IPv6: --keep-ipv6"
fi

# ───────────────────────────── 1. пакеты ──────────────────────────────────
step "Пакеты"
if [[ $DO_UPGRADE -eq 1 ]] && confirm "Обновить систему (apt upgrade)?"; then
  "${APT[@]}" update -qq; apt_updated=1
  "${APT[@]}" upgrade -y -qq >/dev/null
  ok "Система обновлена"
  [[ -e /var/run/reboot-required ]] && warn "Нужна перезагрузка (новое ядро/библиотеки) — сделайте её в удобное время"
else
  info "apt upgrade пропущен"
fi
pkgs=(ca-certificates curl)
[[ $DO_FIREWALL -eq 1 ]] && pkgs+=(ufw)
[[ $DO_FAIL2BAN -eq 1 ]] && pkgs+=(fail2ban python3-systemd)
[[ $DO_TUNING -eq 1 ]]   && pkgs+=(conntrack)
[[ $DO_EXTRAS -eq 1 ]]   && pkgs+=(chrony)
apt_install "${pkgs[@]}"
ok "Установлено: ${pkgs[*]}"

# ──────────────────────── 2. своп, журнал, время ──────────────────────────
if [[ $DO_EXTRAS -eq 1 ]]; then
  step "Своп"
  if [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then
    ok "Своп уже есть ($(free -m | awk '/^Swap:/{print $2}') МБ)"
  elif [[ -e "$SWAPFILE" ]]; then
    warn "$SWAPFILE существует, но не подключён — не трогаю, разберитесь вручную"
  else
    swap_mb=1024; (( mem_mb < 2048 )) && swap_mb=2048
    free_mb="$(df -Pm / | awk 'NR==2{print $4}')"
    if (( free_mb < swap_mb + 3072 )); then
      warn "На / свободно ${free_mb} МБ — своп ${swap_mb} МБ не помещается с запасом, пропускаю"
    elif confirm "Создать своп-файл ${swap_mb} МБ?"; then
      if fallocate -l "${swap_mb}M" "$SWAPFILE" 2>/dev/null || \
         dd if=/dev/zero of="$SWAPFILE" bs=1M count="$swap_mb" status=none; then
        chmod 600 "$SWAPFILE"
        mkswap "$SWAPFILE" >/dev/null
        swapon "$SWAPFILE"
        grep "^$SWAPFILE " /etc/fstab >/dev/null || printf '%s none swap sw 0 0\n' "$SWAPFILE" >> /etc/fstab
        ok "Своп ${swap_mb} МБ подключён и прописан в /etc/fstab"
      else
        warn "Не удалось создать своп-файл"; rm -f "$SWAPFILE"
      fi
    fi
  fi

  step "Журнал и время"
  mkdir -p "$(dirname "$JOURNALD_FILE")"
  cat > "$JOURNALD_FILE" <<'EOF'
# Создано TGweb harden.sh: journald по умолчанию может занять до 10% диска.
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
MaxRetentionSec=1week
EOF
  systemctl restart systemd-journald 2>/dev/null || true
  ok "journald ограничен 200 МБ"
  if systemctl enable --now chrony >/dev/null 2>&1 || systemctl enable --now chronyd >/dev/null 2>&1; then
    ok "chrony синхронизирует время"
  else
    warn "chrony не запустился — время синхронизирует то, что было ($(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo ?))"
  fi
fi

# ──────────────────────────────── 3. ufw ──────────────────────────────────
if [[ $DO_FIREWALL -eq 1 ]]; then
  step "Файрвол (ufw)"
  printf '\n  Будет применено:\n'
  printf '    входящие  : запрещены по умолчанию\n'
  printf '    исходящие : разрешены\n'
  for p in "${ssh_ports[@]}"; do printf '    разрешить : %s/tcp (SSH, с ограничением частоты)\n' "$p"; done
  printf '    разрешить : 80/tcp (ACME), 443/tcp (прокси)\n'
  for p in "${EXTRA_PORTS[@]+"${EXTRA_PORTS[@]}"}"; do printf '    разрешить : %s (--allow-port)\n' "$p"; done
  # Без --reset-firewall существующие правила (порты VPN-ноды, панели,
  # мониторинга) остаются: на общем сервере сброс молча закрыл бы их.
  existing="$(ufw status 2>/dev/null | sed -n '/^--/,$p' | sed '1d' | grep -v '^$' || true)"
  if [[ -n "$existing" ]]; then
    if [[ $RESET_FIREWALL -eq 1 ]]; then
      printf '    %sудалить   : все текущие правила ниже (--reset-firewall)%s\n' "$YELLOW" "$OFF"
    else
      printf '    сохранить : текущие правила ниже (сброс — флагом --reset-firewall)\n'
    fi
    printf '%s\n' "$existing" | sed 's/^/                /'
  fi
  printf '\n'

  if confirm "Применить?"; then
    if [[ $RESET_FIREWALL -eq 1 ]]; then
      ufw --force reset >/dev/null 2>&1 || true
      info "Правила ufw сброшены"
    fi
    # При отключённом IPv6 ufw не нужны правила ip6tables
    if [[ $DISABLE_IPV6 -eq 1 && -f /etc/default/ufw ]]; then
      sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw
    fi
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    for p in "${ssh_ports[@]}"; do ufw limit "$p/tcp" comment 'SSH' >/dev/null; done
    ufw allow 80/tcp  comment 'HTTP ACME' >/dev/null
    ufw allow 443/tcp comment 'HTTPS proxy' >/dev/null
    for p in "${EXTRA_PORTS[@]+"${EXTRA_PORTS[@]}"}"; do ufw allow "$p" comment 'harden --allow-port' >/dev/null; done
    ufw --force enable >/dev/null
    systemctl enable ufw >/dev/null 2>&1 || true
    ok "Правила применены"
    ufw status verbose | sed 's/^/       /'
    for p in "${ssh_ports[@]}"; do
      if ufw status | grep "^$p/tcp" >/dev/null; then
        ok "SSH-порт $p подтверждён в правилах"
      else
        warn "SSH-порт $p НЕ виден в правилах — проверьте вручную, не разрывая сессию!"
      fi
    done
  else
    info "Файрвол не изменён"
  fi
fi

# ───────────────────────────── 4. fail2ban ────────────────────────────────
if [[ $DO_FAIL2BAN -eq 1 ]]; then
  step "fail2ban"
  ok "fail2ban $(fail2ban-server --version 2>/dev/null | head -n1 | awk '{print $2}')"

  # На Debian 12/13 и свежих Ubuntu /var/log/auth.log нет (только journald),
  # а штатный jail sshd читает именно его и молча не стартует. Поэтому
  # backend = systemd; ему нужен рабочий python3-systemd — проверяем импорт.
  f2b_backend="systemd"
  if python3 -c 'from systemd import journal' >/dev/null 2>&1; then
    ok "systemd-backend доступен (python3-systemd импортируется)"
  elif [[ -s /var/log/auth.log ]]; then
    f2b_backend="auto"
    warn "python3-systemd не работает — беру файловый backend, /var/log/auth.log на месте"
  else
    warn "python3-systemd не работает, а /var/log/auth.log нет — jail не увидит логи!"
    warn "Лечится: apt-get install --reinstall python3-systemd (или apt-get install rsyslog)"
  fi

  f2b_banaction="ufw"
  if ! ufw status 2>/dev/null | grep '^Status: active' >/dev/null; then
    f2b_banaction="nftables-multiport"
    warn "ufw неактивен — баню через nftables-multiport"
  fi
  f2b_logpath=""
  [[ "$f2b_backend" != "systemd" ]] && f2b_logpath="logpath = /var/log/auth.log"
  f2b_ipv6="auto"; [[ $DISABLE_IPV6 -eq 1 ]] && f2b_ipv6="no"

  jail_ports="$(IFS=,; printf '%s' "${ssh_ports[*]}")"
  ignore="127.0.0.1/8 ::1"
  [[ -n "$admin_ip" ]] && ignore="$ignore $admin_ip"

  if [[ -e "$JAIL_FILE" ]]; then
    cp -a "$JAIL_FILE" "$JAIL_FILE.bak.$(date +%Y%m%d%H%M%S)"
    info "Прежний jail.local сохранён рядом с суффиксом .bak"
  fi
  cat > "$JAIL_FILE" <<EOF
# Создано TGweb harden.sh — правьте свободно, скрипт делает резервную копию.
[DEFAULT]
# Логи SSH живут в journald: на Debian 12/13 и свежих Ubuntu файла
# /var/log/auth.log нет, и файловый backend тихо не стартует.
backend   = $f2b_backend
banaction = $f2b_banaction
allowipv6 = $f2b_ipv6

bantime   = 1h
findtime  = 10m
maxretry  = 5

# Повторные визиты — всё более долгий бан, до недели.
bantime.increment = true
bantime.factor    = 2
bantime.maxtime   = 1w

# Себя не баним.
ignoreip  = $ignore

[sshd]
enabled = true
port    = $jail_ports
$f2b_logpath
EOF
  chmod 644 "$JAIL_FILE"
  ok "Записан $JAIL_FILE (порты $jail_ports)"

  if fail2ban-client -t >/dev/null 2>&1; then
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban
    sleep 3
    if systemctl is-active --quiet fail2ban; then
      ok "fail2ban активен"
      fail2ban-client status sshd 2>/dev/null | sed 's/^/       /' \
        || warn "Jail sshd не отвечает — journalctl -u fail2ban -n 40"
    else
      warn "fail2ban не поднялся — journalctl -u fail2ban -n 40 --no-pager"
    fi
  else
    warn "fail2ban-client -t сообщил об ошибке, сервис не перезапускаю:"
    fail2ban-client -t 2>&1 | tail -15 | sed 's/^/       /'
  fi
fi

# ─────────────────────────────── 5. сеть ──────────────────────────────────
if [[ $DO_TUNING -eq 1 ]]; then
  step "Сетевой тюнинг"
  modprobe tcp_bbr 2>/dev/null || true
  modprobe nf_conntrack 2>/dev/null || true
  bbr_ok=0
  grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null && bbr_ok=1
  cur_file_max="$(cat /proc/sys/fs/file-max 2>/dev/null || echo 0)"

  {
    printf '# Создано TGweb harden.sh (RAM %s МБ)\n\n' "$mem_mb"
    if [[ $bbr_ok -eq 1 ]]; then
      printf 'net.core.default_qdisc = fq\n'
      printf 'net.ipv4.tcp_congestion_control = bbr\n\n'
    fi
    printf '# Очереди и буферы — по объёму RAM\n'
    printf 'net.core.somaxconn = 65535\n'
    printf 'net.core.netdev_max_backlog = %s\n' "$NET_BACKLOG"
    printf 'net.ipv4.tcp_max_syn_backlog = %s\n' "$SYN_BACKLOG"
    printf 'net.core.rmem_max = %s\n' "$SOCK_BUF"
    printf 'net.core.wmem_max = %s\n' "$SOCK_BUF"
    printf 'net.ipv4.tcp_rmem = 4096 87380 %s\n' "$SOCK_BUF"
    printf 'net.ipv4.tcp_wmem = 4096 65536 %s\n\n' "$SOCK_BUF"
    printf '# Долгие HTTPS-сессии прокси и исходящие к дата-центрам Telegram\n'
    printf 'net.ipv4.tcp_slow_start_after_idle = 0\n'
    printf 'net.ipv4.tcp_fin_timeout = 15\n'
    printf 'net.ipv4.tcp_tw_reuse = 1\n'
    printf 'net.ipv4.tcp_keepalive_time = 600\n'
    printf 'net.ipv4.tcp_keepalive_intvl = 30\n'
    printf 'net.ipv4.tcp_keepalive_probes = 5\n'
    printf 'net.ipv4.ip_local_port_range = 10240 65535\n\n'
    printf '# TFO только для исходящих: серверный TFO отличает нас от обычного веб-сервера\n'
    printf 'net.ipv4.tcp_fastopen = 1\n\n'
    printf '# PLPMTUD в реактивном режиме: страховка от ICMP black hole у операторов\n'
    printf 'net.ipv4.tcp_mtu_probing = 1\n'
    printf 'net.ipv4.tcp_base_mss = 1024\n'
    printf 'net.ipv4.tcp_mtu_probe_floor = 512\n\n'
    printf '# CVE-2019-11479: клиент не навяжет микро-MSS\n'
    printf 'net.ipv4.tcp_min_snd_mss = 536\n\n'
    printf '# conntrack (его использует ufw)\n'
    printf 'net.netfilter.nf_conntrack_max = %s\n' "$CONNTRACK_MAX"
    printf 'net.netfilter.nf_conntrack_tcp_timeout_established = 3600\n'
    printf 'net.netfilter.nf_conntrack_tcp_timeout_time_wait = 60\n\n'
    # file-max — общесистемный потолок; на современных ядрах он уже выше
    # 1048576, и безусловная запись его бы ПОНИЗИЛА. Пишем только если меньше.
    if [[ "$cur_file_max" =~ ^[0-9]+$ ]] && (( cur_file_max < 1048576 )); then
      printf 'fs.file-max = 1048576\n'
    fi
    printf 'vm.swappiness = 10\n'
    if [[ $DISABLE_IPV6 -eq 1 ]]; then
      printf '\n# IPv6 отключён (оставить: harden.sh --keep-ipv6)\n'
      printf 'net.ipv6.conf.all.disable_ipv6 = 1\n'
      printf 'net.ipv6.conf.default.disable_ipv6 = 1\n'
      printf 'net.ipv6.conf.lo.disable_ipv6 = 1\n'
    fi
  } > "$SYSCTL_FILE"

  printf 'options nf_conntrack hashsize=%s\n' "$(( CONNTRACK_MAX / 4 ))" > "$MODPROBE_FILE"
  printf 'tcp_bbr\nnf_conntrack\n' > "$MODULES_FILE"
  # hashsize модуля живьём (modprobe.d подействует при следующей загрузке)
  [[ -w /sys/module/nf_conntrack/parameters/hashsize ]] && \
    echo "$(( CONNTRACK_MAX / 4 ))" > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true

  if sysctl_err="$(sysctl -p "$SYSCTL_FILE" 2>&1 >/dev/null)" && [[ -z "$sysctl_err" ]]; then
    ok "Записан $SYSCTL_FILE и применён"
  else
    warn "Часть параметров ядро не приняло (бывает в контейнерах/OpenVZ):"
    printf '%s\n' "$sysctl_err" | sed 's/^/       /'
  fi
  [[ $bbr_ok -eq 1 ]] || warn "BBR в ядре недоступен — оставлен штатный алгоритм"

  # Лимиты дескрипторов для сессий и сервисов
  printf '* soft nofile 1048576\n* hard nofile 1048576\nroot soft nofile 1048576\nroot hard nofile 1048576\n' > "$LIMITS_FILE"
  mkdir -p "$(dirname "$SYSTEMD_LIMITS_FILE")"
  printf '[Manager]\nDefaultLimitNOFILE=1048576\n' > "$SYSTEMD_LIMITS_FILE"
  systemctl daemon-reexec
  ok "Лимит дескрипторов 1048576 (limits.d и systemd)"
fi

# ───────────────────────── 6. автообновления ──────────────────────────────
if [[ $DO_EXTRAS -eq 1 ]]; then
  step "Автообновления безопасности"
  if confirm "Включить unattended-upgrades?"; then
    apt_install unattended-upgrades
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
    ok "unattended-upgrades включены (перезагрузку после обновления ядра — вручную)"
  else
    info "Автообновления не включены"
  fi
fi

# ─────────────────────────── 7. SSH: только ключи ─────────────────────────
ssh_effective() { sshd -T 2>/dev/null | awk -v k="$1" '$1==k{print $2}'; }
if [[ $HARDEN_SSH -eq 1 ]]; then
  step "SSH: вход только по ключу"
  keys=0
  for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [[ -s "$f" ]] || continue
    n="$(grep -cv '^[[:space:]]*\(#\|$\)' "$f" || true)"
    keys=$(( keys + ${n:-0} ))
  done
  if (( keys == 0 )); then
    warn "В authorized_keys нет ключей — пропускаю, иначе вы потеряете доступ."
    warn "Сначала на своём компьютере: ssh-copy-id root@<IP>, затем повторите с --harden-ssh"
  else
    install -d -m 0755 /etc/ssh/sshd_config.d
    [[ -e "$SSHD_DROPIN" ]] && cp -a "$SSHD_DROPIN" "$SSHD_DROPIN.bak.$(date +%Y%m%d%H%M%S)"
    cat > "$SSHD_DROPIN" <<'EOF'
# Создано TGweb harden.sh --harden-ssh: вход только по ключу.
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
MaxAuthTries 3
EOF
    if ! sshd -t 2>/dev/null; then
      rm -f "$SSHD_DROPIN"
      warn "sshd -t не принял конфигурацию — изменения откачены, SSH не тронут"
    else
      systemctl reload ssh 2>/dev/null || systemctl reload sshd
      pw="$(ssh_effective passwordauthentication)"; rl="$(ssh_effective permitrootlogin)"
      if [[ "$pw" == "no" && "$rl" != "yes" ]]; then
        ok "Пароли отключены ($keys ключ(ей)); passwordauthentication=$pw, permitrootlogin=$rl"
        warn "НЕ закрывайте эту сессию, пока не проверите вход по ключу в новом окне."
      else
        warn "sshd всё ещё: passwordauthentication=$pw, permitrootlogin=$rl. Значение задаёт:"
        grep -rniE '^[[:space:]]*(PasswordAuthentication|PermitRootLogin)[[:space:]]+yes' \
          /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null | sed 's/^/       /' || true
        warn "(вероятно, Match-блок). Исправьте вручную и проверьте: sshd -T | grep -E 'password|rootlogin'"
      fi
    fi
  fi
fi

# ─────────────────────────────── итог ────────────────────────────────────
step "Итог"
printf '  CC/qdisc   : %s / %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo ?)" \
  "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo ?)"
printf '  IPv6       : %s\n' "$( [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)" == 1 ]] && echo отключён || echo включён )"
printf '  conntrack  : max %s, buckets %s\n' "$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo ?)" \
  "$(cat /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || echo ?)"
printf '  nofile     : %s\n' "$(systemctl show -p DefaultLimitNOFILE --value 2>/dev/null || echo ?)"
printf '  swap       : %s МБ\n' "$(free -m | awk '/^Swap:/{print $2}')"
printf '  ufw        : %s\n' "$(ufw status 2>/dev/null | head -n1 | sed 's/Status: //')"
printf '  fail2ban   : %s\n' "$(systemctl is-active fail2ban 2>/dev/null || true)"
printf '  ssh        : password=%s, rootlogin=%s\n' "$(ssh_effective passwordauthentication)" "$(ssh_effective permitrootlogin)"
printf '\n  Слушают снаружи (не loopback):\n'
ss -lntuH 2>/dev/null | awk '{print $1, $5}' \
  | grep -vE ' (127\.[0-9.]+|\[::1\]|::1):' | sort -u | sed 's/^/    /' || true
printf '  %s(2398/8888 MTProxy закрыты nftables-таблицей tproxy_backend; остальное — ufw)%s\n' "$DIM" "$OFF"

cat <<EOF

  Проверить в любой момент:
    ufw status verbose
    fail2ban-client status sshd
    fail2ban-client set sshd unbanip <IP>        # разбанить
    sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc

${YELLOW}  Не закрывайте эту сессию,${OFF} пока не проверите вход вторым окном:
    ssh -p ${ssh_ports[0]} $(id -un)@<адрес сервера>

EOF
