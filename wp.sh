#!/bin/bash

LOG_FILE="/var/log/wp_plugin_cleanup.log"
SELECTED_PLUGIN=""

function log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

function check_root() {
    if [ "$EUID" -ne 0 ]; then
        log "❌ Скрипт должен запускаться от root!"
        exit 1
    fi
}

function install_wp_cli() {
    if ! command -v wp &> /dev/null; then
        log "📦 WP-CLI не найден. Устанавливаю..."
        curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
        chmod +x wp-cli.phar
        mv wp-cli.phar /usr/local/bin/wp
        log "✅ WP-CLI установлен."
    else
        log "✅ WP-CLI уже установлен."
    fi
}

function scan_all_plugins() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🔍 Сканирование всех плагинов на всех сайтах" >> "$LOG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🔍 Сканирование всех плагинов на всех сайтах"
    
    declare -A PLUGIN_SITES
    declare -A PLUGIN_COUNT
    
    # Проверяем, что команда v-list-users доступна
    if ! command -v v-list-users &> /dev/null; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ Команда v-list-users не найдена. Возможно, HestiaCP не установлен." >> "$LOG_FILE"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ Команда v-list-users не найдена. Возможно, HestiaCP не установлен."
        TEMP_FILE=$(mktemp)
        echo "$TEMP_FILE"
        return
    fi
    
    HESTIA_USERS=$(v-list-users plain | awk '{print $1}')
    if [ -z "$HESTIA_USERS" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Пользователи HestiaCP не найдены" >> "$LOG_FILE"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Пользователи HestiaCP не найдены"
        TEMP_FILE=$(mktemp)
        echo "$TEMP_FILE"
        return
    fi
    
    SITES_SCANNED=0
    PLUGINS_FOUND=0
    
    for USER in $HESTIA_USERS; do
        DOMAINS=$(v-list-web-domains "$USER" plain | awk '{print $1}')
        for DOMAIN in $DOMAINS; do
            SITES_SCANNED=$((SITES_SCANNED + 1))
            WEB_ROOT=$(v-list-web-domain "$USER" "$DOMAIN" plain | grep '^HOMEDIR=' | cut -d '=' -f2)/$DOMAIN/public_html
            if [ -d "$WEB_ROOT" ] && [ -d "$WEB_ROOT/wp-content/plugins" ]; then
                PLUGINS=$(ls "$WEB_ROOT/wp-content/plugins/" 2>/dev/null)
                for PLUGIN in $PLUGINS; do
                    if [ -d "$WEB_ROOT/wp-content/plugins/$PLUGIN" ]; then
                        PLUGIN_SITES["$PLUGIN"]="${PLUGIN_SITES[$PLUGIN]} $DOMAIN"
                        PLUGIN_COUNT["$PLUGIN"]=$((PLUGIN_COUNT[$PLUGIN] + 1))
                        PLUGINS_FOUND=$((PLUGINS_FOUND + 1))
                    fi
                done
            fi
        done
    done
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 📊 Просканировано $SITES_SCANNED сайтов, найдено $PLUGINS_FOUND установок плагинов" >> "$LOG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 📊 Просканировано $SITES_SCANNED сайтов, найдено $PLUGINS_FOUND установок плагинов"
    
    # Сохраняем результаты в временный файл
    TEMP_FILE=$(mktemp)
    
    # Проверяем, есть ли плагины
    if [ ${#PLUGIN_COUNT[@]} -eq 0 ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Плагины не найдены на сайтах" >> "$LOG_FILE"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Плагины не найдены на сайтах"
        echo "$TEMP_FILE"
        return
    fi
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 📊 Найдено ${#PLUGIN_COUNT[@]} уникальных плагинов" >> "$LOG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 📊 Найдено ${#PLUGIN_COUNT[@]} уникальных плагинов"
    
    for PLUGIN in "${!PLUGIN_COUNT[@]}"; do
        echo "$PLUGIN|${PLUGIN_COUNT[$PLUGIN]}|${PLUGIN_SITES[$PLUGIN]}" >> "$TEMP_FILE"
    done
    
    # Сортируем по количеству установок
    sort -t'|' -k2 -nr "$TEMP_FILE" > "$TEMP_FILE.sorted"
    mv "$TEMP_FILE.sorted" "$TEMP_FILE"
    
    echo "$TEMP_FILE"
}

function show_plugins_menu() {
    echo ""
    echo "========= Список всех плагинов на всех сайтах ========="
    
    # Сканируем плагины и сохраняем результат
    TEMP_FILE=$(scan_all_plugins)
    
    # Проверяем, что файл существует и не пустой
    if [ ! -f "$TEMP_FILE" ] || [ ! -s "$TEMP_FILE" ]; then
        echo "❌ Плагины не найдены на сайтах"
        rm -f "$TEMP_FILE"
        return
    fi
    
    PLUGIN_LIST=()
    PLUGIN_INFO=()
    
    while IFS='|' read -r PLUGIN COUNT SITES; do
        PLUGIN_LIST+=("$PLUGIN")
        PLUGIN_INFO+=("$COUNT|$SITES")
    done < "$TEMP_FILE"
    
    if [ ${#PLUGIN_LIST[@]} -eq 0 ]; then
        echo "❌ Плагины не найдены на сайтах"
        rm -f "$TEMP_FILE"
        return
    fi
    
    for i in "${!PLUGIN_LIST[@]}"; do
        PLUGIN="${PLUGIN_LIST[$i]}"
        INFO="${PLUGIN_INFO[$i]}"
        COUNT=$(echo "$INFO" | cut -d'|' -f1)
        SITES=$(echo "$INFO" | cut -d'|' -f2-)
        
        printf "%2d) %-40s [%d сайтов]\n" $((i+1)) "$PLUGIN" "$COUNT"
    done
    
    echo "0) Вернуться в главное меню"
    echo "========================================================"
    echo -n "Выберите плагин [0-${#PLUGIN_LIST[@]}]: "
    
    read -r CHOICE
    
    if [ "$CHOICE" = "0" ]; then
        rm -f "$TEMP_FILE"
        return
    fi
    
    if [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le ${#PLUGIN_LIST[@]} ]; then
        SELECTED_PLUGIN="${PLUGIN_LIST[$((CHOICE-1))]}"
        INFO="${PLUGIN_INFO[$((CHOICE-1))]}"
        COUNT=$(echo "$INFO" | cut -d'|' -f1)
        SITES=$(echo "$INFO" | cut -d'|' -f2-)
        
        echo ""
        echo "✅ Выбран плагин: $SELECTED_PLUGIN"
        echo "📊 Установлен на $COUNT сайтах:"
        echo "$SITES" | tr ' ' '\n' | sed 's/^/   - /'
        echo ""
        
        show_plugin_actions_menu
    else
        echo "❗ Неверный выбор. Попробуйте снова."
    fi
    
    rm -f "$TEMP_FILE"
}

function show_plugin_actions_menu() {
    echo "========= Действия с плагином '$SELECTED_PLUGIN' ========="
    echo "1) Деактивировать плагин на всех сайтах"
    echo "2) Удалить плагин со всех сайтов"
    echo "3) Показать статус плагина на всех сайтах"
    echo "4) Вернуться к списку плагинов"
    echo "5) Вернуться в главное меню"
    echo "========================================================"
    echo -n "Выберите действие [1-5]: "
    
    read -r ACTION
    case $ACTION in
        1) deactivate_plugin ;;
        2) remove_plugin ;;
        3) show_plugin_status ;;
        4) show_plugins_menu ;;
        5) return ;;
        *) echo "❗ Неверный выбор. Попробуйте снова." ;;
    esac
}

function show_plugin_status() {
    if [ -z "$SELECTED_PLUGIN" ]; then
        echo "❌ Плагин не выбран"
        return
    fi
    
    log "🔍 Проверка статуса плагина '$SELECTED_PLUGIN'"
    HESTIA_USERS=$(v-list-users plain | awk '{print $1}')
    for USER in $HESTIA_USERS; do
        DOMAINS=$(v-list-web-domains "$USER" plain | awk '{print $1}')
        for DOMAIN in $DOMAINS; do
            WEB_ROOT=$(v-list-web-domain "$USER" "$DOMAIN" plain | grep '^HOMEDIR=' | cut -d '=' -f2)/$DOMAIN/public_html
            if [ -d "$WEB_ROOT/wp-content/plugins/$SELECTED_PLUGIN" ]; then
                STATUS=$(sudo -u "$USER" wp --path="$WEB_ROOT" plugin status "$SELECTED_PLUGIN" 2>/dev/null | grep "Status:" | cut -d':' -f2 | xargs)
                if [ "$STATUS" = "Active" ]; then
                    log "🟢 [$DOMAIN] Плагин активен"
                else
                    log "🔴 [$DOMAIN] Плагин неактивен"
                fi
            else
                log "⏭️ [$DOMAIN] Плагин не установлен"
            fi
        done
    done
}

function deactivate_plugin() {
    if [ -z "$SELECTED_PLUGIN" ]; then
        echo "❌ Плагин не выбран"
        return
    fi
    
    log "🔧 Деактивация плагина '$SELECTED_PLUGIN' со всех сайтов"
    HESTIA_USERS=$(v-list-users plain | awk '{print $1}')
    for USER in $HESTIA_USERS; do
        DOMAINS=$(v-list-web-domains "$USER" plain | awk '{print $1}')
        for DOMAIN in $DOMAINS; do
            WEB_ROOT=$(v-list-web-domain "$USER" "$DOMAIN" plain | grep '^HOMEDIR=' | cut -d '=' -f2)/$DOMAIN/public_html
            if [ -d "$WEB_ROOT/wp-content/plugins/$SELECTED_PLUGIN" ]; then
                log "🔧 [$DOMAIN] Деактивация плагина"
                if sudo -u "$USER" wp --path="$WEB_ROOT" plugin deactivate "$SELECTED_PLUGIN" 2>&1 | sudo tee -a "$LOG_FILE" > /dev/null; then
                    log "✅ [$DOMAIN] Плагин деактивирован"
                else
                    log "❌ [$DOMAIN] Ошибка при деактивации"
                fi
            fi
        done
    done
}

function remove_plugin() {
    if [ -z "$SELECTED_PLUGIN" ]; then
        echo "❌ Плагин не выбран"
        return
    fi
    
    echo "⚠️  ВНИМАНИЕ: Вы собираетесь удалить плагин '$SELECTED_PLUGIN' со всех сайтов!"
    echo -n "Продолжить? (y/N): "
    read -r CONFIRM
    
    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
        echo "❌ Операция отменена"
        return
    fi
    
    log "🧨 Удаление плагина '$SELECTED_PLUGIN' со всех сайтов"
    HESTIA_USERS=$(v-list-users plain | awk '{print $1}')
    for USER in $HESTIA_USERS; do
        DOMAINS=$(v-list-web-domains "$USER" plain | awk '{print $1}')
        for DOMAIN in $DOMAINS; do
            WEB_ROOT=$(v-list-web-domain "$USER" "$DOMAIN" plain | grep '^HOMEDIR=' | cut -d '=' -f2)/$DOMAIN/public_html
            if [ -d "$WEB_ROOT/wp-content/plugins/$SELECTED_PLUGIN" ]; then
                log "🔧 [$DOMAIN] Деактивация и удаление"
                if sudo -u "$USER" wp --path="$WEB_ROOT" plugin deactivate "$SELECTED_PLUGIN" 2>&1 | sudo tee -a "$LOG_FILE" > /dev/null && \
                   sudo -u "$USER" wp --path="$WEB_ROOT" plugin delete "$SELECTED_PLUGIN" 2>&1 | sudo tee -a "$LOG_FILE" > /dev/null; then
                    log "✅ [$DOMAIN] Плагин удалён"
                else
                    log "❌ [$DOMAIN] Ошибка при удалении"
                fi
            fi
        done
    done
}

function show_main_menu() {
    echo ""
    echo "========= Главное меню управления плагинами WordPress ========="
    echo "1) Установить WP-CLI"
    echo "2) Показать список всех плагинов"
    echo "3) Выход"
    echo "================================================================"
    echo -n "Выберите действие [1-3]: "
}

check_root
install_wp_cli

while true; do
    show_main_menu
    read -r CHOICE
    case $CHOICE in
        1) install_wp_cli ;;
        2) show_plugins_menu ;;
        3) log "🚪 Выход из скрипта"; exit 0 ;;
        *) echo "❗ Неверный выбор. Попробуйте снова." ;;
    esac
done
