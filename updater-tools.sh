#!/usr/bin/env bash
# ==============================================================================
#  UPDATER TOOLS - Automated Server Maintenance with Anti-Hang IPv6 Fallback
# ==============================================================================
#  GitHub: https://github.com/winq1337/updater-tools
#  License: MIT
# ==============================================================================

set -Eeuo pipefail

# --- Colors & Terminal Output ---
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    readonly C_RESET="$(tput sgr0)"
    readonly C_BOLD="$(tput bold)"
    readonly C_DIM="$(tput dim)"
    readonly C_GREEN="$(tput setaf 2)"
    readonly C_YELLOW="$(tput setaf 3)"
    readonly C_RED="$(tput setaf 1)"
    readonly C_BLUE="$(tput setaf 4)"
    readonly C_CYAN="$(tput setaf 6)"
    readonly C_MAGENTA="$(tput setaf 5)"
else
    readonly C_RESET="" C_BOLD="" C_DIM="" C_GREEN="" C_YELLOW="" C_RED="" C_BLUE="" C_CYAN="" C_MAGENTA=""
fi

readonly BADGE_OK="${C_GREEN}[  OK  ]${C_RESET}"
readonly BADGE_WARN="${C_YELLOW}[ WARN ]${C_RESET}"
readonly BADGE_FAIL="${C_RED}[ FAIL ]${C_RESET}"
readonly BADGE_INFO="${C_BLUE}[ INFO ]${C_RESET}"
readonly BADGE_RETRY="${C_YELLOW}[ RETRY]${C_RESET}"

readonly LOG_FILE="/var/log/updater-tools.log"
trap 'tput cnorm 2>/dev/null || true' EXIT SIGINT SIGTERM

DRY_RUN=0
VERBOSE=0
SKIP_BACKUP=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dry-run) DRY_RUN=1; shift ;;
        -v|--verbose) VERBOSE=1; shift ;;
        -b|--no-backup) SKIP_BACKUP=1; shift ;;
        -h|--help)
            echo "Использование: $0 [ОПЦИИ]"
            echo "  -d, --dry-run     Тестовый запуск без внесения изменений"
            echo "  -v, --verbose     Вывод подробного отладочного потока"
            echo "  -b, --no-backup   Пропустить создание бэкапа конфигураций"
            echo "  -h, --help        Показать справку"
            exit 0
            ;;
        *) echo "Неизвестный параметр: $1"; exit 1 ;;
    esac
done

log() {
    local level="${2:-INFO}"
    local msg="$1"
    local clean_msg
    clean_msg="$(echo -e "$msg" | sed -r 's/\x1B\[[0-9;]*[a-zA-Z]//g')"
    printf "[%s] [%-5s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$clean_msg" >> "$LOG_FILE"
    if [[ "${VERBOSE}" -eq 1 ]]; then
        printf "  %b[%s]%b %s\n" "${C_DIM}" "$level" "${C_RESET}" "$msg"
    fi
}

# --- Экстренное принудительное переключение на IPv4 ---
force_ipv4_fallback() {
    printf "\n%b %bОбнаружено зависание сети APT! Принудительно отключаем IPv6 и переводим на IPv4...%b\n" \
        "$BADGE_WARN" "${C_YELLOW}${C_BOLD}" "${C_RESET}"
    log "Triggered IPv6 auto-disable and switched APT to pure IPv4" "WARN"

    # 1. Принудительный IPv4 в конфигурации APT
    echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4
    echo 'Acquire::http::Timeout "10";' > /etc/apt/apt.conf.d/99timeouts
    echo 'Acquire::ftp::Timeout "10";' >> /etc/apt/apt.conf.d/99timeouts

    # 2. Временное отключение IPv6 на уровне ядра (для надежности curl/wget/apt)
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true

    # 3. Чистим локи после принудительного убийства зависшего процесса
    release_apt_locks
}

# --- Умное освобождение блокировок APT/DPKG ---
release_apt_locks() {
    local locks=("/var/lib/dpkg/lock" "/var/lib/dpkg/lock-frontend" "/var/lib/apt/lists/lock" "/var/cache/apt/archives/lock")
    systemctl stop unattended-upgrades 2>/dev/null || true

    for lock in "${locks[@]}"; do
        if fuser "$lock" >/dev/null 2>&1; then
            local pids
            pids="$(fuser "$lock" 2>/dev/null || true)"
            log "Процессы держат $lock: $pids. Отправляем SIGTERM..." "WARN"
            fuser -k -TERM "$lock" >/dev/null 2>&1 || true
            sleep 2

            if fuser "$lock" >/dev/null 2>&1; then
                log "Процесс игнорирует SIGTERM. Выполняем жесткий SIGKILL (-9)..." "WARN"
                fuser -k -KILL "$lock" >/dev/null 2>&1 || true
                sleep 1
            fi
        fi
        rm -f "$lock" 2>/dev/null || true
    done

    pkill -9 -f "unattended-upgrade" 2>/dev/null || true
    dpkg --configure -a >> "$LOG_FILE" 2>&1 || true
}

# --- Анимированный раннер с анти-зависанием (Timeout Watchdog) ---
run_task() {
    local label="$1"
    local timeout_sec="${APT_TIMEOUT:-30}"
    shift
    local cmd=("$@")

    if [[ "${DRY_RUN}" -eq 1 ]]; then
        printf "%b %s %b(DRY-RUN)%b\n" "$BADGE_INFO" "$label" "${C_DIM}" "${C_RESET}"
        log "DRY-RUN: ${cmd[*]}"
        return 0
    fi

    tput civis 2>/dev/null || true
    local tmp_out
    tmp_out="$(mktemp)"
    local start_time
    start_time=$(date +%s)

    "${cmd[@]}" >"$tmp_out" 2>&1 &
    local pid=$!
    local spin_chars="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    local idx=0
    local len=${#spin_chars}
    local is_hang=0

    while kill -0 "$pid" 2>/dev/null; do
        local elapsed=$(( $(date +%s) - start_time ))
        
        # Детектор зависания APT (при превышении таймаута)
        if [[ $elapsed -gt $timeout_sec ]]; then
            is_hang=1
            kill -15 "$pid" 2>/dev/null || true
            sleep 1
            kill -9 "$pid" 2>/dev/null || true
            break
        fi

        local char="${spin_chars:idx:1}"
        printf "\r  ${C_CYAN}%s${C_RESET} %s %b(%ds)%b " "$char" "$label" "${C_DIM}" "$elapsed" "${C_RESET}"
        idx=$(((idx + 1) % len))
        sleep 0.08
    done

    wait "$pid" 2>/dev/null || true
    local status=$?
    local duration=$(( $(date +%s) - start_time ))
    tput cnorm 2>/dev/null || true

    # Если сработал детектор зависания — применяем IPv4 фикс и перезапускаем
    if [[ $is_hang -eq 1 ]]; then
        printf "\r%b %s %b(Зависло на %ds! Переключаем на IPv4...)%b\n" "$BADGE_RETRY" "$label" "${C_YELLOW}" "$duration" "${C_RESET}"
        force_ipv4_fallback
        
        printf "  %bПовторная попытка через чистый IPv4...%b\n" "${C_CYAN}" "${C_RESET}"
        start_time=$(date +%s)
        
        "${cmd[@]}" >"$tmp_out" 2>&1 &
        pid=$!
        while kill -0 "$pid" 2>/dev/null; do
            local char="${spin_chars:idx:1}"
            printf "\r  ${C_CYAN}%s${C_RESET} %s [IPv4] " "$char" "$label"
            idx=$(((idx + 1) % len))
            sleep 0.08
        done
        wait "$pid" 2>/dev/null || true
        status=$?
        duration=$(( $(date +%s) - start_time ))
    fi

    if [[ $status -eq 0 ]]; then
        printf "\r%b %s %b(%ds)%b\n" "$BADGE_OK" "$label" "${C_DIM}" "$duration" "${C_RESET}"
        cat "$tmp_out" >> "$LOG_FILE" 2>/dev/null || true
        rm -f "$tmp_out"
        return 0
    else
        printf "\r%b %s %b(%ds - FAILED)%b\n" "$BADGE_FAIL" "$label" "${C_DIM}" "$duration" "${C_RESET}"
        echo -e "${C_RED}─── Лог ошибки: ───────────────────────────────────────${C_RESET}"
        tail -n 10 "$tmp_out"
        echo -e "${C_RED}───────────────────────────────────────────────────────${C_RESET}"
        cat "$tmp_out" >> "$LOG_FILE" 2>/dev/null || true
        rm -f "$tmp_out"
        return $status
    fi
}

print_banner() {
    clear 2>/dev/null || true
    echo -e "${C_CYAN}"
    cat << "BANNER"
  ██╗   ██╗██████╗ ██████╗  █████╗ ████████╗███████╗██████╗     ████████╗ ██████╗  ██████╗ ██╗     ███████╗
  ██║   ██║██╔══██╗██╔══██╗██╔══██╗╚══██╔══╝██╔════╝██╔══██╗    ╚══██╔══╝██╔═══██╗██╔═══██╗██║     ██╔════╝
  ██║   ██║██████╔╝██║  ██║███████║   ██║   █████╗  ██████╔╝       ██║   ██║   ██║██║   ██║██║     ███████╗
  ██║   ██║██╔═══╝ ██║  ██║██╔══██║   ██║   ██╔══╝  ██╔══██╗       ██║   ██║   ██║██║   ██║██║     ╚════██║
  ╚██████╔╝██║     ██████╔╝██║  ██║   ██║   ███████╗██║  ██║       ██║   ╚██████╔╝╚██████╔╝███████╗███████║
   ╚═════╝ ╚═╝     ╚═════╝ ╚═╝  ╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝       ╚═╝    ╚═════╝  ╚═════╝ ╚══════╝╚══════╝
BANNER
    echo -e "${C_RESET}"
    echo -e "${C_DIM}────────────────────────────────────────────────────────────────────────────────────────${C_RESET}"
    printf " %bHost:%b   %-24s %bOS:%b     %s\n" "${C_BOLD}" "${C_RESET}" "$(hostname -f 2>/dev/null || hostname)" "${C_BOLD}" "${C_RESET}" "$(grep -oP '(?<=PRETTY_NAME=")[^"]*' /etc/os-release 2>/dev/null || uname -s)"
    printf " %bKernel:%b %-24s %bUptime:%b %s\n" "${C_BOLD}" "${C_RESET}" "$(uname -r)" "${C_BOLD}" "${C_RESET}" "$(uptime -p 2>/dev/null || uptime | awk '{print $3,$4}')"
    printf " %bLog:%b    %-24s %bIPv6:%b   %s\n" "${C_BOLD}" "${C_RESET}" "$LOG_FILE" "${C_BOLD}" "${C_RESET}" "${C_GREEN}Auto-Fallback Watchdog (25s)${C_RESET}"
    echo -e "${C_DIM}────────────────────────────────────────────────────────────────────────────────────────${C_RESET}\n"
}

# --- Предстартовые проверки ---
preflight_checks() {
    echo -e "${C_BOLD}▶ [1/5] Проверка системы и готовности окружения${C_RESET}"

    if [[ "$EUID" -ne 0 ]]; then
        printf "%b Скрипт должен быть запущен с правами root (sudo)!\n" "$BADGE_FAIL"
        exit 1
    fi

    # Проверка дискового пространства
    local free_kb
    free_kb=$(df -k / | awk 'NR==2 {print $4}')
    if [[ "$free_kb" -lt 2097152 ]]; then
        printf "%b Мало места на диске: свободно %.1f MB (требуется >= 2GB)\n" "$BADGE_FAIL" "$((free_kb / 1024))"
        exit 1
    fi
    printf "%b Свободное место на диске: %.1f GB\n" "$BADGE_OK" "$((free_kb / 1024 / 1024))"

    # Предварительная оптимизация сети APT
    echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4
    echo 'Acquire::http::Timeout "15";' > /etc/apt/apt.conf.d/99timeouts
    printf "%b Настройки таймаутов APT и IPv4 активированы\n" "$BADGE_OK"

    run_task "Проверка и снятие фоновых блокировок dpkg/apt" release_apt_locks
}

# --- Бэкап конфигураций ---
backup_configs() {
    echo -e "\n${C_BOLD}▶ [2/5] Резервное копирование конфигураций перед обновлением${C_RESET}"
    if [[ "$SKIP_BACKUP" -eq 1 ]]; then
        printf "%b Пропущено по флагу --no-backup\n" "$BADGE_INFO"
        return 0
    fi

    local backup_dir="/var/backups/updater-tools"
    local timestamp archive targets=()
    timestamp="$(date +%Y%m%d_%H%M%S)"
    archive="$backup_dir/configs_${timestamp}.tar.gz"

    mkdir -p "$backup_dir"
    for dir in "/etc/nginx" "/etc/apache2" "/etc/php" "/etc/mysql" "/etc/docker" "/etc/letsencrypt"; do
        [[ -d "$dir" ]] && targets+=("$dir")
    done

    if [[ ${#targets[@]} -gt 0 ]]; then
        tar -czf "$archive" "${targets[@]}" 2>/dev/null
        chmod 600 "$archive"
        printf "%b Бэкап создан: %s%s%b\n" "$BADGE_OK" "${C_DIM}" "$archive" "${C_RESET}"
    else
        printf "%b Веб-конфигурации для бэкапа не найдены\n" "$BADGE_INFO"
    fi
    ls -1t "$backup_dir"/configs_*.tar.gz 2>/dev/null | tail -n +8 | xargs -r rm -f
}

# --- Официальные репозитории ---
setup_repos() {
    echo -e "\n${C_BOLD}▶ [3/5] Проверка и подключение официальных репозиториев вендоров${C_RESET}"

    if command -v nginx >/dev/null 2>&1; then
        apt-get install -y curl gnupg2 ca-certificates lsb-release ubuntu-keyring >/dev/null 2>&1 || true
        if [ ! -f /usr/share/keyrings/nginx-archive-keyring.gpg ]; then
            curl -4 -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg 2>/dev/null || true
        fi
        local codename
        codename=$(lsb_release -cs 2>/dev/null || echo "noble")
        echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/ubuntu ${codename} nginx" > /etc/apt/sources.list.d/nginx.list
        cat << 'PREF' > /etc/apt/preferences.d/99nginx
Package: *
Pin: origin nginx.org
Pin: release o=nginx
Pin-Priority: 900
PREF
        printf "%b Репозиторий Nginx настроен на nginx.org (CVE патчи)\n" "$BADGE_OK"
    fi

    if command -v php >/dev/null 2>&1; then
        if ! grep -rq "ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
            apt-get install -y software-properties-common >/dev/null 2>&1 || true
            add-apt-repository -y ppa:ondrej/php >/dev/null 2>&1 || true
            printf "%b Репозиторий PHP PPA Ondřej Surý подключен\n" "$BADGE_OK"
        fi
    fi
}

# --- Основной цикл апгрейда компонентов ---
perform_upgrades() {
    echo -e "\n${C_BOLD}▶ [4/5] Обновление компонентов (с защитой от зависания)${C_RESET}"

    APT_TIMEOUT=25 run_task "Синхронизация списков пакетов (apt update)" apt-get update -qq

    APT_TIMEOUT=180 run_task "Установка системных патчей (apt dist-upgrade)" \
        env DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y -qq \
        -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"

    # 1. NGINX
    if command -v nginx >/dev/null 2>&1; then
        APT_TIMEOUT=60 run_task "Обновление Nginx до последнего релиза" \
            env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" nginx nginx-common
        
        if nginx -t >/dev/null 2>&1; then
            run_task "Полный перезапуск Nginx (сброс уязвимости из памяти)" systemctl restart nginx
            printf "      %bВерсия:%b %s\n" "${C_DIM}" "${C_RESET}" "$(nginx -v 2>&1)"
        else
            printf "%b Ошибка синтаксиса в nginx.conf! Перезапуск отменен.\n" "$BADGE_WARN"
        fi
    fi

    # 2. APACHE
    if command -v apache2 >/dev/null 2>&1; then
        APT_TIMEOUT=60 run_task "Обновление Apache2" \
            env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" apache2 apache2-utils
        
        if apache2ctl configtest >/dev/null 2>&1; then
            run_task "Перезапуск Apache2" systemctl restart apache2
            printf "      %bВерсия:%b %s\n" "${C_DIM}" "${C_RESET}" "$(apache2 -v 2>&1 | head -n 1)"
        fi
    fi

    # 3. PHP & PHP-FPM
    if command -v php >/dev/null 2>&1; then
        local php_pkgs
        php_pkgs=$(dpkg --get-selections | grep -E '^php[0-9.]*' | awk '{print $1}' || true)
        if [[ -n "$php_pkgs" ]]; then
            APT_TIMEOUT=90 run_task "Обновление установленных пакетов PHP" \
                env DEBIAN_FRONTEND=noninteractive apt-get install --only-upgrade -y -qq \
                -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" $php_pkgs
        fi

        local fpm_services
        fpm_services=$(systemctl list-unit-files --type=service 2>/dev/null | grep -E 'php[0-9.]*-fpm' | awk '{print $1}' || true)
        for fpm in $fpm_services; do
            if systemctl is-active --quiet "$fpm"; then
                run_task "Перезапуск службы $fpm" systemctl restart "$fpm"
            fi
        done
        printf "      %bТекущий PHP в CLI:%b %s\n" "${C_DIM}" "${C_RESET}" "$(php -v | head -n 1)"
    fi

    # 4. Сопутствующие сервисы
    if command -v certbot >/dev/null 2>&1; then
        run_task "Проверка SSL-сертификатов Certbot" certbot renew -q --no-random-sleep-on-renew
    fi

    if command -v pm2 >/dev/null 2>&1; then
        run_task "Обновление демона PM2 в памяти" pm2 update
    fi

    if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker; then
        run_task "Очистка неиспользуемого кэша Docker" docker system prune -f
    fi

    run_task "Очистка устаревших пакетов и ядер" apt-get autoremove -y -qq
    systemctl start unattended-upgrades 2>/dev/null || true
}

# --- Финальный аудит ---
audit_and_report() {
    echo -e "\n${C_BOLD}▶ [5/5] Финальный аудит безопасности и сети${C_RESET}"

    if [[ -f /var/run/reboot-required ]]; then
        printf "%b %bТРЕБУЕТСЯ ПЕРЕЗАГРУЗКА СИСТЕМЫ%b (обновлено ядро Linux) -> команда: %breboot%b\n" \
            "$BADGE_WARN" "${C_YELLOW}${C_BOLD}" "${C_RESET}" "${C_BOLD}" "${C_RESET}"
    else
        printf "%b Перезагрузка ядра не требуется\n" "$BADGE_OK"
    fi

    printf "\n%b Активные веб-сокеты (LISTEN):\n" "$BADGE_INFO"
    printf "${C_DIM}%-7s %-25s %-20s %s${C_RESET}\n" "PROTO" "LOCAL ADDRESS" "SERVICE" "PID"

    if command -v ss >/dev/null 2>&1; then
        ss -tulnp 2>/dev/null | awk 'NR>1 {
            proto=$1; local=$5; proc_info=$7;
            match(proc_info, /users:\(\("([^"]+)",pid=([0-9]+)/, arr);
            pname = arr[1] ? arr[1] : "-";
            pid = arr[2] ? arr[2] : "-";
            if (local ~ /:(80|443|8080|3000|3306|5432|22)$/ || pname ~ /(nginx|apache|php|node|docker)/) {
                printf " %-6s %-25s %-20s %s\n", proto, local, pname, pid;
            }
        }'
    fi

    echo -e "\n${C_GREEN}════════════════════════════════════════════════════════════════════════════════════════${C_RESET}"
    echo -e " ${C_BOLD}${C_GREEN}✔ UPDATER TOOLS УСПЕШНО ЗАВЕРШИЛ РАБОТУ!${C_RESET}"
    echo -e " Лог-файл: ${C_CYAN}${LOG_FILE}${C_RESET}"
    echo -e "${C_GREEN}════════════════════════════════════════════════════════════════════════════════════════${C_RESET}\n"
}

# --- Точка входа ---
print_banner
preflight_checks
backup_configs
setup_repos
perform_upgrades
audit_and_report
