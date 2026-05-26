cat > /home/claude/pterodactyl-nebula-all-in-one-installer-v6.sh << 'ENDOFSCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# KAHFITZY NEBULA PRO PTERODACTYL v6
# One command install: Pterodactyl Panel + Nebula FULL custom UI
# Support: Ubuntu 22.04/24.04, Debian 12/13
# v6: Login page & server manager FULL redesign — bukan sekedar CSS override
# ============================================================

LOG_FILE="/var/log/kahfitzy-nebula-ptero-installer.log"
PANEL_DIR="/var/www/pterodactyl"
THEME_DIR="/var/www/pterodactyl/public/kahfitzy-nebula"
NGINX_CONF="/etc/nginx/sites-available/pterodactyl.conf"
PHP_VER="8.3"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

trap 'echo -e "${RED}Installer gagal di line $LINENO. Cek log: $LOG_FILE${NC}" | tee -a "$LOG_FILE"' ERR

log() { echo -e "$*" | tee -a "$LOG_FILE"; }
die() { log "${RED}$*${NC}"; exit 1; }
ok()  { log "${GREEN}$*${NC}"; }
warn(){ log "${YELLOW}$*${NC}"; }
info(){ log "${CYAN}$*${NC}"; }

banner() {
  clear
  echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}   KAHFITZY NEBULA PRO v6 - FULL CUSTOM UI  ${NC}"
  echo -e "${CYAN}   Login & Panel BEDA TOTAL dari Pterodactyl${NC}"
  echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"
  echo ""
}

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "Jalankan sebagai root. Contoh: sudo bash install.sh"
}

detect_os() {
  [[ -f /etc/os-release ]] || die "OS tidak dikenali."
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="$ID"
  OS_VER="$VERSION_ID"
  OS_CODENAME="${VERSION_CODENAME:-}"

  case "${OS_ID}:${OS_VER}" in
    ubuntu:22.04|ubuntu:24.04|debian:12|debian:13)
      ok "OS support terdeteksi: ${PRETTY_NAME}"
      ;;
    *)
      die "OS tidak support: ${PRETTY_NAME:-unknown}. Support: Ubuntu 22/24, Debian 12/13."
      ;;
  esac
}

random_string() {
  local len="${1:-32}"
  local out=""
  while [[ ${#out} -lt $len ]]; do
    out+="$(cat /proc/sys/kernel/random/uuid)"
    out="${out//-/}"
  done
  printf '%s' "${out:0:$len}"
}

confirm() {
  local prompt="$1"
  local ans
  read -r -p "$prompt [y/N]: " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

apt_base() {
  export DEBIAN_FRONTEND=noninteractive
  info "Update package index..."
  apt-get update -y
  apt-get install -y apt-transport-https ca-certificates curl wget gnupg lsb-release \
    software-properties-common sudo unzip tar git cron
}

setup_php_repo() {
  if [[ "$OS_ID" == "ubuntu" ]]; then
    info "Menambahkan repository PHP untuk Ubuntu..."
    LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
  else
    info "Menambahkan repository PHP untuk Debian..."
    install -d /etc/apt/keyrings
    curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/keyrings/sury-php.gpg
    echo "deb [signed-by=/etc/apt/keyrings/sury-php.gpg] https://packages.sury.org/php/ ${OS_CODENAME} main" \
      > /etc/apt/sources.list.d/sury-php.list
  fi
  apt-get update -y
}

install_dependencies() {
  apt_base
  setup_php_repo

  info "Install dependency Panel..."
  apt-get install -y \
    nginx mariadb-server redis-server certbot python3-certbot-nginx \
    php${PHP_VER} php${PHP_VER}-cli php${PHP_VER}-fpm php${PHP_VER}-common \
    php${PHP_VER}-gd php${PHP_VER}-mysql php${PHP_VER}-mbstring php${PHP_VER}-bcmath \
    php${PHP_VER}-xml php${PHP_VER}-curl php${PHP_VER}-zip php${PHP_VER}-intl php${PHP_VER}-sqlite3

  systemctl enable --now nginx mariadb redis-server php${PHP_VER}-fpm

  if ! command -v composer >/dev/null 2>&1; then
    info "Install Composer..."
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
  fi

  ok "Dependency selesai."
}

mysql_exec() {
  mysql --protocol=socket -uroot "$@"
}

env_format_value() {
  local value="$1"
  case "$value" in
    true|false|null|[0-9]*)
      printf '%s' "$value"
      return
      ;;
  esac
  if [[ "$value" =~ ^[A-Za-z0-9_@%+=:,.\\/-]+$ ]]; then
    printf '%s' "$value"
  else
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
  fi
}

set_env_value() {
  local file="$1" key="$2" value="$3"
  local formatted escaped
  formatted="$(env_format_value "$value")"
  escaped="$(printf '%s' "$formatted" | sed -e 's/[\\/&]/\\&/g')"
  if grep -q "^${key}=" "$file"; then
    sed -i "s/^${key}=.*/${key}=${escaped}/" "$file"
  else
    echo "${key}=${formatted}" >> "$file"
  fi
}

write_env() {
  local domain="$1" admin_email="$2" db_pass="$3"
  local app_url="https://${domain}"

  cd "$PANEL_DIR"
  cp -n .env.example .env

  set_env_value .env APP_NAME "Kahfitzy Nebula"
  set_env_value .env APP_ENV production
  set_env_value .env APP_DEBUG false
  set_env_value .env APP_URL "$app_url"
  set_env_value .env APP_TIMEZONE Asia/Jakarta
  set_env_value .env APP_SERVICE_AUTHOR "$admin_email"
  set_env_value .env TRUSTED_PROXIES '*'
  set_env_value .env DB_CONNECTION mysql
  set_env_value .env DB_HOST 127.0.0.1
  set_env_value .env DB_PORT 3306
  set_env_value .env DB_DATABASE panel
  set_env_value .env DB_USERNAME pterodactyl
  set_env_value .env DB_PASSWORD "$db_pass"
  set_env_value .env CACHE_DRIVER redis
  set_env_value .env SESSION_DRIVER database
  set_env_value .env QUEUE_CONNECTION redis
  set_env_value .env REDIS_HOST 127.0.0.1
  set_env_value .env REDIS_PASSWORD null
  set_env_value .env REDIS_PORT 6379
  set_env_value .env MAIL_MAILER log
  set_env_value .env MAIL_FROM_ADDRESS "$admin_email"
  set_env_value .env MAIL_FROM_NAME 'Kahfitzy Nebula'
}

setup_database() {
  local db_pass="$1"
  info "Setup database MariaDB..."
  mysql_exec <<SQL
CREATE DATABASE IF NOT EXISTS panel CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${db_pass}';
ALTER USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${db_pass}';
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
  ok "Database selesai."
}

install_panel_files() {
  if [[ -f "$PANEL_DIR/artisan" ]]; then
    warn "Panel sudah ada di $PANEL_DIR"
    echo ""
    echo "1. Lanjutkan setup / repair panel yang belum selesai"
    echo "2. Apply theme saja (skip install)"
    echo "0. Batal"
    read -r -p "Pilih: " EXISTING_CHOICE
    case "$EXISTING_CHOICE" in
      1)
        cd "$PANEL_DIR"
        COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction || true
        return 0
        ;;
      2) return 10 ;;
      *) die "Dibatalkan." ;;
    esac
  fi

  if [[ -d "$PANEL_DIR" && ! -f "$PANEL_DIR/artisan" ]]; then
    warn "Folder $PANEL_DIR sudah ada tapi bukan panel valid."
    if confirm "Backup folder lama dan install ulang panel?"; then
      mv "$PANEL_DIR" "${PANEL_DIR}.backup.$(date +%Y%m%d-%H%M%S)"
    else
      die "Dibatalkan agar data tidak tertimpa."
    fi
  fi

  mkdir -p "$PANEL_DIR"
  cd "$PANEL_DIR"
  info "Download Pterodactyl Panel release terbaru..."
  curl -L -o panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
  tar -xzvf panel.tar.gz >/dev/null
  rm -f panel.tar.gz
  chmod -R 755 storage bootstrap/cache
  info "Install dependency composer panel..."
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction
  return 0
}

create_admin_user() {
  local admin_email="$1" admin_user="$2" admin_pass="$3"
  cd "$PANEL_DIR"
  info "Membuat admin panel..."
  php artisan p:user:make \
    --email="$admin_email" \
    --username="$admin_user" \
    --name-first="Kahfitzy" \
    --name-last="Admin" \
    --password="$admin_pass" \
    --admin=1 \
    --no-interaction || warn "Gagal auto-create admin. Buat manual: php artisan p:user:make"
}

setup_permissions() {
  chown -R www-data:www-data "$PANEL_DIR"
  find "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" -type d -exec chmod 775 {} \; || true
}

setup_cron_and_queue() {
  info "Setup cron dan queue worker..."
  (crontab -l 2>/dev/null | grep -v "pterodactyl/artisan schedule:run" || true; \
   echo "* * * * * php $PANEL_DIR/artisan schedule:run >> /dev/null 2>&1") | crontab -

  cat > /etc/systemd/system/pteroq.service <<EOF
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php $PANEL_DIR/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now pteroq
}

setup_nginx() {
  local domain="$1"
  info "Setup Nginx untuk $domain..."

  cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name $domain;

    root $PANEL_DIR/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \\.php$ {
        fastcgi_split_path_info ^(.+\\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\\.ht {
        deny all;
    }
}
EOF

  ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/pterodactyl.conf
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl reload nginx
}

setup_ssl() {
  local domain="$1" email="$2"
  if confirm "Aktifkan SSL Let's Encrypt sekarang? Pastikan domain sudah mengarah ke IP VPS"; then
    info "Request SSL untuk $domain..."
    certbot --nginx -d "$domain" --non-interactive --agree-tos -m "$email" --redirect \
      || warn "SSL gagal. Panel tetap jalan via HTTP."
    systemctl reload nginx || true
  else
    warn "SSL dilewati. Aktifkan nanti dengan: certbot --nginx -d $domain"
  fi
}

# ============================================================
# NEBULA FULL CUSTOM THEME v6
# Login page: FULL custom design — bukan Pterodactyl form
# Server list & server detail: layout dan komponen baru
# ============================================================

write_nebula_css() {
  mkdir -p "$THEME_DIR"
  cat > "$THEME_DIR/nebula.css" << 'ENDCSS'
/* ====================================================
   KAHFITZY NEBULA PRO v6 — Full custom theme
   Bukan CSS override. Ini full redesign.
   ==================================================== */

/* ── FONTS ─────────────────────────────────────── */
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&family=Space+Grotesk:wght@400;500;600;700&display=swap');

/* ── VARIABLES ──────────────────────────────────── */
:root {
  --n-bg:        #030711;
  --n-bg1:       #070e1f;
  --n-bg2:       #0c1530;
  --n-card:      rgba(9,14,36,.82);
  --n-border:    rgba(148,163,255,.12);
  --n-border2:   rgba(148,163,255,.22);
  --n-text:      #eef0ff;
  --n-muted:     #8a9ac7;
  --n-purple:    #8b5cf6;
  --n-pink:      #ec4899;
  --n-cyan:      #22d3ee;
  --n-blue:      #3b82f6;
  --n-green:     #34d399;
  --n-red:       #fb7185;
  --n-yellow:    #fbbf24;
  --n-font:      'Inter', 'Space Grotesk', system-ui, sans-serif;
  --n-font-head: 'Space Grotesk', 'Inter', system-ui, sans-serif;
  --n-radius:    18px;
  --n-radius-sm: 12px;
  --n-radius-lg: 24px;
  --n-glow-p:    rgba(139,92,246,.28);
  --n-glow-c:    rgba(34,211,238,.22);
  --n-glow-pk:   rgba(236,72,153,.18);
}

/* ── RESET BASE ─────────────────────────────────── */
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

html {
  font-family: var(--n-font);
  font-size: 15px;
  background: var(--n-bg) !important;
  -webkit-font-smoothing: antialiased;
}

body {
  color: var(--n-text) !important;
  background:
    radial-gradient(circle at 15% 10%, rgba(139,92,246,.22) 0%, transparent 30%),
    radial-gradient(circle at 85% 15%, rgba(34,211,238,.16) 0%, transparent 28%),
    radial-gradient(circle at 50% 90%, rgba(236,72,153,.12) 0%, transparent 32%),
    linear-gradient(180deg, #030711 0%, #060d1e 50%, #030711 100%) !important;
  background-attachment: fixed !important;
  overflow-x: hidden !important;
  min-height: 100vh;
}

/* ── STARFIELD ──────────────────────────────────── */
body::before {
  content: "";
  position: fixed;
  inset: 0;
  pointer-events: none;
  z-index: 0;
  background-image:
    radial-gradient(circle, rgba(255,255,255,.55) 0 1px, transparent 1.5px),
    radial-gradient(circle, rgba(34,211,238,.3) 0 1px, transparent 2px),
    radial-gradient(circle, rgba(139,92,246,.25) 0 1px, transparent 1.8px);
  background-size: 160px 160px, 240px 240px, 310px 310px;
  background-position: 24px 32px, 80px 90px, 140px 60px;
  opacity: .6;
  mask-image: linear-gradient(to bottom, rgba(0,0,0,.85) 0%, transparent 82%);
}

/* ── NEBULA GLOW BG ─────────────────────────────── */
body::after {
  content: "";
  position: fixed;
  inset: -20% -15% auto -15%;
  height: 80vh;
  pointer-events: none;
  z-index: 0;
  background:
    radial-gradient(ellipse at 22% 40%, rgba(139,92,246,.20) 0%, transparent 55%),
    radial-gradient(ellipse at 72% 30%, rgba(34,211,238,.14) 0%, transparent 52%),
    radial-gradient(ellipse at 52% 70%, rgba(236,72,153,.10) 0%, transparent 55%);
  filter: blur(52px);
}

#app { position: relative; z-index: 1; min-height: 100vh; }

/* ====================================================
   A. HALAMAN LOGIN — FULL CUSTOM
   ==================================================== */

/* Sembunyikan layout default Pterodactyl di halaman auth */
body.login-page .container,
body.auth-page .container,
[data-pterodactyl-title*="Login"] .container {
  all: unset !important;
}

/* Wrapper login baru */
.kn-login-wrap {
  position: fixed;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 1.5rem;
  z-index: 10;
}

/* Panel kiri — ilustrasi / branding */
.kn-login-left {
  flex: 0 0 420px;
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  justify-content: center;
  padding: 3rem 3.5rem;
  background:
    radial-gradient(ellipse at 30% 20%, rgba(139,92,246,.22), transparent 60%),
    radial-gradient(ellipse at 70% 80%, rgba(34,211,238,.16), transparent 60%),
    rgba(7,12,30,.72);
  border: 1px solid var(--n-border2);
  border-radius: var(--n-radius-lg) 0 0 var(--n-radius-lg);
  backdrop-filter: blur(22px);
  min-height: 560px;
}

.kn-login-logo {
  font-family: var(--n-font-head);
  font-size: 2rem;
  font-weight: 700;
  background: linear-gradient(135deg, var(--n-purple), var(--n-cyan));
  -webkit-background-clip: text;
  -webkit-text-fill-color: transparent;
  background-clip: text;
  margin-bottom: .4rem;
}

.kn-login-tagline {
  font-size: .82rem;
  color: var(--n-muted);
  letter-spacing: .06em;
  text-transform: uppercase;
  margin-bottom: 2.5rem;
}

.kn-orbit {
  width: 210px;
  height: 210px;
  position: relative;
  margin: 0 auto 2.5rem auto;
}

.kn-orbit-ring {
  position: absolute;
  inset: 0;
  border-radius: 50%;
  border: 1px solid rgba(139,92,246,.22);
  animation: kn-spin 10s linear infinite;
}
.kn-orbit-ring:nth-child(2) {
  inset: 18px;
  border-color: rgba(34,211,238,.18);
  animation-duration: 15s;
  animation-direction: reverse;
}
.kn-orbit-ring:nth-child(3) {
  inset: 36px;
  border-color: rgba(236,72,153,.14);
  animation-duration: 20s;
}

.kn-orbit-dot {
  position: absolute;
  width: 8px;
  height: 8px;
  border-radius: 50%;
  top: -4px;
  left: 50%;
  transform: translateX(-50%);
}
.kn-orbit-dot-1 { background: var(--n-purple); box-shadow: 0 0 10px var(--n-purple); }
.kn-orbit-dot-2 { background: var(--n-cyan);   box-shadow: 0 0 10px var(--n-cyan);   }
.kn-orbit-dot-3 { background: var(--n-pink);   box-shadow: 0 0 10px var(--n-pink);   }

.kn-orbit-core {
  position: absolute;
  inset: 54px;
  border-radius: 50%;
  background: radial-gradient(circle, rgba(139,92,246,.35), rgba(34,211,238,.15), transparent 70%);
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 2.4rem;
}

.kn-login-features {
  display: flex;
  flex-direction: column;
  gap: .65rem;
  width: 100%;
}

.kn-feat-item {
  display: flex;
  align-items: center;
  gap: .7rem;
  font-size: .82rem;
  color: var(--n-muted);
}

.kn-feat-icon {
  width: 28px;
  height: 28px;
  border-radius: 8px;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: .9rem;
  background: rgba(139,92,246,.15);
  border: 1px solid rgba(139,92,246,.22);
  flex-shrink: 0;
}

/* Panel kanan — form login */
.kn-login-right {
  flex: 0 0 380px;
  background: rgba(5,9,26,.88);
  border: 1px solid var(--n-border);
  border-left: none;
  border-radius: 0 var(--n-radius-lg) var(--n-radius-lg) 0;
  backdrop-filter: blur(28px);
  padding: 3rem 2.8rem;
  min-height: 560px;
  display: flex;
  flex-direction: column;
  justify-content: center;
}

.kn-login-title {
  font-family: var(--n-font-head);
  font-size: 1.65rem;
  font-weight: 700;
  color: var(--n-text);
  margin-bottom: .35rem;
}

.kn-login-sub {
  font-size: .83rem;
  color: var(--n-muted);
  margin-bottom: 2rem;
}

.kn-form-group {
  display: flex;
  flex-direction: column;
  gap: .4rem;
  margin-bottom: 1.1rem;
}

.kn-label {
  font-size: .78rem;
  font-weight: 600;
  color: var(--n-muted);
  letter-spacing: .05em;
  text-transform: uppercase;
}

.kn-input-wrap {
  position: relative;
  display: flex;
  align-items: center;
}

.kn-input-icon {
  position: absolute;
  left: 14px;
  font-size: 1rem;
  color: var(--n-muted);
  pointer-events: none;
  z-index: 1;
}

.kn-input {
  width: 100%;
  padding: .72rem 1rem .72rem 2.6rem;
  background: rgba(3,7,20,.72) !important;
  border: 1px solid var(--n-border) !important;
  border-radius: var(--n-radius-sm) !important;
  color: var(--n-text) !important;
  font-family: var(--n-font);
  font-size: .88rem;
  transition: border-color .2s, box-shadow .2s;
  outline: none;
}

.kn-input:focus {
  border-color: rgba(34,211,238,.6) !important;
  box-shadow: 0 0 0 3px rgba(34,211,238,.1), 0 0 20px rgba(139,92,246,.08) !important;
}

.kn-input::placeholder { color: rgba(138,154,199,.55) !important; }

.kn-btn-primary {
  width: 100%;
  padding: .82rem 1rem;
  margin-top: .4rem;
  background: linear-gradient(135deg, #7c3aed 0%, #2563eb 55%, #06b6d4 100%) !important;
  border: none !important;
  border-radius: var(--n-radius-sm) !important;
  color: #fff !important;
  font-family: var(--n-font-head);
  font-size: .92rem;
  font-weight: 600;
  letter-spacing: .03em;
  cursor: pointer;
  position: relative;
  overflow: hidden;
  box-shadow: 0 12px 40px rgba(59,130,246,.25), 0 0 20px rgba(139,92,246,.15) !important;
  transition: transform .18s ease, box-shadow .18s ease, filter .18s ease;
}

.kn-btn-primary::before {
  content: "";
  position: absolute;
  top: 0; left: -100%;
  width: 100%; height: 100%;
  background: linear-gradient(90deg, transparent, rgba(255,255,255,.12), transparent);
  transition: left .5s;
}

.kn-btn-primary:hover {
  transform: translateY(-2px);
  filter: brightness(1.08);
  box-shadow: 0 18px 55px rgba(59,130,246,.3), 0 0 30px rgba(139,92,246,.2) !important;
}

.kn-btn-primary:hover::before { left: 100%; }

.kn-login-links {
  display: flex;
  justify-content: space-between;
  margin-top: 1.4rem;
  font-size: .78rem;
}

.kn-login-links a {
  color: var(--n-muted) !important;
  text-decoration: none !important;
  transition: color .2s;
}
.kn-login-links a:hover { color: var(--n-cyan) !important; }

.kn-login-divider {
  text-align: center;
  color: var(--n-muted);
  font-size: .75rem;
  margin: 1.3rem 0;
  position: relative;
}
.kn-login-divider::before,
.kn-login-divider::after {
  content: "";
  position: absolute;
  top: 50%;
  width: 36%;
  height: 1px;
  background: var(--n-border);
}
.kn-login-divider::before { left: 0; }
.kn-login-divider::after  { right: 0; }

@keyframes kn-spin { to { transform: rotate(360deg); } }

@media (max-width: 840px) {
  .kn-login-left { display: none; }
  .kn-login-right {
    border-radius: var(--n-radius-lg);
    border-left: 1px solid var(--n-border);
    max-width: 420px;
    width: 100%;
  }
}

/* ====================================================
   B. NAVIGATION — TOP BAR
   ==================================================== */

/* Sembunyikan nav default pterodactyl, ganti dengan kn-nav */
nav.bg-neutral-900,
nav[class*="bg-neutral"],
nav[class*="bg-gray-900"],
nav[class*="bg-slate"] {
  display: none !important;
}

.kn-topbar {
  position: fixed;
  top: 0; left: 0; right: 0;
  height: 60px;
  background: rgba(3,7,20,.88);
  border-bottom: 1px solid var(--n-border);
  backdrop-filter: blur(20px) saturate(180%);
  -webkit-backdrop-filter: blur(20px) saturate(180%);
  display: flex;
  align-items: center;
  padding: 0 1.5rem;
  gap: 1rem;
  z-index: 900;
  box-shadow: 0 8px 32px rgba(0,0,0,.28);
}

.kn-nav-logo {
  font-family: var(--n-font-head);
  font-weight: 700;
  font-size: 1.1rem;
  background: linear-gradient(135deg, var(--n-purple), var(--n-cyan));
  -webkit-background-clip: text;
  -webkit-text-fill-color: transparent;
  background-clip: text;
  margin-right: .5rem;
  white-space: nowrap;
  flex-shrink: 0;
}

.kn-nav-links {
  display: flex;
  gap: .25rem;
  flex: 1;
}

.kn-nav-link {
  display: flex;
  align-items: center;
  gap: .4rem;
  padding: .4rem .8rem;
  border-radius: 10px;
  font-size: .83rem;
  font-weight: 500;
  color: var(--n-muted) !important;
  text-decoration: none !important;
  transition: background .18s, color .18s;
}

.kn-nav-link:hover,
.kn-nav-link.active {
  background: rgba(139,92,246,.15);
  color: var(--n-text) !important;
}

.kn-nav-link.active {
  background: rgba(139,92,246,.2);
  color: #d8b4fe !important;
}

.kn-nav-right {
  display: flex;
  align-items: center;
  gap: .75rem;
  margin-left: auto;
}

.kn-nav-avatar {
  width: 36px;
  height: 36px;
  border-radius: 50%;
  background: linear-gradient(135deg, var(--n-purple), var(--n-cyan));
  display: flex;
  align-items: center;
  justify-content: center;
  font-weight: 700;
  font-size: .85rem;
  color: #fff;
  cursor: pointer;
  border: 2px solid rgba(139,92,246,.35);
  transition: border-color .2s, box-shadow .2s;
}
.kn-nav-avatar:hover {
  border-color: var(--n-purple);
  box-shadow: 0 0 16px rgba(139,92,246,.3);
}

.kn-nav-badge {
  display: inline-flex;
  align-items: center;
  padding: .2rem .6rem;
  border-radius: 999px;
  font-size: .68rem;
  font-weight: 600;
  background: rgba(139,92,246,.18);
  border: 1px solid rgba(139,92,246,.3);
  color: #c4b5fd;
  white-space: nowrap;
}

/* ====================================================
   C. SERVER LIST — BUKAN TABLE PTERODACTYL
   ==================================================== */

/* Offset untuk topbar */
#app > .w-full:first-child {
  padding-top: 60px !important;
}

/* Sembunyikan container default server list pterodactyl */
.server-bar { display: none !important; }

/* Main content wrapper */
.kn-main {
  max-width: 1200px;
  margin: 0 auto;
  padding: 2rem 1.5rem;
}

/* Page header bar */
.kn-page-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 2rem;
  flex-wrap: wrap;
  gap: 1rem;
}

.kn-page-title {
  font-family: var(--n-font-head);
  font-size: 1.5rem;
  font-weight: 700;
  color: var(--n-text);
}

.kn-page-sub {
  font-size: .82rem;
  color: var(--n-muted);
  margin-top: .2rem;
}

/* Search bar */
.kn-search {
  display: flex;
  align-items: center;
  gap: .6rem;
  background: rgba(3,7,20,.72);
  border: 1px solid var(--n-border);
  border-radius: var(--n-radius-sm);
  padding: .5rem 1rem;
  min-width: 220px;
}

.kn-search input {
  background: transparent !important;
  border: none !important;
  color: var(--n-text) !important;
  font-size: .85rem;
  outline: none;
  flex: 1;
}

.kn-search input::placeholder { color: var(--n-muted) !important; }

/* ── SERVER CARDS ───────────────────────────────── */
.kn-servers {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(320px, 1fr));
  gap: 1.25rem;
}

.kn-server-card {
  background: var(--n-card);
  border: 1px solid var(--n-border);
  border-radius: var(--n-radius);
  padding: 1.5rem;
  position: relative;
  overflow: hidden;
  transition: transform .2s ease, box-shadow .2s ease, border-color .2s ease;
  cursor: pointer;
  text-decoration: none !important;
  display: block;
}

.kn-server-card::before {
  content: "";
  position: absolute;
  top: 0; left: 0; right: 0;
  height: 2px;
  background: linear-gradient(90deg, var(--n-purple), var(--n-cyan));
  opacity: 0;
  transition: opacity .2s;
}

.kn-server-card:hover {
  transform: translateY(-3px);
  border-color: rgba(139,92,246,.35);
  box-shadow:
    0 24px 64px rgba(0,0,0,.35),
    0 0 0 1px rgba(139,92,246,.14),
    0 0 40px rgba(139,92,246,.07);
}

.kn-server-card:hover::before { opacity: 1; }

/* Status indicator */
.kn-status-dot {
  width: 9px;
  height: 9px;
  border-radius: 50%;
  display: inline-block;
  flex-shrink: 0;
}

.kn-status-dot.running {
  background: var(--n-green);
  box-shadow: 0 0 8px rgba(52,211,153,.5);
  animation: kn-pulse 2.2s ease infinite;
}

.kn-status-dot.offline { background: rgba(251,113,133,.5); box-shadow: none; }
.kn-status-dot.starting { background: var(--n-yellow); box-shadow: 0 0 8px rgba(251,191,36,.4); }
.kn-status-dot.stopping { background: var(--n-yellow); opacity: .7; }

@keyframes kn-pulse {
  0%, 100% { box-shadow: 0 0 8px rgba(52,211,153,.5); }
  50%       { box-shadow: 0 0 16px rgba(52,211,153,.8); }
}

.kn-server-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  margin-bottom: 1rem;
}

.kn-server-icon {
  width: 44px;
  height: 44px;
  border-radius: 12px;
  background: linear-gradient(135deg, rgba(139,92,246,.2), rgba(34,211,238,.12));
  border: 1px solid rgba(139,92,246,.22);
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 1.3rem;
}

.kn-server-status-row {
  display: flex;
  align-items: center;
  gap: .45rem;
  font-size: .75rem;
  color: var(--n-muted);
}

.kn-server-name {
  font-family: var(--n-font-head);
  font-weight: 600;
  font-size: 1rem;
  color: var(--n-text);
  margin-bottom: .25rem;
}

.kn-server-desc {
  font-size: .78rem;
  color: var(--n-muted);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

/* Resource bars */
.kn-resource-bars {
  display: flex;
  flex-direction: column;
  gap: .6rem;
  margin-top: 1.1rem;
}

.kn-res-row {
  display: flex;
  flex-direction: column;
  gap: .28rem;
}

.kn-res-label {
  display: flex;
  justify-content: space-between;
  font-size: .72rem;
  color: var(--n-muted);
}

.kn-res-label span:last-child { color: var(--n-text); }

.kn-res-track {
  height: 4px;
  background: rgba(255,255,255,.07);
  border-radius: 999px;
  overflow: hidden;
}

.kn-res-fill {
  height: 100%;
  border-radius: 999px;
  transition: width .6s ease;
}

.kn-res-fill.cpu   { background: linear-gradient(90deg, var(--n-purple), var(--n-blue)); }
.kn-res-fill.ram   { background: linear-gradient(90deg, var(--n-cyan), var(--n-blue)); }
.kn-res-fill.disk  { background: linear-gradient(90deg, var(--n-pink), var(--n-purple)); }

.kn-server-foot {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-top: 1.1rem;
  padding-top: .9rem;
  border-top: 1px solid var(--n-border);
  font-size: .75rem;
  color: var(--n-muted);
}

.kn-chip {
  display: inline-flex;
  align-items: center;
  gap: .3rem;
  padding: .2rem .55rem;
  border-radius: 6px;
  font-size: .7rem;
  font-weight: 600;
}

.kn-chip.green  { background: rgba(52,211,153,.12);  color: var(--n-green);  border: 1px solid rgba(52,211,153,.22);  }
.kn-chip.red    { background: rgba(251,113,133,.12); color: var(--n-red);    border: 1px solid rgba(251,113,133,.22); }
.kn-chip.yellow { background: rgba(251,191,36,.12);  color: var(--n-yellow); border: 1px solid rgba(251,191,36,.22);  }
.kn-chip.purple { background: rgba(139,92,246,.12);  color: #c4b5fd;         border: 1px solid rgba(139,92,246,.22);  }
.kn-chip.cyan   { background: rgba(34,211,238,.10);  color: var(--n-cyan);   border: 1px solid rgba(34,211,238,.2);   }

/* ====================================================
   D. SERVER DETAIL PAGE — SIDEBAR + CONTENT
   ==================================================== */

.kn-detail-layout {
  display: flex;
  gap: 1.5rem;
  min-height: calc(100vh - 60px);
  padding-top: 60px;
}

/* Sidebar */
.kn-sidebar {
  width: 220px;
  flex-shrink: 0;
  background: rgba(4,8,24,.82);
  border-right: 1px solid var(--n-border);
  backdrop-filter: blur(20px);
  padding: 1.5rem 0;
  position: fixed;
  top: 60px;
  bottom: 0;
  overflow-y: auto;
  z-index: 100;
}

.kn-sidebar-section {
  padding: .5rem 1rem .25rem 1rem;
  font-size: .68rem;
  font-weight: 700;
  letter-spacing: .1em;
  text-transform: uppercase;
  color: rgba(139,92,246,.7);
  margin-top: .5rem;
}

.kn-sidebar-link {
  display: flex;
  align-items: center;
  gap: .65rem;
  padding: .55rem 1.2rem;
  font-size: .83rem;
  color: var(--n-muted) !important;
  text-decoration: none !important;
  border-left: 2px solid transparent;
  transition: background .15s, color .15s, border-color .15s;
}

.kn-sidebar-link:hover {
  background: rgba(139,92,246,.1);
  color: var(--n-text) !important;
}

.kn-sidebar-link.active {
  background: rgba(139,92,246,.15);
  border-left-color: var(--n-purple);
  color: #d8b4fe !important;
}

.kn-sidebar-icon {
  width: 18px;
  text-align: center;
  font-size: 1rem;
  flex-shrink: 0;
}

.kn-sidebar-badge {
  margin-left: auto;
  background: rgba(139,92,246,.2);
  color: #c4b5fd;
  font-size: .65rem;
  padding: .1rem .4rem;
  border-radius: 999px;
}

/* Content area */
.kn-content {
  flex: 1;
  margin-left: 220px;
  padding: 2rem 2rem 2rem 2rem;
  min-height: calc(100vh - 60px);
}

/* ── CONSOLE ─────────────────────────────────────── */
.kn-console-wrap {
  background: rgba(2,5,18,.9) !important;
  border: 1px solid rgba(139,92,246,.2) !important;
  border-radius: var(--n-radius) !important;
  overflow: hidden;
  box-shadow:
    0 30px 80px rgba(0,0,0,.4),
    inset 0 1px 0 rgba(139,92,246,.1) !important;
}

.kn-console-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: .75rem 1.2rem;
  background: rgba(139,92,246,.08);
  border-bottom: 1px solid rgba(139,92,246,.14);
}

.kn-console-dots {
  display: flex;
  gap: .35rem;
}

.kn-console-dot {
  width: 10px;
  height: 10px;
  border-radius: 50%;
}

.kn-console-dot:nth-child(1) { background: #fb7185; }
.kn-console-dot:nth-child(2) { background: #fbbf24; }
.kn-console-dot:nth-child(3) { background: #34d399; }

.kn-console-title {
  font-size: .75rem;
  color: var(--n-muted);
  letter-spacing: .06em;
}

/* ── STAT CARDS (top of server page) ─────────────── */
.kn-stat-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
  gap: 1rem;
  margin-bottom: 1.5rem;
}

.kn-stat-card {
  background: var(--n-card);
  border: 1px solid var(--n-border);
  border-radius: var(--n-radius-sm);
  padding: 1rem 1.2rem;
  position: relative;
  overflow: hidden;
}

.kn-stat-card::after {
  content: "";
  position: absolute;
  bottom: 0; left: 0; right: 0;
  height: 2px;
}

.kn-stat-card.cpu::after    { background: linear-gradient(90deg, var(--n-purple), var(--n-blue)); }
.kn-stat-card.ram::after    { background: linear-gradient(90deg, var(--n-cyan), var(--n-blue)); }
.kn-stat-card.disk::after   { background: linear-gradient(90deg, var(--n-pink), var(--n-purple)); }
.kn-stat-card.net::after    { background: linear-gradient(90deg, var(--n-green), var(--n-cyan)); }
.kn-stat-card.uptime::after { background: linear-gradient(90deg, var(--n-yellow), var(--n-green)); }

.kn-stat-label {
  font-size: .72rem;
  color: var(--n-muted);
  text-transform: uppercase;
  letter-spacing: .08em;
  margin-bottom: .3rem;
}

.kn-stat-value {
  font-family: var(--n-font-head);
  font-size: 1.4rem;
  font-weight: 700;
  color: var(--n-text);
  line-height: 1;
}

.kn-stat-unit {
  font-size: .7rem;
  color: var(--n-muted);
  margin-top: .2rem;
}

/* ====================================================
   E. OVERRIDE SISA UI PTERODACTYL
      (form, table, input di halaman admin/detail)
   ==================================================== */

/* Global card styling */
.bg-gray-700, .bg-gray-800, .bg-gray-900,
.bg-neutral-700, .bg-neutral-800, .bg-neutral-900,
.bg-slate-700, .bg-slate-800, .bg-slate-900,
[class*="bg-gray-7"], [class*="bg-gray-8"], [class*="bg-gray-9"] {
  background: linear-gradient(160deg, rgba(10,16,42,.85), rgba(5,9,25,.75)) !important;
  border-color: var(--n-border) !important;
}

/* Border radius global */
[class*="rounded-lg"], [class*="rounded-xl"], [class*="rounded-2xl"] {
  border-radius: var(--n-radius) !important;
}
[class*="rounded-md"], [class*="rounded"] {
  border-radius: var(--n-radius-sm) !important;
}

/* Input fields */
input:not([type="range"]):not([type="checkbox"]):not([type="radio"]),
textarea,
select {
  background: rgba(3,7,20,.75) !important;
  border: 1px solid var(--n-border) !important;
  color: var(--n-text) !important;
  border-radius: var(--n-radius-sm) !important;
  font-family: var(--n-font) !important;
  transition: border-color .2s, box-shadow .2s;
}

input:not([type="range"]):not([type="checkbox"]):not([type="radio"]):focus,
textarea:focus,
select:focus {
  border-color: rgba(34,211,238,.65) !important;
  box-shadow: 0 0 0 3px rgba(34,211,238,.1) !important;
  outline: none !important;
}

input::placeholder, textarea::placeholder { color: rgba(138,154,199,.5) !important; }

/* Buttons */
button, [type="submit"], [type="button"] {
  font-family: var(--n-font) !important;
  border-radius: var(--n-radius-sm) !important;
  transition: transform .16s ease, filter .16s ease, box-shadow .16s ease !important;
}

button:hover:not(:disabled), [type="submit"]:hover {
  transform: translateY(-1px) !important;
  filter: brightness(1.06) !important;
}

/* Primary buttons */
[class*="bg-blue-"], [class*="bg-green-"], [class*="bg-purple-"] {
  background: linear-gradient(135deg, #7c3aed 0%, #2563eb 55%, #06b6d4 100%) !important;
  color: #fff !important;
  border: 1px solid rgba(255,255,255,.12) !important;
  box-shadow: 0 10px 35px rgba(59,130,246,.2) !important;
}

[class*="bg-red-"] {
  background: linear-gradient(135deg, #f43f5e, #be123c) !important;
  color: #fff !important;
}

/* Tables */
table { border-collapse: separate !important; border-spacing: 0 !important; }
thead { background: rgba(139,92,246,.06) !important; }
th { font-size: .72rem !important; text-transform: uppercase !important; letter-spacing: .08em !important; color: var(--n-muted) !important; }
td, th { border-color: var(--n-border) !important; }
tr:hover td { background: rgba(139,92,246,.05) !important; }

/* Alerts / notifications */
[class*="bg-yellow-"] { background: rgba(251,191,36,.12) !important; border-color: rgba(251,191,36,.25) !important; color: var(--n-yellow) !important; }
[class*="bg-red-"]    { background: rgba(251,113,133,.12) !important; border-color: rgba(251,113,133,.25) !important; }
[class*="bg-green-"]  { background: rgba(52,211,153,.10) !important; border-color: rgba(52,211,153,.22) !important; color: var(--n-green) !important; }

/* Scrollbar */
::-webkit-scrollbar { width: 7px; height: 7px; }
::-webkit-scrollbar-track { background: rgba(2,6,20,.7); }
::-webkit-scrollbar-thumb {
  background: linear-gradient(180deg, rgba(139,92,246,.6), rgba(34,211,238,.5));
  border-radius: 999px;
}

/* Text colors */
[class*="text-gray-50"], [class*="text-gray-100"], [class*="text-neutral-100"] { color: var(--n-text) !important; }
[class*="text-gray-200"], [class*="text-gray-300"], [class*="text-neutral-200"], [class*="text-neutral-300"] { color: #ccd6f6 !important; }
[class*="text-gray-400"], [class*="text-gray-500"], [class*="text-neutral-400"], [class*="text-neutral-500"] { color: var(--n-muted) !important; }

/* Breadcrumb */
[class*="breadcrumb"] a, .breadcrumbs a { color: #c4b5fd !important; }

/* Modal */
[class*="modal"] > div, [role="dialog"] > div {
  background: linear-gradient(160deg, rgba(10,16,42,.97), rgba(5,9,25,.95)) !important;
  border: 1px solid var(--n-border2) !important;
  border-radius: var(--n-radius-lg) !important;
  box-shadow: 0 40px 120px rgba(0,0,0,.5), 0 0 60px rgba(139,92,246,.08) !important;
}

/* File manager */
[class*="file-object"], [class*="FileObject"] {
  border-color: var(--n-border) !important;
  background: var(--n-card) !important;
}
[class*="file-object"]:hover { background: rgba(139,92,246,.08) !important; }

/* Mobile */
@media (max-width: 768px) {
  body::before { background-size: 110px 110px, 170px 170px, 220px 220px; opacity: .5; }
  body::after  { filter: blur(36px); height: 60vh; }
  .kn-sidebar  { transform: translateX(-100%); transition: transform .25s; }
  .kn-sidebar.open { transform: translateX(0); }
  .kn-content  { margin-left: 0; }
  .kn-servers  { grid-template-columns: 1fr; }
  .kn-topbar   { padding: 0 1rem; }
  [class*="rounded-lg"], [class*="rounded-xl"] { border-radius: 14px !important; }
}
ENDCSS
  ok "CSS Nebula v6 ditulis."
}

write_nebula_js() {
  mkdir -p "$THEME_DIR"
  cat > "$THEME_DIR/nebula.js" << 'ENDJS'
/* ====================================================
   KAHFITZY NEBULA PRO v6 — Full UI injection
   Login page full custom + server card redesign
   ==================================================== */
(function () {
  'use strict';

  const BRAND   = 'Kahfitzy Nebula';
  const BRAND_S = 'Nebula';
  const ICONS = {
    server:   '🖥️',
    database: '🗄️',
    file:     '📁',
    console:  '⌨️',
    schedule: '⏰',
    users:    '👥',
    settings: '⚙️',
    network:  '🌐',
    startup:  '🚀',
    activity: '📊',
    home:     '🏠',
    back:     '←',
  };

  /* ── util ── */
  const q  = (s, p) => (p || document).querySelector(s);
  const qq = (s, p) => [...(p || document).querySelectorAll(s)];
  const el = (tag, cls, html) => {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (html !== undefined) e.innerHTML = html;
    return e;
  };

  /* ── rebrand text nodes ── */
  function rebrand(root) {
    if (!root) return;
    const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
    const nodes = [];
    while (w.nextNode()) nodes.push(w.currentNode);
    nodes.forEach(n => {
      if (!n.nodeValue) return;
      n.nodeValue = n.nodeValue
        .replace(/Pterodactyl®?/gi, BRAND)
        .replace(/pterodactyl/gi, BRAND)
        .replace(/Kahfitzy Stellar/gi, BRAND);
    });
    document.title = document.title
      .replace(/Pterodactyl®?/gi, BRAND)
      .replace(/Kahfitzy Stellar/gi, BRAND);
  }

  /* ── detect current page ── */
  function getPage() {
    const p = window.location.pathname;
    if (p === '/' || p === '/login' || p.includes('/auth/'))       return 'login';
    if (p === '/servers' || p === '/dashboard' || p === '/')        return 'servers';
    if (p.match(/^\/server\/[^/]+$/))                              return 'server-home';
    if (p.match(/^\/server\/[^/]+\//))                             return 'server-detail';
    return 'other';
  }

  /* ── inject topbar ── */
  function injectTopbar(page) {
    if (q('.kn-topbar')) return;
    if (page === 'login') return;

    const userName = (q('[data-user-name]')?.dataset?.userName ||
                      q('.navigation__avatar')?.textContent?.trim()?.slice(0,1).toUpperCase() ||
                      q('meta[name="csrf-token"]') ? '?' : '?').slice(0, 1).toUpperCase();

    const isServer = page.startsWith('server-');
    const currentServer = isServer ? window.location.pathname.split('/')[2] : null;

    const bar = el('div', 'kn-topbar');
    bar.innerHTML = `
      <a href="/" class="kn-nav-logo">${BRAND_S}</a>
      <nav class="kn-nav-links">
        <a href="/" class="kn-nav-link ${page === 'servers' ? 'active' : ''}">
          ${ICONS.home} Servers
        </a>
        ${isServer ? `
        <a href="/server/${currentServer}" class="kn-nav-link ${page === 'server-home' ? 'active' : ''}">
          ${ICONS.console} Console
        </a>
        <a href="/server/${currentServer}/files" class="kn-nav-link">
          ${ICONS.file} Files
        </a>
        <a href="/server/${currentServer}/databases" class="kn-nav-link">
          ${ICONS.database} Database
        </a>
        <a href="/server/${currentServer}/schedules" class="kn-nav-link">
          ${ICONS.schedule} Schedules
        </a>
        <a href="/server/${currentServer}/settings" class="kn-nav-link">
          ${ICONS.settings} Settings
        </a>` : ''}
      </nav>
      <div class="kn-nav-right">
        <span class="kn-nav-badge">✦ Nebula</span>
        <div class="kn-nav-avatar" title="Account">${userName}</div>
      </div>
    `;
    document.body.prepend(bar);
  }

  /* ── inject custom login ── */
  function injectLogin() {
    const existingForm = q('form');
    if (!existingForm) return;
    if (q('.kn-login-wrap')) return;

    // Sembunyikan semua elemen default pterodactyl di luar form
    qq('body > *').forEach(c => {
      if (!c.tagName.match(/^(STYLE|LINK|SCRIPT)$/)) c.style.display = 'none';
    });

    const emailInput    = q('input[type="email"], input[name="user"]', existingForm);
    const passwordInput = q('input[type="password"]', existingForm);
    const submitBtn     = q('button[type="submit"], input[type="submit"]', existingForm);
    const forgotLink    = q('a[href*="forgot"], a[href*="password"]', existingForm);
    const csrfInput     = q('input[name="_token"]', existingForm);

    // Bungkus form asli tapi sembunyikan
    existingForm.style.display = 'none';

    const wrap = el('div', 'kn-login-wrap');
    wrap.innerHTML = `
      <div class="kn-login-left">
        <div class="kn-login-logo">${BRAND}</div>
        <div class="kn-login-tagline">Game Server Manager</div>

        <div class="kn-orbit">
          <div class="kn-orbit-ring"><div class="kn-orbit-dot kn-orbit-dot-1"></div></div>
          <div class="kn-orbit-ring"><div class="kn-orbit-dot kn-orbit-dot-2"></div></div>
          <div class="kn-orbit-ring"><div class="kn-orbit-dot kn-orbit-dot-3"></div></div>
          <div class="kn-orbit-core">🌌</div>
        </div>

        <div class="kn-login-features">
          <div class="kn-feat-item">
            <div class="kn-feat-icon">⚡</div>
            Real-time server monitoring
          </div>
          <div class="kn-feat-item">
            <div class="kn-feat-icon">🔒</div>
            Secure isolated containers
          </div>
          <div class="kn-feat-item">
            <div class="kn-feat-icon">📁</div>
            Full file manager & console
          </div>
          <div class="kn-feat-item">
            <div class="kn-feat-icon">🌐</div>
            Multi-server control panel
          </div>
        </div>
      </div>

      <div class="kn-login-right">
        <div class="kn-login-title">Welcome back</div>
        <div class="kn-login-sub">Sign in to manage your servers</div>

        <div id="kn-error-box" style="display:none;padding:.75rem 1rem;background:rgba(251,113,133,.12);border:1px solid rgba(251,113,133,.3);border-radius:12px;color:#fb7185;font-size:.8rem;margin-bottom:1rem;"></div>

        <div class="kn-form-group">
          <label class="kn-label">Email or Username</label>
          <div class="kn-input-wrap">
            <span class="kn-input-icon">👤</span>
            <input class="kn-input" id="kn-user" type="text"
              autocomplete="username"
              placeholder="your@email.com"
              value="${emailInput ? (emailInput.value || '') : ''}">
          </div>
        </div>

        <div class="kn-form-group">
          <label class="kn-label">Password</label>
          <div class="kn-input-wrap">
            <span class="kn-input-icon">🔑</span>
            <input class="kn-input" id="kn-pass" type="password"
              autocomplete="current-password"
              placeholder="••••••••••">
            <span id="kn-eye" style="position:absolute;right:12px;cursor:pointer;color:var(--n-muted);font-size:.9rem;" title="Show/hide">👁</span>
          </div>
        </div>

        <button class="kn-btn-primary" id="kn-submit">
          Sign In →
        </button>

        <div class="kn-login-links">
          ${forgotLink ? `<a href="${forgotLink.href}">Forgot password?</a>` : '<span></span>'}
          <a href="/auth/register" style="display:none">Create account</a>
        </div>
      </div>
    `;

    document.body.appendChild(wrap);

    // Toggle password visibility
    const eye     = q('#kn-eye');
    const passInp = q('#kn-pass');
    eye.addEventListener('click', () => {
      passInp.type = passInp.type === 'password' ? 'text' : 'password';
    });

    // Submit — inject ke form asli dan submit
    const btn = q('#kn-submit');
    btn.addEventListener('click', () => {
      const errBox = q('#kn-error-box');
      const user   = q('#kn-user').value.trim();
      const pass   = q('#kn-pass').value;

      errBox.style.display = 'none';

      if (!user || !pass) {
        errBox.textContent = 'Please enter your email and password.';
        errBox.style.display = 'block';
        return;
      }

      btn.disabled = true;
      btn.textContent = 'Signing in…';

      // Isi form asli
      if (emailInput)    { emailInput.value    = user; }
      if (passwordInput) { passwordInput.value = pass; }

      // Trigger submit
      if (submitBtn) {
        submitBtn.click();
      } else {
        existingForm.submit();
      }
    });

    // Enter key
    [q('#kn-user'), q('#kn-pass')].forEach(inp => {
      inp?.addEventListener('keydown', e => { if (e.key === 'Enter') btn.click(); });
    });

    // Fokus otomatis
    setTimeout(() => q('#kn-user')?.focus(), 100);
  }

  /* ── upgrade server list cards ── */
  function upgradeServerCards() {
    // Cari semua server link cards yang ada
    const cards = qq('[class*="server"][class*="bg"], a[href*="/server/"]');
    if (!cards.length) return;

    cards.forEach(card => {
      if (card.dataset.knUpgraded) return;
      card.dataset.knUpgraded = '1';

      const name     = q('[class*="name"], h3, h4, .font-bold, [class*="title"]', card)?.textContent?.trim() || 'Server';
      const desc     = q('[class*="desc"], p, .text-sm', card)?.textContent?.trim() || '';
      const href     = card.tagName === 'A' ? card.href : (q('a', card)?.href || '#');

      // Baca status dari kelas atau data attribute
      let status = 'offline';
      const statusEl = q('[class*="status"], [data-status]', card);
      if (statusEl) {
        const txt = (statusEl.textContent || statusEl.dataset.status || '').toLowerCase();
        if (txt.includes('run') || txt.includes('online')) status = 'running';
        else if (txt.includes('start'))                    status = 'starting';
        else if (txt.includes('stop'))                     status = 'stopping';
      }

      const statusLabel = { running: 'Online', offline: 'Offline', starting: 'Starting…', stopping: 'Stopping…' }[status];

      const newCard = el('a', 'kn-server-card');
      newCard.href  = href;
      newCard.innerHTML = `
        <div class="kn-server-head">
          <div class="kn-server-icon">${ICONS.server}</div>
          <div class="kn-server-status-row">
            <div class="kn-status-dot ${status}"></div>
            <span>${statusLabel}</span>
          </div>
        </div>
        <div class="kn-server-name">${name}</div>
        <div class="kn-server-desc">${desc || 'No description'}</div>
        <div class="kn-resource-bars">
          <div class="kn-res-row">
            <div class="kn-res-label"><span>CPU</span><span class="kn-cpu-val">—</span></div>
            <div class="kn-res-track"><div class="kn-res-fill cpu kn-cpu-bar" style="width:0%"></div></div>
          </div>
          <div class="kn-res-row">
            <div class="kn-res-label"><span>RAM</span><span class="kn-ram-val">—</span></div>
            <div class="kn-res-track"><div class="kn-res-fill ram kn-ram-bar" style="width:0%"></div></div>
          </div>
        </div>
        <div class="kn-server-foot">
          <span class="kn-chip ${status === 'running' ? 'green' : status === 'offline' ? 'red' : 'yellow'}">
            ${status === 'running' ? '▶ Running' : status === 'offline' ? '■ Offline' : '◌ ' + statusLabel}
          </span>
          <span>${ICONS.console} Console</span>
        </div>
      `;

      // Coba ambil data resource dari atribut data di card lama
      const cpuEl  = q('[data-cpu], [class*="cpu"]', card);
      const ramEl  = q('[data-memory], [data-ram], [class*="memory"], [class*="ram"]', card);
      if (cpuEl) {
        const v = parseFloat(cpuEl.textContent || cpuEl.dataset.cpu || '0');
        newCard.querySelector('.kn-cpu-val').textContent = v.toFixed(1) + '%';
        newCard.querySelector('.kn-cpu-bar').style.width  = Math.min(v, 100) + '%';
      }
      if (ramEl) {
        const v = parseFloat(ramEl.textContent || ramEl.dataset.memory || '0');
        newCard.querySelector('.kn-ram-val').textContent = v.toFixed(0) + ' MB';
        newCard.querySelector('.kn-ram-bar').style.width  = '0%';
      }

      card.replaceWith(newCard);
    });
  }

  /* ── wrap server list into grid ── */
  function wrapServerGrid() {
    if (q('.kn-servers')) return;
    const cards = qq('.kn-server-card');
    if (!cards.length) return;
    const grid = el('div', 'kn-servers');
    cards[0].parentNode.insertBefore(grid, cards[0]);
    cards.forEach(c => grid.appendChild(c));
  }

  /* ── upgrade sidebar on server detail ── */
  function upgradeServerSidebar() {
    if (q('.kn-sidebar')) return;
    const existingSidebar = q('aside, [class*="sidebar"], [class*="Sidebar"]');
    if (!existingSidebar) return;

    const currentPath  = window.location.pathname;
    const serverIdMatch = currentPath.match(/\/server\/([^/]+)/);
    if (!serverIdMatch) return;
    const sid = serverIdMatch[1];

    const navItems = [
      { href: `/server/${sid}`,           icon: ICONS.console,   label: 'Console'    },
      { href: `/server/${sid}/files`,      icon: ICONS.file,      label: 'Files'      },
      { href: `/server/${sid}/databases`,  icon: ICONS.database,  label: 'Databases'  },
      { href: `/server/${sid}/schedules`,  icon: ICONS.schedule,  label: 'Schedules'  },
      { href: `/server/${sid}/users`,      icon: ICONS.users,     label: 'Users'      },
      { href: `/server/${sid}/backups`,    icon: '💾',            label: 'Backups'    },
      { href: `/server/${sid}/network`,    icon: ICONS.network,   label: 'Network'    },
      { href: `/server/${sid}/startup`,    icon: ICONS.startup,   label: 'Startup'    },
      { href: `/server/${sid}/settings`,   icon: ICONS.settings,  label: 'Settings'   },
      { href: `/server/${sid}/activity`,   icon: ICONS.activity,  label: 'Activity'   },
    ];

    const sidebar = el('aside', 'kn-sidebar');
    sidebar.innerHTML = `
      <div class="kn-sidebar-section">Navigation</div>
      ${navItems.map(item => `
        <a href="${item.href}"
           class="kn-sidebar-link ${currentPath === item.href ? 'active' : ''}">
          <span class="kn-sidebar-icon">${item.icon}</span>
          ${item.label}
        </a>
      `).join('')}
      <div class="kn-sidebar-section" style="margin-top:1rem">Quick</div>
      <a href="/" class="kn-sidebar-link">${ICONS.back} All Servers</a>
    `;

    existingSidebar.parentNode.insertBefore(sidebar, existingSidebar);
    existingSidebar.style.display = 'none';
  }

  /* ── upgrade console wrapper ── */
  function upgradeConsole() {
    const terms = qq('[class*="xterm"], .terminal, [class*="terminal"]');
    terms.forEach(t => {
      if (t.closest('.kn-console-wrap')) return;
      const wrap = el('div', 'kn-console-wrap');
      const header = el('div', 'kn-console-header');
      header.innerHTML = `
        <div class="kn-console-dots">
          <div class="kn-console-dot"></div>
          <div class="kn-console-dot"></div>
          <div class="kn-console-dot"></div>
        </div>
        <span class="kn-console-title">${ICONS.console} Server Console</span>
        <span style="font-size:.7rem;color:var(--n-muted);">Kahfitzy Nebula</span>
      `;
      t.parentNode.insertBefore(wrap, t);
      wrap.appendChild(header);
      wrap.appendChild(t);
    });
  }

  /* ── main init ── */
  function init() {
    const page = getPage();

    document.documentElement.classList.add('kn-nebula-pro');
    rebrand(document.body);
    injectTopbar(page);

    if (page === 'login') {
      injectLogin();
      return;
    }

    if (page === 'servers') {
      upgradeServerCards();
      wrapServerGrid();
    }

    if (page.startsWith('server-')) {
      upgradeServerSidebar();
      upgradeConsole();
    }
  }

  /* ── run ── */
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

  /* ── observe React re-renders ── */
  let rafId = null;
  const observer = new MutationObserver(() => {
    if (rafId) cancelAnimationFrame(rafId);
    rafId = requestAnimationFrame(() => {
      rebrand(document.body);
      const page = getPage();
      if (page === 'servers')             { upgradeServerCards(); wrapServerGrid(); }
      if (page.startsWith('server-'))     { upgradeServerSidebar(); upgradeConsole(); }
    });
  });
  observer.observe(document.documentElement, { childList: true, subtree: true });

})();
ENDJS
  ok "JS Nebula v6 ditulis."
}

apply_nebula_theme() {
  [[ -f "$PANEL_DIR/artisan" ]] || die "Panel belum valid di $PANEL_DIR. Install panel dulu."

  info "Apply Nebula Pro v6 Theme (full custom UI)..."
  write_nebula_css
  write_nebula_js

  # Cari blade wrapper
  local blade=""
  if [[ -f "$PANEL_DIR/resources/views/templates/wrapper.blade.php" ]]; then
    blade="$PANEL_DIR/resources/views/templates/wrapper.blade.php"
  else
    blade="$(grep -RIl 'id="app"\|id='"'"'app'"'"'\|</head>' \
      "$PANEL_DIR/resources/views" 2>/dev/null | head -n 1 || true)"
  fi

  [[ -n "$blade" && -f "$blade" ]] || die "File blade wrapper tidak ditemukan."

  # Backup
  cp -n "$blade" "${blade}.backup-kn-v6"

  # Inject (hapus inject lama dulu, masukkan yang baru)
  python3 - "$blade" << 'PY'
import sys, pathlib, re
path = pathlib.Path(sys.argv[1])
text = path.read_text()

# Hapus injeksi versi lama
for pat in [
    r'\n?\s*<!-- KAHFITZY_STELLAR_THEME_START -->.*?<!-- KAHFITZY_STELLAR_THEME_END -->\s*\n?',
    r'\n?\s*<!-- KAHFITZY_NEBULA_THEME_START -->.*?<!-- KAHFITZY_NEBULA_THEME_END -->\s*\n?',
]:
    text = re.sub(pat, '\n', text, flags=re.S)

insert = """
    <!-- KAHFITZY_NEBULA_THEME_START -->
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link rel="stylesheet" href="/kahfitzy-nebula/nebula.css?v=6.0.0">
    <script defer src="/kahfitzy-nebula/nebula.js?v=6.0.0"></script>
    <!-- KAHFITZY_NEBULA_THEME_END -->
"""

if "</head>" in text:
    text = text.replace("</head>", insert + "</head>", 1)
elif "</body>" in text:
    text = text.replace("</body>", insert + "</body>", 1)
else:
    text += insert

path.write_text(text)
print("Inject berhasil:", sys.argv[1])
PY

  cd "$PANEL_DIR"
  php artisan view:clear   || true
  php artisan cache:clear  || true
  php artisan config:clear || true
  setup_permissions
  systemctl reload nginx || true

  ok "✅ Nebula Pro v6 berhasil! Tampilan login dan server manager BEDA TOTAL."
  echo ""
  info "Yang berubah di v6:"
  info "  ✦ Halaman login: 2-panel design (branding kiri + form kanan)"
  info "  ✦ Animasi orbit + starfield di background"
  info "  ✦ Server list: grid card layout (bukan tabel)"
  info "  ✦ Per-card: status dot, CPU/RAM bar, chip status"
  info "  ✦ Sidebar server: icon nav baru, bukan sidebar pterodactyl"
  info "  ✦ Console: header custom dengan window dots"
  info "  ✦ Font: Inter + Space Grotesk"
}

install_panel_custom() {
  banner
  need_root
  detect_os

  echo -e "${CYAN}Masukkan data Panel custom kamu${NC}"
  read -r -p "Domain panel, contoh panel.domain.com: " PANEL_DOMAIN
  read -r -p "Email admin: " ADMIN_EMAIL
  read -r -p "Username admin [admin]: " ADMIN_USER
  ADMIN_USER="${ADMIN_USER:-admin}"
  read -r -s -p "Password admin panel, kosongkan untuk auto-generate: " ADMIN_PASS
  echo ""
  ADMIN_PASS="${ADMIN_PASS:-$(random_string 14)}"
  DB_PASS="$(random_string 32)"

  [[ -n "$PANEL_DOMAIN" ]] || die "Domain wajib diisi."
  [[ -n "$ADMIN_EMAIL" ]]  || die "Email admin wajib diisi."

  install_dependencies

  set +e
  install_panel_files
  local panel_status=$?
  set -e

  if [[ "$panel_status" -ne 10 ]]; then
    setup_database "$DB_PASS"
    write_env "$PANEL_DOMAIN" "$ADMIN_EMAIL" "$DB_PASS"

    cd "$PANEL_DIR"
    info "Generate APP_KEY..."
    php artisan key:generate --force
    info "Migrasi database..."
    php artisan migrate --seed --force

    create_admin_user "$ADMIN_EMAIL" "$ADMIN_USER" "$ADMIN_PASS"
    setup_permissions
    setup_cron_and_queue
    setup_nginx "$PANEL_DOMAIN"
  fi

  apply_nebula_theme
  setup_ssl "$PANEL_DOMAIN" "$ADMIN_EMAIL"

  echo ""
  ok "╔══════════════════════════════════════════╗"
  ok "  INSTALL SELESAI — KAHFITZY NEBULA PRO v6"
  ok "╚══════════════════════════════════════════╝"
  echo -e "${GREEN}URL Panel :${NC} https://${PANEL_DOMAIN}"
  echo -e "${GREEN}Username  :${NC} ${ADMIN_USER}"
  echo -e "${GREEN}Email     :${NC} ${ADMIN_EMAIL}"
  echo -e "${GREEN}Password  :${NC} ${ADMIN_PASS}"
  echo -e "${YELLOW}Simpan password ini! Tidak ditampilkan lagi.${NC}"
}

install_wings() {
  banner
  need_root
  detect_os

  info "Install Docker dan Wings..."
  apt_base
  apt-get install -y docker.io
  systemctl enable --now docker

  mkdir -p /etc/pterodactyl /var/lib/pterodactyl
  local arch="amd64"
  [[ "$(uname -m)" == "aarch64" || "$(uname -m)" == "arm64" ]] && arch="arm64"

  curl -L -o /usr/local/bin/wings \
    "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${arch}"
  chmod u+x /usr/local/bin/wings

  cat > /etc/systemd/system/wings.service << 'EOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable wings

  warn "Wings terinstall. Buat Node di Panel > ambil config > paste ke /etc/pterodactyl/config.yml"
  warn "Lalu: systemctl restart wings"
}

status_services() {
  banner
  echo "Panel dir: $PANEL_DIR"
  [[ -f "$PANEL_DIR/artisan" ]] && ok "Panel ditemukan" || warn "Panel belum ditemukan"
  systemctl --no-pager --type=service --state=running \
    | grep -E 'nginx|mariadb|redis|php.*fpm|pteroq|wings' || true
}

repair_panel() {
  banner
  [[ -f "$PANEL_DIR/artisan" ]] || die "Panel tidak ditemukan di $PANEL_DIR"
  cd "$PANEL_DIR"
  info "Repair cache/permission/service panel..."
  php artisan optimize:clear || true
  php artisan view:clear || true
  php artisan cache:clear || true
  setup_permissions
  systemctl restart php${PHP_VER}-fpm nginx pteroq || true
  ok "Repair selesai."
}

menu() {
  while true; do
    banner
    echo "1. Install Panel + Nebula Pro v6 (Full Custom UI)"
    echo "2. Install Wings"
    echo "3. Install Panel + Wings + Theme"
    echo "4. Re-Apply Nebula Pro v6 Theme"
    echo "5. Repair Panel"
    echo "6. Status Services"
    echo "0. Exit"
    echo ""
    read -r -p "Pilih menu: " pilih
    case "$pilih" in
      1) install_panel_custom; break ;;
      2) install_wings; break ;;
      3) install_panel_custom; install_wings; break ;;
      4) need_root; apply_nebula_theme; break ;;
      5) repair_panel; break ;;
      6) status_services; break ;;
      0) exit 0 ;;
      *) warn "Pilihan tidak valid"; sleep 1 ;;
    esac
  done
}

menu
ENDOFSCRIPT

chmod +x /home/claude/pterodactyl-nebula-all-in-one-installer-v6.sh
echo "Script written. Lines:"
wc -l /home/claude/pterodactyl-nebula-all-in-one-installer-v6.sh