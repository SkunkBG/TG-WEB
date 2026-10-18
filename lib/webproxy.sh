# shellcheck shell=bash
#
# TGweb — общие функции для install.sh и status.sh: base path relay и
# клиентские реквизиты WEB-прокси. Подключается через source.
#
# Правила вывода реквизитов повторяют deploy/install.sh из tproxy-server
# (README.md §6, BASE_PATH.md):
#   корень хоста : server = host,        secret в ссылке = hex как есть
#   base path    : server = host/path,   secret в ссылке = base64url(0x70 || secret)
# Вручную в клиенте secret вводится в hex в обоих случаях.

TPROXY_CONFIG="/etc/tproxy-server/config.json"

# tgweb_base_path [config] — base_path из config.json; пусто = корень хоста.
# Тот же sed, что у апстрима при переустановке, чтобы значения совпадали.
tgweb_base_path() {
  local config="${1:-$TPROXY_CONFIG}"
  [[ -r "$config" ]] || return 0
  sed -n 's/.*"base_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$config" | head -n1
}

# tgweb_client_server HOST BASE_PATH — значение поля «server» в клиенте.
tgweb_client_server() {
  if [[ -n "$2" ]]; then printf '%s/%s' "$1" "$2"; else printf '%s' "$1"; fi
}

# tgweb_link_secret SECRET BASE_PATH — secret для ссылки t.me/webproxy.
# Под base path ссылка обязана нести помеченную форму, иначе клиент её отвергнет.
tgweb_link_secret() {
  local secret="$1" base_path="$2"
  if [[ -z "$base_path" ]]; then
    printf '%s' "$secret"
    return
  fi
  # Сырой секрет может содержать NUL, поэтому он идёт только через пайп.
  # shellcheck disable=SC2059
  { printf '\x70'; printf "$(printf %s "$secret" | sed 's/../\\x&/g')"; } \
    | base64 | tr '+/' '-_' | tr -d '=\n'
}

# tgweb_link SCHEME HOST BASE_PATH SECRET — готовая ссылка; SCHEME: https или tg.
tgweb_link() {
  local scheme="$1" server link_secret
  server="$(tgweb_client_server "$2" "$3")"
  link_secret="$(tgweb_link_secret "$4" "$3")"
  if [[ "$scheme" == "tg" ]]; then
    printf 'tg://webproxy?server=%s&secret=%s' "${server//\//%2F}" "$link_secret"
  else
    printf 'https://t.me/webproxy?server=%s&secret=%s' "${server//\//%2F}" "$link_secret"
  fi
}
