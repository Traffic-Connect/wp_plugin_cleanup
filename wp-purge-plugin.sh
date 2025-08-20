#!/usr/bin/env bash
# wp-purge-plugin.sh
# Пройдётся по всем WP в /home/*/web/* и деактивирует/удалит указанный плагин.
# Требует root. Для безопасности по умолчанию — dry-run.

set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 <plugin-slug> [--apply] [--include-private-html]
  <plugin-slug>           Слаг плагина, например: wordfence
  --apply                 Выполнить реальные изменения (по умолчанию: dry-run)
  --include-private-html  Также искать WP в private_html
EOF
}

# ---- ПАРАМЕТРЫ ----
APPLY=0
INCLUDE_PRIVATE=0
PLUGIN_SLUG="${1:-}"
[[ -z "${PLUGIN_SLUG}" || "${PLUGIN_SLUG}" == "--help" || "${PLUGIN_SLUG}" == "-h" ]] && { usage; exit 1; }
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --include-private-html) INCLUDE_PRIVATE=1 ;;
    *) echo "Неизвестный параметр: $1"; usage; exit 1 ;;
  esac
  shift
done

# ---- ПРОВЕРКИ ----
if [[ $EUID -ne 0 ]]; then
  echo "Запустите от root (sudo)."
  exit 1
fi

LOG="/var/log/wp-purge-plugin.log"
mkdir -p "$(dirname "$LOG")"
touch "$LOG"
exec > >(tee -a "$LOG") 2>&1

say() { echo -e "$*"; }
ok()  { say "✅ $*"; }
warn(){ say "⚠️  $*"; }
err() { say "❌ $*"; }

# ---- WP-CLI ----
if ! command -v wp >/dev/null 2>&1; then
  warn "wp-cli не найден. Скачиваю в /usr/local/bin/wp ..."
  curl -fsSL -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
  chmod +x /usr/local/bin/wp
  ok "Установлен wp-cli: $(wp --version 2>/dev/null || true)"
else
  ok "Найден wp-cli: $(wp --version 2>/dev/null || true)"
fi

# Определим пути поиска (Hestia структура)
SEARCH_PATHS=(/home/*/web/*/public_html)
[[ $INCLUDE_PRIVATE -eq 1 ]] && SEARCH_PATHS+=(/home/*/web/*/private_html)

say "Ищу WordPress установки (wp-config.php) в: ${SEARCH_PATHS[*]}"
mapfile -t WP_CONFIGS < <(find "${SEARCH_PATHS[@]}" -maxdepth 2 -type f -name wp-config.php 2>/dev/null | sort)

TOTAL_FOUND=${#WP_CONFIGS[@]}
say "Найдено WP установок: $TOTAL_FOUND"
[[ $TOTAL_FOUND -eq 0 ]] && exit 0

DRYRUN_MSG=$([[ $APPLY -eq 1 ]] && echo "РЕЖИМ: APPLY (изменения будут внесены)" || echo "РЕЖИМ: DRY-RUN (только показ действий)")
say "— $DRYRUN_MSG —"
say "Целевой плагин: $PLUGIN_SLUG"
echo

SUCCESS_CNT=0
SKIP_CNT=0
ERROR_CNT=0

for CFG in "${WP_CONFIGS[@]}"; do
  WP_PATH="$(dirname "$CFG")"
  # Определим владельца папки (важно для прав)
  OWNER="$(stat -c %U "$WP_PATH" 2>/dev/null || echo root)"
  # Некоторые docroot могут быть symlink — норм
  DOMAIN_HINT="$(echo "$WP_PATH" | awk -F'/web/' '{print $2}' | awk -F'/' '{print $1}')" || DOMAIN_HINT="$WP_PATH"

  say "────────────────────────────────────────────────────────"
  say "Сайт: $DOMAIN_HINT"
  say "Путь: $WP_PATH"
  say "Владелец: $OWNER"

  # Проверка установки и наличия плагина
  if ! sudo -u "$OWNER" -H wp --path="$WP_PATH" core is-installed >/dev/null 2>&1; then
    warn "Похоже, это не валидная WP установка. Пропускаю."
    ((SKIP_CNT++)) || true
    continue
  fi

  if ! sudo -u "$OWNER" -H wp --path="$WP_PATH" plugin is-installed "$PLUGIN_SLUG" >/dev/null 2>&1; then
    warn "Плагин '$PLUGIN_SLUG' не установлен здесь. Пропускаю."
    ((SKIP_CNT++)) || true
    continue
  fi

  # Определим multisite
  IS_MS=$(sudo -u "$OWNER" -H wp --path="$WP_PATH" eval 'echo is_multisite() ? "yes" : "no";' 2>/dev/null || echo "no")
  say "Multisite: $IS_MS"

  # Активен ли плагин
  ACTIVE="no"
  if [[ "$IS_MS" == "yes" ]]; then
    if sudo -u "$OWNER" -H wp --path="$WP_PATH" plugin status "$PLUGIN_SLUG" | grep -q "Network active"; then
      ACTIVE="network"
    elif sudo -u "$OWNER" -H wp --path="$WP_PATH" plugin status "$PLUGIN_SLUG" | grep -q "Active"; then
      ACTIVE="site"
    fi
  else
    if sudo -u "$OWNER" -H wp --path="$WP_PATH" plugin is-active "$PLUGIN_SLUG" >/dev/null 2>&1; then
      ACTIVE="site"
    fi
  fi
  say "Статус плагина: $ACTIVE"

  # Деактивация (если активен)
  if [[ "$ACTIVE" != "no" ]]; then
    if [[ $APPLY -eq 1 ]]; then
      if [[ "$ACTIVE" == "network" ]]; then
        sudo -u "$OWNER" -H wp --path="$WP_PATH" plugin deactivate "$PLUGIN_SLUG" --network || { err "Не удалось деактивировать (network)."; ((ERROR_CNT++)) || true; continue; }
      else
        sudo -u "$OWNER" -H wp --path="$WP_PATH" plugin deactivate "$PLUGIN_SLUG" || { err "Не удалось деактивировать."; ((ERROR_CNT++)) || true; continue; }
      fi
      ok "Деактивирован."
    else
      say "→ DRY-RUN: деактивировал(а) бы плагин (${ACTIVE})."
    fi
  else
    say "Плагин уже не активен."
  fi

  # Удаление
  if [[ $APPLY -eq 1 ]]; then
    if sudo -u "$OWNER" -H wp --path="$WP_PATH" plugin delete "$PLUGIN_SLUG"; then
      ok "Удалён."
      ((SUCCESS_CNT++)) || true
    else
      err "Ошибка удаления."
      ((ERROR_CNT++)) || true
    fi
  else
    say "→ DRY-RUN: удалил(а) бы плагин '$PLUGIN_SLUG'."
    ((SUCCESS_CNT++)) || true
  fi
done

say "────────────────────────────────────────────────────────"
say "Готово. Итог:"
say "  Успешных (или планировалось в DRY-RUN): $SUCCESS_CNT"
say "  Пропущено: $SKIP_CNT"
say "  Ошибок: $ERROR_CNT"
say "Лог: $LOG"
