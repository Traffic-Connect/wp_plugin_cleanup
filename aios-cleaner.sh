#!/usr/bin/env bash
# aios-cleaner.sh
# Ищет во всех базах таблицы wp_aiowps_* и чистит (TRUNCATE) либо удаляет (DROP).
# Подходит для серверов с HestiaCP. Требует права, позволяющие подключиться к MySQL.
# По умолчанию: dry-run + TRUNCATE.

set -euo pipefail

# ---------- НАСТРОЙКИ ПО УМОЛЧАНИЮ ----------
APPLY=0
MODE="truncate"     # truncate | drop
PATTERN="wp_aiowps_%"
OPTIMIZE=0          # OPTIMIZE TABLE после TRUNCATE (может занять время/IO)
MYSQL_USER=""       # если пусто — попробует подключение без пароля (unix_socket)
MYSQL_PASS=""
DEFAULTS_FILE=""    # путь к my.cnf с кредами, альтернативно MYSQL_USER/PASS
INCLUDE_DBS=""      # через запятую: db1,db2
EXCLUDE_DBS="information_schema,performance_schema,sys,mysql"

usage() {
  cat <<EOF
Usage: $0 [--apply] [--mode truncate|drop] [--pattern 'wp_aiowps_%']
          [--optimize] [--mysql-user USER] [--mysql-pass PASS]
          [--defaults-file /root/.my.cnf] [--include-dbs db1,db2] [--exclude-dbs db3,db4]

По умолчанию: dry-run + --mode truncate + pattern 'wp_aiowps_%'.
Примеры:
  Dry-run (посмотреть план):    $0
  Очистить по всем БД:          $0 --apply
  Полностью удалить таблицы:    $0 --apply --mode drop
  Точнее навести порядок:       $0 --apply --mode truncate --optimize
  С кредами:                    $0 --mysql-user root --mysql-pass 'pass'
  Через my.cnf:                 $0 --defaults-file /root/.my.cnf
  Только эти базы:              $0 --apply --include-dbs displayplus_it_wp,site2_wp
EOF
}

# ---------- ПАРСИНГ АРГУМЕНТОВ ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --mode) MODE="${2:-}"; shift ;;
    --pattern) PATTERN="${2:-}"; shift ;;
    --optimize) OPTIMIZE=1 ;;
    --mysql-user) MYSQL_USER="${2:-}"; shift ;;
    --mysql-pass) MYSQL_PASS="${2:-}"; shift ;;
    --defaults-file) DEFAULTS_FILE="${2:-}"; shift ;;
    --include-dbs) INCLUDE_DBS="${2:-}"; shift ;;
    --exclude-dbs) EXCLUDE_DBS="${2:-}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Неизвестный параметр: $1"; usage; exit 1 ;;
  esac
  shift
done

if [[ "$MODE" != "truncate" && "$MODE" != "drop" ]]; then
  echo "MODE должен быть 'truncate' или 'drop'"; exit 1
fi

# ---------- ПОДКЛЮЧЕНИЕ К MYSQL ----------
MYSQL_OPTS=(--batch --skip-column-names)
if [[ -n "$DEFAULTS_FILE" ]]; then
  MYSQL_OPTS+=(--defaults-file="$DEFAULTS_FILE")
else
  [[ -n "$MYSQL_USER" ]] && MYSQL_OPTS+=(-u "$MYSQL_USER")
  [[ -n "$MYSQL_PASS" ]] && MYSQL_OPTS+=(-p"$MYSQL_PASS")
fi

mysql_query() {
  mysql "${MYSQL_OPTS[@]}" -e "$1"
}

# ---------- ПОЛУЧЕНИЕ СПИСКА БАЗ ----------
IFS=',' read -r -a EXCL_ARR <<< "$EXCLUDE_DBS"
declare -A EXCL_SET; for d in "${EXCL_ARR[@]}"; do EXCL_SET["$d"]=1; done

if [[ -n "$INCLUDE_DBS" ]]; then
  IFS=',' read -r -a DBS <<< "$INCLUDE_DBS"
else
  mapfile -t DBS < <(mysql_query "SHOW DATABASES;")
fi

# Фильтрация системных/исключённых баз
FILTERED_DBS=()
for db in "${DBS[@]}"; do
  [[ -z "$db" ]] && continue
  if [[ -n "${EXCL_SET[$db]:-}" ]]; then
    continue
  fi
  FILTERED_DBS+=("$db")
done

LOG="/var/log/aios-cleaner.log"
mkdir -p "$(dirname "$LOG")"; touch "$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "==============================================="
echo "AIOS Cleaner — $(date)"
echo "Режим: ${APPLY:+APPLY}( $( [[ $APPLY -eq 1 ]] && echo "изменения будут внесены" || echo "dry-run" ) )"
echo "Действие: $MODE"
echo "Паттерн таблиц: $PATTERN"
[[ $OPTIMIZE -eq 1 ]] && echo "После TRUNCATE: OPTIMIZE включен"
echo "Исключённые БД: $EXCLUDE_DBS"
[[ -n "$INCLUDE_DBS" ]] && echo "Ограничение по БД: $INCLUDE_DBS"
echo "Лог: $LOG"
echo "==============================================="

TOTAL_TABLES=0
TOTAL_SIZE_MB=0
AFFECTED_TABLES=0

for DB in "${FILTERED_DBS[@]}"; do
  # Ищем таблицы по паттерну и их размер
  readarray -t ROWS < <(mysql_query "
    SELECT TABLE_NAME, ROUND((DATA_LENGTH+INDEX_LENGTH)/1024/1024,2) AS size_mb
    FROM information_schema.TABLES
    WHERE TABLE_SCHEMA='${DB//\'/\'\'}'
      AND TABLE_NAME LIKE '${PATTERN//\'/\'\'}'
    ORDER BY size_mb DESC;
  ")

  [[ ${#ROWS[@]} -eq 0 ]] && continue

  echo "---- БД: $DB ----"
  for row in "${ROWS[@]}"; do
    TBL="$(echo "$row" | awk '{print $1}')"
    SIZE="$(echo "$row" | awk '{print $2}')"
    [[ -z "$TBL" ]] && continue

    printf "Таблица: %s.%s (≈ %s MB)\n" "$DB" "$TBL" "${SIZE:-0}"
    ((TOTAL_TABLES++)) || true
    TOTAL_SIZE_MB=$(awk -v a="$TOTAL_SIZE_MB" -v b="${SIZE:-0}" 'BEGIN{printf "%.2f", a+b}')

    if [[ $APPLY -eq 1 ]]; then
      case "$MODE" in
        truncate)
          mysql_query "TRUNCATE TABLE \`${DB}\`.\`${TBL}\`;" \
            && echo " → TRUNCATE: OK" \
            || { echo " → TRUNCATE: ERROR"; continue; }
          ((AFFECTED_TABLES++)) || true
          if [[ $OPTIMIZE -eq 1 ]]; then
            mysql_query "OPTIMIZE TABLE \`${DB}\`.\`${TBL}\`;" \
              && echo "   OPTIMIZE: OK" \
              || echo "   OPTIMIZE: ERROR"
          fi
        ;;
        drop)
          mysql_query "DROP TABLE \`${DB}\`.\`${TBL}\`;" \
            && echo " → DROP: OK" \
            || { echo " → DROP: ERROR"; continue; }
          ((AFFECTED_TABLES++)) || true
        ;;
      esac
    else
      echo " → DRY-RUN: было бы '${MODE^^}' этой таблицы"
      ((AFFECTED_TABLES++)) || true
    fi
  done
done

echo "==============================================="
echo "ИТОГО:"
echo "  Найдено таблиц:     $TOTAL_TABLES"
echo "  Совокупный размер:  ${TOTAL_SIZE_MB} MB (до действий)"
echo "  ${APPLY:+Обработано/запланировано}: ${AFFECTED_TABLES}"
echo "Готово."
