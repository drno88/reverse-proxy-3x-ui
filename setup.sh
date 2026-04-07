#!/bin/bash
# ==============================================================================
# 3x-ui Reverse Proxy Setup
# Nginx + acme.sh (Let's Encrypt) + VLESS (WS / gRPC / XHTTP / Reality)
#
# Supported: Ubuntu 22.04, 24.04 / Debian 12, 13
# Usage:     sudo bash setup.sh
# ==============================================================================

set -euo pipefail

# ── Colors (consistent with 3x-ui installer style) ───────────────────────────
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;34m'
cyan='\033[0;36m'
bold='\033[1m'
dim='\033[2m'
plain='\033[0m'

info()  { echo -e "${green}[✓]${plain} $*"; }
warn()  { echo -e "${yellow}[!]${plain} $*"; }
err()   { echo -e "${red}[✗]${plain} $*"; }
ask()   { echo -e "${blue}[?]${plain} $*"; }
step()  { echo -e "\n${cyan}${bold}── $* ──${plain}\n"; }
die()   { err "$*"; exit 1; }

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Запустите от root: sudo bash setup.sh"

# ── OS detection ──────────────────────────────────────────────────────────────
detect_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
    elif [[ -f /usr/lib/os-release ]]; then
        source /usr/lib/os-release
    else
        die "Не удалось определить ОС (/etc/os-release отсутствует)"
    fi

    release="${ID}"
    os_ver="${VERSION_ID:-unknown}"

    case "$release" in
        ubuntu)
            case "$os_ver" in
                22.04|24.04) ;;
                *) warn "Ubuntu $os_ver не тестировалась, продолжаем..." ;;
            esac
            ;;
        debian)
            case "$os_ver" in
                12|13) ;;
                *) warn "Debian $os_ver не тестировалась, продолжаем..." ;;
            esac
            ;;
        *)
            die "Поддерживаются Ubuntu 22/24 и Debian 12/13. Текущая ОС: $release $os_ver"
            ;;
    esac

    info "ОС: $release $os_ver"
}

# ── Helpers ───────────────────────────────────────────────────────────────────
gen_random_string() {
    local length="${1:-$(( RANDOM % 8 + 5 ))}"  # random 5-12 if no arg
    openssl rand -base64 $(( length * 2 )) | tr -dc 'a-z0-9' | head -c "$length"
}

gen_random_path_len() {
    echo $(( RANDOM % 8 + 5 ))
}

is_domain() {
    [[ "$1" =~ ^([A-Za-z0-9](-*[A-Za-z0-9])*\.)+([A-Za-z]{2,}|xn--[a-z0-9]{2,})$ ]]
}

is_port_valid() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

is_port_in_use() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ss -ltn 2>/dev/null | awk -v p=":${port}" '$4 ~ p {found=1} END {exit !found}' && return 0
    fi
    if command -v netstat &>/dev/null; then
        netstat -lnt 2>/dev/null | awk -v p=":${port} " '$4 ~ p {found=1} END {exit !found}' && return 0
    fi
    if command -v lsof &>/dev/null; then
        lsof -nP -iTCP:"${port}" -sTCP:LISTEN &>/dev/null && return 0
    fi
    return 1
}

# Prompt for a port with default and conflict check
# Usage: read_port VAR_NAME "Description" DEFAULT
read_port() {
    local varname="$1" desc="$2" default="$3" val
    while true; do
        ask "$desc [Enter = $default]:"
        read -r val
        val="${val:-$default}"
        if ! is_port_valid "$val"; then
            err "Некорректный порт: $val (допустимо 1-65535)"
            continue
        fi
        if is_port_in_use "$val"; then
            warn "Порт $val уже занят — выберите другой или убедитесь что это правильный порт"
            ask "Всё равно использовать $val? [y/N]:"
            read -r force
            [[ "${force,,}" =~ ^(y|yes)$ ]] || continue
        fi
        printf -v "$varname" '%s' "$val"
        break
    done
}

# Normalize path: leading slash, no trailing slash, no spaces
normalize_path() {
    local p="${1// /}"
    p="/${p#/}"
    p="${p%/}"
    echo "$p"
}

# confirm "Question text" → returns 0 for yes, 1 for no
confirm() {
    local yn
    ask "$1 [Y/n]:"
    read -r yn
    yn="${yn:-y}"
    [[ "${yn,,}" =~ ^(y|yes)$ ]]
}

# ── Install nginx ─────────────────────────────────────────────────────────────
install_nginx() {
    step "Nginx"
    if command -v nginx &>/dev/null; then
        info "Nginx уже установлен: $(nginx -v 2>&1 | tr -d '\n')"
        systemctl is-active --quiet nginx && info "Сервис nginx запущен" \
            || { warn "Nginx не запущен, запускаем..."; systemctl start nginx; }
        return
    fi

    info "Устанавливаем nginx..."
    wait_dpkg
    apt-get update -qq
    apt-get install -y nginx || die "Не удалось установить nginx"
    systemctl enable --now nginx
    info "Nginx установлен и запущен"
}

# ── Install acme.sh ───────────────────────────────────────────────────────────
install_acme() {
    step "acme.sh (SSL)"
    if command -v ~/.acme.sh/acme.sh &>/dev/null; then
        info "acme.sh уже установлен"
        return
    fi

    info "Устанавливаем acme.sh..."
    curl -fsSL https://get.acme.sh | sh -s email=noreply@"${DOMAIN}" >/dev/null 2>&1 \
        || die "Не удалось установить acme.sh"
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1
    info "acme.sh установлен"
}

# ── Install 3x-ui ─────────────────────────────────────────────────────────────
install_3xui() {
    step "3x-ui"
    if command -v x-ui &>/dev/null \
        || systemctl list-units --full -all 2>/dev/null | grep -q "x-ui.service"; then
        info "3x-ui уже установлен"
        systemctl is-active --quiet x-ui \
            && info "Сервис x-ui запущен" \
            || warn "Сервис x-ui не запущен: systemctl start x-ui"
        return
    fi

    confirm "3x-ui не найден. Установить сейчас?" \
        || { warn "Пропускаем установку 3x-ui"; return; }

    info "Запускаем установщик 3x-ui..."
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) \
        || die "Ошибка при установке 3x-ui"
    info "3x-ui установлен"
}

# ── Obtain SSL certificate via acme.sh ───────────────────────────────────────
get_ssl() {
    step "SSL сертификат для $DOMAIN"

    local cert_dir="/root/cert/${DOMAIN}"
    local cert_file="${cert_dir}/fullchain.pem"
    local key_file="${cert_dir}/privkey.pem"

    CERT_FILE="$cert_file"
    KEY_FILE="$key_file"

    # Already exists?
    if [[ -f "$cert_file" && -f "$key_file" ]]; then
        info "Сертификат для $DOMAIN уже существует: $cert_dir"
        return
    fi

    mkdir -p "$cert_dir"

    warn "Для ACME HTTP-01 challenge порт 80 должен быть доступен из интернета"
    warn "Временно останавливаем nginx..."
    systemctl stop nginx 2>/dev/null || true

    # Set CA
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force >/dev/null 2>&1

    # Issue
    info "Запрашиваем сертификат..."
    ~/.acme.sh/acme.sh --issue \
        -d "${DOMAIN}" \
        --standalone \
        --httpport 80 \
        --force \
        || {
            systemctl start nginx 2>/dev/null || true
            die "Не удалось получить сертификат.\nПроверьте: домен $DOMAIN → IP сервера, порт 80 открыт."
        }

    # Install
    ~/.acme.sh/acme.sh --installcert -d "${DOMAIN}" \
        --key-file   "$key_file" \
        --fullchain-file "$cert_file" \
        --reloadcmd  "systemctl reload nginx" \
        2>&1 || true  # reloadcmd might fail first time, check files instead

    if [[ ! -f "$cert_file" || ! -f "$key_file" ]]; then
        systemctl start nginx 2>/dev/null || true
        die "Файлы сертификата не найдены после установки acme.sh"
    fi

    # Secure permissions
    chmod 600 "$key_file"
    chmod 644 "$cert_file"

    systemctl start nginx 2>/dev/null || true
    info "Сертификат получен: $cert_dir"
    info "Автообновление: acme.sh cron (автоматически настроен)"
}

# ── Write nginx config ────────────────────────────────────────────────────────
write_nginx_config() {
    step "Настройка Nginx"

    local conf_file="/etc/nginx/sites-available/${DOMAIN}.conf"
    local conf_link="/etc/nginx/sites-enabled/${DOMAIN}.conf"

    # Backup existing
    if [[ -f "$conf_file" ]]; then
        local bak="${conf_file}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$conf_file" "$bak"
        warn "Бэкап предыдущего конфига: $bak"
    fi

    # Remove default site (port conflicts)
    if [[ -f /etc/nginx/sites-enabled/default ]]; then
        rm -f /etc/nginx/sites-enabled/default
        warn "Отключили nginx default сайт"
    fi

    cat > "$conf_file" << NGINX_EOF
# ==============================================================================
# 3x-ui Reverse Proxy: ${DOMAIN}
# Generated: $(date)
# Protocols: VLESS+WS | VLESS+gRPC | VLESS+XHTTP | Panel
# Note: VLESS+Reality работает напрямую через Xray (порт ${REALITY_PORT}), без Nginx
# ==============================================================================

# ── HTTP → HTTPS redirect ──────────────────────────────────────────────────────
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

# ── HTTPS ─────────────────────────────────────────────────────────────────────
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    # ── SSL ──────────────────────────────────────────────────────────────────
    ssl_certificate     ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
    # ── Security headers ─────────────────────────────────────────────────────
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy no-referrer always;

    # ── Logs ─────────────────────────────────────────────────────────────────
    access_log /var/log/nginx/${DOMAIN}_access.log;
    error_log  /var/log/nginx/${DOMAIN}_error.log;

    # ── 3x-ui Panel: ${PANEL_PATH} ───────────────────────────────────────────
    # ВАЖНО: В 3x-ui → Настройки панели → URI Path → установите: ${PANEL_PATH}
    location ${PANEL_PATH}/ {
        proxy_pass         http://127.0.0.1:${PANEL_PORT}/;
        proxy_http_version 1.1;
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_read_timeout 86400;
    }

    # ── VLESS + WebSocket: ${WS_PATH} ────────────────────────────────────────
    # Xray inbound → port: ${WS_PORT}  transport: ws  path: ${WS_PATH}  TLS: none
    location ${WS_PATH} {
        proxy_pass         http://127.0.0.1:${WS_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }

    # ── VLESS + gRPC: /${GRPC_SERVICE} ───────────────────────────────────────
    # Xray inbound → port: ${GRPC_PORT}  transport: grpc  serviceName: ${GRPC_SERVICE}  TLS: none
    location /${GRPC_SERVICE} {
        grpc_pass          grpc://127.0.0.1:${GRPC_PORT};
        grpc_set_header    Host \$host;
        grpc_set_header    X-Real-IP \$remote_addr;
        grpc_read_timeout  86400s;
        grpc_send_timeout  86400s;
        grpc_buffer_size   64k;
        client_max_body_size 0;
    }

    # ── VLESS + XHTTP (SplitHTTP): ${XHTTP_PATH} ─────────────────────────────
    # Xray inbound → port: ${XHTTP_PORT}  transport: xhttp  path: ${XHTTP_PATH}  TLS: none
    location ${XHTTP_PATH} {
        proxy_pass              http://127.0.0.1:${XHTTP_PORT};
        proxy_http_version      1.1;
        proxy_set_header        Host \$host;
        proxy_set_header        X-Real-IP \$remote_addr;
        proxy_set_header        X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header        X-Forwarded-Proto \$scheme;
        proxy_buffering         off;
        proxy_cache             off;
        proxy_request_buffering off;
        proxy_read_timeout      86400;
        proxy_send_timeout      86400;
        client_max_body_size    0;
        chunked_transfer_encoding on;
    }

    # ── Default: всё остальное → 404 ─────────────────────────────────────────
    location / {
        return 404;
    }
}
NGINX_EOF

    # Enable site
    ln -sf "$conf_file" "$conf_link"

    # Test config
    nginx -t 2>&1 || {
        err "Ошибка в конфиге Nginx. Детали выше."
        die "Исправьте конфиг: $conf_file"
    }

    systemctl reload nginx
    info "Nginx настроен: $conf_file"
}

# ── Enable BBR ────────────────────────────────────────────────────────────────
enable_bbr() {
    step "TCP BBR"

    local sysctl_conf="/etc/sysctl.conf"
    local changed=0

    if grep -q "net.core.default_qdisc" "$sysctl_conf" 2>/dev/null; then
        # Update in place if value differs
        if ! grep -q "net.core.default_qdisc = fq" "$sysctl_conf"; then
            sed -i 's/^net.core.default_qdisc.*/net.core.default_qdisc = fq/' "$sysctl_conf"
            changed=1
        fi
    else
        echo "net.core.default_qdisc = fq" >> "$sysctl_conf"
        changed=1
    fi

    if grep -q "net.ipv4.tcp_congestion_control" "$sysctl_conf" 2>/dev/null; then
        if ! grep -q "net.ipv4.tcp_congestion_control = bbr" "$sysctl_conf"; then
            sed -i 's/^net.ipv4.tcp_congestion_control.*/net.ipv4.tcp_congestion_control = bbr/' "$sysctl_conf"
            changed=1
        fi
    else
        echo "net.ipv4.tcp_congestion_control = bbr" >> "$sysctl_conf"
        changed=1
    fi

    if [[ $changed -eq 1 ]]; then
        sysctl -p &>/dev/null
        info "BBR включён и применён"
    else
        info "BBR уже был настроен"
    fi

    # Verify
    local qdisc cc
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
    info "Проверка: qdisc=$qdisc  congestion_control=$cc"
}

# ── Disable UFW ───────────────────────────────────────────────────────────────
disable_ufw() {
    step "UFW"
    if ! command -v ufw &>/dev/null; then
        info "UFW не установлен, пропускаем"
        return
    fi

    if ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw disable
        info "UFW отключён"
    else
        info "UFW уже был неактивен"
    fi
}

# Wait for dpkg lock to be released (unattended-upgrades can hold it)
wait_dpkg() {
    local i=0
    while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock &>/dev/null 2>&1; do
        (( i == 0 )) && warn "dpkg/apt занят другим процессом, ждём освобождения..."
        sleep 5
        (( i++ ))
        (( i > 36 )) && die "dpkg lock не освободился за 3 минуты"
    done
}

# ── Install & configure fail2ban ──────────────────────────────────────────────
install_fail2ban() {
    step "fail2ban"

    if ! command -v fail2ban-client &>/dev/null; then
        info "Устанавливаем fail2ban..."
        wait_dpkg
        apt-get install -y fail2ban || die "Не удалось установить fail2ban"
    else
        info "fail2ban уже установлен: $(fail2ban-client version 2>&1 | head -1)"
    fi

    # Write jail config for nginx + 3x-ui panel
    cat > /etc/fail2ban/jail.d/3xui-nginx.conf << F2B_EOF
# fail2ban jails for 3x-ui + nginx
# Generated: $(date)

[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
banaction = iptables-multiport

# Nginx: слишком много 4xx ошибок (сканеры, перебор путей)
[nginx-4xx]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/${DOMAIN}_access.log
           /var/log/nginx/*_access.log
filter   = nginx-4xx
maxretry = 20
findtime = 5m
bantime  = 30m

# Nginx: брутфорс панели (401/403 на пути панели)
[nginx-panel-auth]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/${DOMAIN}_access.log
filter   = nginx-panel-auth
maxretry = 10
findtime = 5m
bantime  = 2h
F2B_EOF

    # Filter: nginx 4xx
    cat > /etc/fail2ban/filter.d/nginx-4xx.conf << 'FILTER_EOF'
[Definition]
failregex = ^<HOST> -.*"(GET|POST|HEAD|PUT|DELETE|OPTIONS).*" (400|401|403|404|405) (?!200|301|302)
ignoreregex = \.(?:css|js|ico|png|jpg|gif|svg|woff|woff2|ttf|eot)(\?.*)?$
FILTER_EOF

    # Filter: panel brute force
    cat > /etc/fail2ban/filter.d/nginx-panel-auth.conf << FILTER_EOF
[Definition]
failregex = ^<HOST> -.*"(GET|POST) ${PANEL_PATH}.*" (401|403)
ignoreregex =
FILTER_EOF

    systemctl enable --now fail2ban
    systemctl restart fail2ban

    # Give it a moment to start
    sleep 2
    if fail2ban-client status &>/dev/null; then
        info "fail2ban запущен"
        fail2ban-client status nginx-4xx &>/dev/null      && info "Jail nginx-4xx активен"
        fail2ban-client status nginx-panel-auth &>/dev/null && info "Jail nginx-panel-auth активен"
    else
        warn "fail2ban запущен, но статус не удалось проверить (это нормально при первом старте)"
    fi
}

# ── Interactive questions ─────────────────────────────────────────────────────
ask_questions() {
    step "Настройка параметров"

    # ── Domain ──────────────────────────────────────────────────────────────
    echo -e "${dim}Домен должен иметь A-запись указывающую на IP этого сервера.${plain}"
    while true; do
        ask "Введите домен (например: vpn.example.com):"
        read -r DOMAIN
        DOMAIN="${DOMAIN// /}"
        if [[ -z "$DOMAIN" ]]; then
            err "Домен не может быть пустым"
            continue
        fi
        if ! is_domain "$DOMAIN"; then
            err "Некорректный домен: $DOMAIN"
            continue
        fi
        break
    done
    echo ""

    # ── Panel ────────────────────────────────────────────────────────────────
    local default_panel="$(gen_random_string "$(gen_random_path_len)")"
    echo -e "${dim}Советы для пути панели: /cloud  /files  /inbox  /webdav  /storage  /portal${plain}"
    ask "Путь к панели 3x-ui [Enter = /$default_panel]:"
    read -r PANEL_PATH
    PANEL_PATH=$(normalize_path "${PANEL_PATH:-$default_panel}")

    read_port PANEL_PORT "Порт панели 3x-ui (проверьте в настройках)" "2053"
    echo ""

    # ── WebSocket ────────────────────────────────────────────────────────────
    local default_ws="$(gen_random_string "$(gen_random_path_len)")"
    echo -e "${dim}Советы для WS пути: /chat  /live  /stream  /io  /connect${plain}"
    ask "Путь для VLESS+WebSocket [Enter = /$default_ws]:"
    read -r WS_PATH
    WS_PATH=$(normalize_path "${WS_PATH:-$default_ws}")

    read_port WS_PORT "Xray inbound порт для VLESS+WS" "10001"
    echo ""

    # ── gRPC ─────────────────────────────────────────────────────────────────
    local default_grpc="$(gen_random_string "$(gen_random_path_len)")"
    echo -e "${dim}gRPC serviceName используется как URL путь. Примеры: stream  Chat  Api  Sync${plain}"
    ask "serviceName для VLESS+gRPC [Enter = $default_grpc]:"
    read -r GRPC_SERVICE
    GRPC_SERVICE="${GRPC_SERVICE:-$default_grpc}"
    GRPC_SERVICE="${GRPC_SERVICE// /}"  # no spaces

    read_port GRPC_PORT "Xray inbound порт для VLESS+gRPC" "10002"
    echo ""

    # ── XHTTP ────────────────────────────────────────────────────────────────
    local default_xhttp="$(gen_random_string "$(gen_random_path_len)")"
    echo -e "${dim}Советы для XHTTP пути: /download  /assets  /cdn  /update  /sync${plain}"
    ask "Путь для VLESS+XHTTP [Enter = /$default_xhttp]:"
    read -r XHTTP_PATH
    XHTTP_PATH=$(normalize_path "${XHTTP_PATH:-$default_xhttp}")

    read_port XHTTP_PORT "Xray inbound порт для VLESS+XHTTP" "10003"
    echo ""

    # ── Reality ──────────────────────────────────────────────────────────────
    echo -e "${dim}Reality работает напрямую через Xray, без Nginx. Любой свободный порт.${plain}"
    read_port REALITY_PORT "Порт для VLESS+Reality (прямое подключение)" "8443"
    echo ""

    # ── Summary ──────────────────────────────────────────────────────────────
    echo -e "${cyan}${bold}┌─────────────────────────────────────────────────────────┐${plain}"
    echo -e "${cyan}${bold}│                  Проверьте настройки                   │${plain}"
    echo -e "${cyan}${bold}└─────────────────────────────────────────────────────────┘${plain}"
    echo ""
    echo -e "  Домен:           ${bold}$DOMAIN${plain}"
    echo -e "  Панель:          ${bold}https://$DOMAIN$PANEL_PATH/${plain}  →  localhost:$PANEL_PORT"
    echo -e "  VLESS+WS:        ${bold}$WS_PATH${plain}  →  localhost:$WS_PORT"
    echo -e "  VLESS+gRPC:      serviceName=${bold}$GRPC_SERVICE${plain}  →  localhost:$GRPC_PORT"
    echo -e "  VLESS+XHTTP:     ${bold}$XHTTP_PATH${plain}  →  localhost:$XHTTP_PORT"
    echo -e "  VLESS+Reality:   прямой порт ${bold}$REALITY_PORT${plain} (без Nginx)"
    echo ""

    confirm "Продолжить установку?" || die "Установка отменена"
}

# ── Final instructions ────────────────────────────────────────────────────────
show_instructions() {
    echo ""
    echo -e "${green}${bold}╔══════════════════════════════════════════════════════════════╗"
    echo -e "║                   Установка завершена!                       ║"
    echo -e "╚══════════════════════════════════════════════════════════════╝${plain}"
    echo ""

    echo -e "${bold}━━━ Доступ к панели ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${plain}"
    echo -e "  URL: ${green}https://$DOMAIN$PANEL_PATH/${plain}"
    echo ""
    echo -e "  ${yellow}!${plain} В панели: Настройки → Настройки панели → URI Path → ${bold}$PANEL_PATH${plain}"
    echo -e "    (без этого ссылки внутри панели могут не работать)"
    echo ""

    echo -e "${bold}━━━ Настройка inbound'ов в 3x-ui ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${plain}"
    echo ""

    echo -e "${cyan}1. VLESS + WebSocket${plain}"
    echo -e "   Xray порт:     ${bold}$WS_PORT${plain}"
    echo -e "   Transport:     WebSocket,  Path: ${bold}$WS_PATH${plain}"
    echo -e "   TLS:           None  ← TLS снимает Nginx"
    echo -e "   ${dim}Клиент: host=$DOMAIN  port=443  TLS=TLS  path=$WS_PATH${plain}"
    echo ""

    echo -e "${cyan}2. VLESS + gRPC${plain}"
    echo -e "   Xray порт:     ${bold}$GRPC_PORT${plain}"
    echo -e "   Transport:     gRPC,  serviceName: ${bold}$GRPC_SERVICE${plain}"
    echo -e "   TLS:           None  ← TLS снимает Nginx"
    echo -e "   ${dim}Клиент: host=$DOMAIN  port=443  TLS=TLS  serviceName=$GRPC_SERVICE${plain}"
    echo ""

    echo -e "${cyan}3. VLESS + XHTTP (SplitHTTP)${plain}"
    echo -e "   Xray порт:     ${bold}$XHTTP_PORT${plain}"
    echo -e "   Transport:     XHTTP / SplitHTTP,  Path: ${bold}$XHTTP_PATH${plain}"
    echo -e "   TLS:           None  ← TLS снимает Nginx"
    echo -e "   ${dim}Клиент: host=$DOMAIN  port=443  TLS=TLS  path=$XHTTP_PATH${plain}"
    echo ""

    echo -e "${cyan}4. VLESS + Reality${plain}"
    echo -e "   Xray порт:     ${bold}$REALITY_PORT${plain}  (публичный, без Nginx)"
    echo -e "   Transport:     TCP / XTLS-Vision"
    echo -e "   TLS:           Reality"
    echo -e "   SNI-цель:      например ${bold}microsoft.com:443${plain} или ${bold}apple.com:443${plain}"
    echo -e "   ${yellow}Reality НЕ проходит через Nginx — подключение прямое!${plain}"
    echo -e "   ${dim}Клиент: host=<IP сервера>  port=$REALITY_PORT${plain}"
    echo ""

    echo -e "${bold}━━━ Порты ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${plain}"
    echo -e "  ${green}Публичные (открыть в файрволе):${plain}"
    echo -e "    80, 443/tcp  — HTTP + HTTPS (Nginx)"
    echo -e "    ${bold}$REALITY_PORT/tcp${plain}     — VLESS+Reality (прямой Xray)"
    echo ""
    echo -e "  ${red}Только localhost (НЕ открывать наружу!):${plain}"
    echo -e "    $PANEL_PORT  — 3x-ui панель"
    echo -e "    $WS_PORT     — VLESS+WS"
    echo -e "    $GRPC_PORT   — VLESS+gRPC"
    echo -e "    $XHTTP_PORT  — VLESS+XHTTP"
    echo ""
    echo ""

    echo -e "${bold}━━━ fail2ban ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${plain}"
    echo -e "  Активные jails:"
    echo -e "    nginx-4xx         — бан при >20 ошибках 4xx за 5 мин (бан 30 мин)"
    echo -e "    nginx-panel-auth  — бан при >10 ошибках 401/403 на панели (бан 2 ч)"
    echo -e "  Статус:   ${dim}fail2ban-client status${plain}"
    echo -e "  Забаненые: ${dim}fail2ban-client status nginx-4xx${plain}"
    echo ""

    echo -e "${bold}━━━ Файлы ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${plain}"
    echo -e "  Nginx конфиг:   /etc/nginx/sites-available/${DOMAIN}.conf"
    echo -e "  SSL сертификат: /root/cert/${DOMAIN}/"
    echo -e "  fail2ban jail:  /etc/fail2ban/jail.d/3xui-nginx.conf"
    echo -e "  Проверить:      ${dim}nginx -t && systemctl reload nginx${plain}"
    echo -e "  Логи nginx:     ${dim}tail -f /var/log/nginx/${DOMAIN}_error.log${plain}"
    echo -e "  Логи fail2ban:  ${dim}tail -f /var/log/fail2ban.log${plain}"
    echo ""

    info "Готово! Откройте ${green}https://$DOMAIN$PANEL_PATH/${plain}"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    echo -e "${cyan}${bold}"
    echo "  ╔════════════════════════════════════════════════════╗"
    echo "  ║         3x-ui Reverse Proxy Setup                 ║"
    echo "  ║   Nginx · acme.sh · VLESS Transports              ║"
    echo "  ╚════════════════════════════════════════════════════╝"
    echo -e "${plain}"

    detect_os
    ask_questions

    enable_bbr
    disable_ufw
    install_nginx
    install_acme
    install_3xui
    get_ssl
    write_nginx_config
    install_fail2ban

    show_instructions
}

main
