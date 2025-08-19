#!/bin/bash

LOG_FILE="/var/log/wp_plugin_cleanup.log"
PLUGIN="all-in-one-wp-security-and-firewall"

function log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
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

function scan_sites() {
    log "🔍 Сканирование сайтов на наличие плагина '$PLUGIN'"
    HESTIA_USERS=$(v-list-users plain | awk '{print $1}')
    for USER in $HESTIA_USERS; do
        DOMAINS=$(v-list-web-domains $USER plain | awk '{print $1}')
        for DOMAIN in $DOMAINS; do
            WEB_ROOT=$(v-list-web-domain $USER $DOMAIN plain | grep '^HOMEDIR=' | cut -d '=' -f2)/$DOMAIN/public_html
            if [ -d "$WEB_ROOT/wp-content/plugins/$PLUGIN" ]; then
                log "📍 [$DOMAIN] Плагин найден"
            else
                log "⏭️ [$DOMAIN] Плагин не найден"
            fi
        done
    done
}

function remove_plugin() {
    log "🧨 Удаление плагина '$PLUGIN' со всех сайтов"
    HESTIA_USERS=$(v-list-users plain | awk '{print $1}')
    for USER in $HESTIA_USERS; do
        DOMAINS=$(v-list-web-domains $USER plain | awk '{print $1}')
        for DOMAIN in $DOMAINS; do
            WEB_ROOT=$(v-list-web-domain $USER $DOMAIN plain | grep '^HOMEDIR=' | cut -d '=' -f2)/$DOMAIN/public_html
            if [ -d "$WEB_ROOT/wp-content/plugins/$PLUGIN" ]; then
                log "🔧 [$DOMAIN] Деактивация и удаление"
                sudo -u $USER wp --path="$WEB_ROOT" plugin deactivate $PLUGIN >> "$LOG_FILE" 2>&1
                sudo -u $USER wp --path="$WEB_ROOT" plugin delete $PLUGIN >> "$LOG_FILE" 2>&1
                log "✅ [$DOMAIN] Плагин удалён"
            fi
        done
    done
}

function dry_run() {
    log "🧪 Dry-run: покажем, где установлен плагин, без удаления"
    scan_sites
}

function drop_aiowps_tables() {
    log "🧹 Удаление таблиц, связанных с '$PLUGIN'"
    HESTIA_USERS=$(v-list-users plain | awk '{print $1}')
    for USER in $HESTIA_USERS; do
        DOMAINS=$(v-list-web-domains $USER plain | awk '{print $1}')
        for DOMAIN in $DOMAINS; do
            WEB_ROOT=$(v-list-web-domain $USER $DOMAIN plain | grep '^HOMEDIR=' | cut -d '=' -f2)/$DOMAIN/public_html
            if [ -f "$WEB_ROOT/wp-config.php" ]; then
                DB_NAME=$(grep DB_NAME "$WEB_ROOT/wp-config.php" | cut -d \' -f4)
                DB_USER=$(grep DB_USER "$WEB_ROOT/wp-config.php" | cut -d \' -f4)
                DB_PASS=$(grep DB_PASSWORD "$WEB_ROOT/wp-config.php" | cut -d \' -f4)
                TABLES=$(mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "SHOW TABLES LIKE 'aiowps_%';" | grep aiowps_)
                for TABLE in $TABLES; do
                    mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "DROP TABLE $TABLE;"
                    log "🗑️ [$DOMAIN] Удалена таблица $TABLE"
                done
            fi
        done
    done
}



function show_menu() {
    echo ""
    echo "========= Меню управления плагином AIOWPS ========="
    echo "1) Установить WP-CLI"
    echo "2) Сканировать сайты на наличие плагина"
    echo "3) Удалить плагин со всех сайтов"
    echo "4) Dry-run (только показать, где установлен)"
    echo "5) Удалить связанные таблицы из MySQL"
    echo "6) Выход"
    echo "===================================================="
    echo -n "Выберите действие [1-6]: "
}

check_root
install_wp_cli

while true; do
    show_menu
    read CHOICE
    case $CHOICE in
        1) install_wp_cli ;;
        2) scan_sites ;;
        3) remove_plugin ;;
        4) dry_run ;;
        5) drop_aiowps_tables ;;
        6) log "🚪 Выход из скрипта"; exit 0 ;;
        *) echo "❗ Неверный выбор. Попробуйте снова." ;;
    esac
done
