#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# KAHFITZY STELLAR PRO PTERODACTYL
# One command install: Pterodactyl Panel + Stellar custom theme
# Support: Ubuntu 22.04/24.04, Debian 12/13
# ============================================================

LOG_FILE="/var/log/kahfitzy-stellar-ptero-installer.log"
PANEL_DIR="/var/www/pterodactyl"
THEME_DIR="/var/www/pterodactyl/public/kahfitzy-stellar"
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
ok() { log "${GREEN}$*${NC}"; }
warn() { log "${YELLOW}$*${NC}"; }
info() { log "${CYAN}$*${NC}"; }

banner() {
  clear
  echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}   KAHFITZY STELLAR PRO PTERODACTYL${NC}"
  echo -e "${CYAN}   Panel custom theme v4, lebih clean dan premium${NC}"
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
  apt-get install -y apt-transport-https ca-certificates curl wget gnupg lsb-release software-properties-common sudo unzip tar git cron
}

setup_php_repo() {
  if [[ "$OS_ID" == "ubuntu" ]]; then
    info "Menambahkan repository PHP untuk Ubuntu..."
    LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
  else
    info "Menambahkan repository PHP untuk Debian..."
    install -d /etc/apt/keyrings
    curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/keyrings/sury-php.gpg
    echo "deb [signed-by=/etc/apt/keyrings/sury-php.gpg] https://packages.sury.org/php/ ${OS_CODENAME} main" > /etc/apt/sources.list.d/sury-php.list
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
    true|false|null|[0-9]* )
      printf '%s' "$value"
      return
      ;;
  esac

  # Value .env yang ada spasi wajib dikutip.
  # Contoh error lama: MAIL_FROM_NAME=Kahfitzy Stellar Panel
  if [[ "$value" =~ ^[A-Za-z0-9_@%+=:,.\/-]+$ ]]; then
    printf '%s' "$value"
  else
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
  fi
}
set_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  local formatted escaped

  formatted="$(env_format_value "$value")"
  escaped="$(printf '%s' "$formatted" | sed -e 's/[\/&]/\\&/g')"

  if grep -q "^${key}=" "$file"; then
    sed -i "s/^${key}=.*/${key}=${escaped}/" "$file"
  else
    echo "${key}=${formatted}" >> "$file"
  fi
}

write_env() {
  local domain="$1"
  local admin_email="$2"
  local db_pass="$3"
  local app_url="https://${domain}"

  cd "$PANEL_DIR"
  cp -n .env.example .env

  set_env_value .env APP_NAME "Kahfitzy Stellar Panel"
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
  set_env_value .env MAIL_FROM_NAME 'Kahfitzy Stellar Panel'
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
    warn "Kalau install sebelumnya gagal di .env / APP_KEY, pilih lanjut setup/repair."
    echo ""
    echo "1. Lanjutkan setup / repair panel yang belum selesai"
    echo "2. Apply theme saja"
    echo "0. Batal"
    read -r -p "Pilih: " EXISTING_CHOICE

    case "$EXISTING_CHOICE" in
      1)
        cd "$PANEL_DIR"
        info "Repair dependency composer panel..."
        COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction || true
        return 0
        ;;
      2)
        return 10
        ;;
      *)
        die "Dibatalkan."
        ;;
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
  local admin_email="$1"
  local admin_user="$2"
  local admin_pass="$3"

  cd "$PANEL_DIR"
  info "Membuat admin panel..."
  php artisan p:user:make \
    --email="$admin_email" \
    --username="$admin_user" \
    --name-first="Kahfitzy" \
    --name-last="Admin" \
    --password="$admin_pass" \
    --admin=1 \
    --no-interaction || warn "Gagal auto-create admin. Kamu bisa buat manual dengan: php artisan p:user:make"
}

setup_permissions() {
  chown -R www-data:www-data "$PANEL_DIR"
  find "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" -type d -exec chmod 775 {} \; || true
}

setup_cron_and_queue() {
  info "Setup cron dan queue worker..."
  (crontab -l 2>/dev/null | grep -v "pterodactyl/artisan schedule:run" || true; echo "* * * * * php $PANEL_DIR/artisan schedule:run >> /dev/null 2>&1") | crontab -

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

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
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

    location ~ /\.ht {
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
  local domain="$1"
  local email="$2"
  if confirm "Aktifkan SSL Let's Encrypt sekarang? Pastikan domain sudah mengarah ke IP VPS"; then
    info "Request SSL untuk $domain..."
    certbot --nginx -d "$domain" --non-interactive --agree-tos -m "$email" --redirect || warn "SSL gagal. Panel tetap jalan via HTTP. Cek DNS/firewall port 80/443."
    systemctl reload nginx || true
  else
    warn "SSL dilewati. APP_URL tetap https. Jika belum SSL, aktifkan nanti agar browser tidak error."
  fi
}

apply_stellar_theme() {
  [[ -f "$PANEL_DIR/artisan" ]] || die "Panel belum valid di $PANEL_DIR. Install panel dulu."

  info "Apply Stellar Pro Theme langsung ke panel..."
  mkdir -p "$THEME_DIR"

  cat > "$THEME_DIR/stellar.css" <<'CSS'
/* Kahfitzy Stellar Pro v4 - clean, tidak merusak layout Pterodactyl */
:root {
  --ks-bg-0: #050713;
  --ks-bg-1: #0a1022;
  --ks-card: rgba(10, 16, 34, .78);
  --ks-card-2: rgba(15, 23, 42, .72);
  --ks-line: rgba(255, 255, 255, .10);
  --ks-line-2: rgba(255, 255, 255, .16);
  --ks-text: #f8fafc;
  --ks-muted: #9aa7bd;
  --ks-orange: #ff8a00;
  --ks-violet: #7c3aed;
  --ks-blue: #38bdf8;
  --ks-green: #34d399;
  --ks-red: #fb7185;
}

html {
  background: var(--ks-bg-0) !important;
}

body {
  color: var(--ks-text) !important;
  background:
    radial-gradient(circle at 8% 8%, rgba(255, 138, 0, .20), transparent 28%),
    radial-gradient(circle at 92% 4%, rgba(124, 58, 237, .24), transparent 30%),
    radial-gradient(circle at 50% 100%, rgba(56, 189, 248, .14), transparent 36%),
    linear-gradient(180deg, #070a17 0%, #050713 50%, #080b18 100%) !important;
  background-attachment: fixed !important;
  overflow-x: hidden;
}

body::before {
  content: "";
  position: fixed;
  inset: 0;
  pointer-events: none;
  z-index: 0;
  background-image:
    linear-gradient(rgba(255,255,255,.028) 1px, transparent 1px),
    linear-gradient(90deg, rgba(255,255,255,.028) 1px, transparent 1px);
  background-size: 52px 52px;
  mask-image: linear-gradient(to bottom, rgba(0,0,0,.82), transparent 74%);
}

body::after {
  content: "";
  position: fixed;
  inset: auto -12% -28% -12%;
  height: 48vh;
  pointer-events: none;
  z-index: 0;
  background: radial-gradient(ellipse at center, rgba(255, 138, 0, .10), transparent 62%);
  filter: blur(28px);
}

#app {
  position: relative;
  z-index: 1;
  min-height: 100vh;
}

#app > div {
  background: transparent !important;
}

/* Panel shell / navbar */
nav, header, aside {
  background: rgba(5, 7, 19, .66) !important;
  border-color: var(--ks-line) !important;
  backdrop-filter: blur(18px) saturate(150%);
}

/* Card surfaces: target warna Pterodactyl, bukan semua div */
div[class*="bg-gray-900"], div[class*="bg-gray-800"], div[class*="bg-gray-700"],
div[class*="bg-neutral-900"], div[class*="bg-neutral-800"], div[class*="bg-neutral-700"],
div[class*="bg-slate-900"], div[class*="bg-slate-800"], div[class*="bg-slate-700"] {
  background: linear-gradient(180deg, rgba(15, 23, 42, .78), rgba(7, 10, 24, .68)) !important;
  border-color: var(--ks-line) !important;
  box-shadow: 0 18px 60px rgba(0, 0, 0, .22), inset 0 1px 0 rgba(255,255,255,.04) !important;
}

/* Jangan bikin kotak raksasa. Cuma haluskan border/radius elemen yang memang sudah rounded */
[class*="rounded"] {
  border-radius: 18px !important;
}

[class*="border"] {
  border-color: var(--ks-line) !important;
}

[class*="shadow"] {
  box-shadow: 0 18px 60px rgba(0,0,0,.24) !important;
}

/* Text */
[class*="text-gray-100"], [class*="text-neutral-100"], [class*="text-slate-100"] { color: #f8fafc !important; }
[class*="text-gray-200"], [class*="text-neutral-200"], [class*="text-slate-200"] { color: #e2e8f0 !important; }
[class*="text-gray-300"], [class*="text-neutral-300"], [class*="text-slate-300"],
[class*="text-gray-400"], [class*="text-neutral-400"], [class*="text-slate-400"] { color: var(--ks-muted) !important; }

/* Links and active states */
a {
  color: inherit;
  text-decoration: none !important;
}

a:hover {
  color: #fed7aa !important;
}

[class*="border-blue"], [class*="text-blue"], [class*="bg-blue"] {
  border-color: rgba(255, 138, 0, .75) !important;
}

/* Form */
input, textarea, select {
  background: rgba(2, 6, 23, .72) !important;
  border: 1px solid var(--ks-line) !important;
  color: var(--ks-text) !important;
  border-radius: 14px !important;
  box-shadow: inset 0 1px 0 rgba(255,255,255,.04) !important;
}

input::placeholder, textarea::placeholder {
  color: rgba(148, 163, 184, .75) !important;
}

input:focus, textarea:focus, select:focus {
  border-color: rgba(255, 138, 0, .85) !important;
  box-shadow: 0 0 0 3px rgba(255, 138, 0, .16) !important;
  outline: none !important;
}

/* Buttons */
button, a[role="button"], input[type="submit"] {
  border-radius: 14px !important;
  transition: transform .16s ease, box-shadow .16s ease, border-color .16s ease, filter .16s ease !important;
}

button:hover, a[role="button"]:hover, input[type="submit"]:hover {
  transform: translateY(-1px);
  filter: brightness(1.05);
}

button[class*="bg-blue"], a[class*="bg-blue"], input[type="submit"],
button[class*="bg-green"], a[class*="bg-green"] {
  background: linear-gradient(135deg, #ff8a00 0%, #ff4d00 45%, #7c3aed 100%) !important;
  border: 1px solid rgba(255,255,255,.16) !important;
  color: #fff !important;
  box-shadow: 0 12px 36px rgba(255, 102, 0, .20) !important;
}

button[class*="bg-red"], a[class*="bg-red"] {
  background: linear-gradient(135deg, #fb7185, #be123c) !important;
  border: 1px solid rgba(255,255,255,.14) !important;
}

/* Table/list */
table, thead, tbody, tr, td, th {
  border-color: rgba(255,255,255,.08) !important;
}

tr:hover, li:hover {
  background-color: rgba(255, 138, 0, .055) !important;
}

/* Server console */
.terminal, [class*="terminal"], [class*="Terminal"], [class*="console"], [class*="Console"] {
  background: rgba(2, 6, 23, .86) !important;
  border-color: rgba(255,255,255,.10) !important;
  box-shadow: 0 24px 90px rgba(0,0,0,.30) !important;
}

/* Auth/login page gets premium look without breaking dashboard */
body:has(form) form {
  border-color: var(--ks-line) !important;
}

/* Footer bawaan dibuat lebih clean */
footer, [class*="footer"] {
  color: rgba(226, 232, 240, .54) !important;
  border-color: rgba(255,255,255,.08) !important;
}

/* Hilangkan badge lama yang bikin ganggu */
.kahfitzy-stellar-badge {
  display: none !important;
}

/* Scrollbar */
::-webkit-scrollbar { width: 9px; height: 9px; }
::-webkit-scrollbar-track { background: rgba(2, 6, 23, .64); }
::-webkit-scrollbar-thumb {
  background: linear-gradient(180deg, #ff8a00, #7c3aed);
  border-radius: 999px;
}

/* Mobile: jangan sampai background/kotak jadi aneh di HP */
@media (max-width: 768px) {
  body::before { background-size: 38px 38px; opacity: .65; }
  [class*="rounded"] { border-radius: 14px !important; }
  button, a[role="button"], input, textarea, select { border-radius: 12px !important; }
}

CSS

  cat > "$THEME_DIR/stellar.js" <<'JS'
(function () {
  const BRAND = 'Kahfitzy Stellar';

  function replaceTextNode(node) {
    if (!node || !node.nodeValue) return;
    node.nodeValue = node.nodeValue
      .replace(/Pterodactyl®?/gi, BRAND)
      .replace(/pterodactyl/gi, BRAND);
  }

  function walkAndReplace(root) {
    const walker = document.createTreeWalker(root || document.body, NodeFilter.SHOW_TEXT, null);
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    nodes.forEach(replaceTextNode);
  }

  function apply() {
    document.documentElement.classList.add('kahfitzy-stellar-pro');
    document.title = document.title.replace(/Pterodactyl®?/gi, BRAND);

    document.querySelectorAll('.kahfitzy-stellar-badge').forEach(el => el.remove());
    walkAndReplace(document.body);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', apply);
  } else {
    apply();
  }

  let timer = null;
  const observer = new MutationObserver(() => {
    clearTimeout(timer);
    timer = setTimeout(apply, 120);
  });

  observer.observe(document.documentElement, { childList: true, subtree: true });
})();

JS

  local blade=""
  if [[ -f "$PANEL_DIR/resources/views/templates/wrapper.blade.php" ]]; then
    blade="$PANEL_DIR/resources/views/templates/wrapper.blade.php"
  else
    blade="$(grep -RIl "id=\"app\"\|id='app'\|</head>" "$PANEL_DIR/resources/views" 2>/dev/null | head -n 1 || true)"
  fi

  [[ -n "$blade" && -f "$blade" ]] || die "File blade wrapper tidak ditemukan. Theme gagal diinject."

  cp -n "$blade" "${blade}.backup-kahfitzy-stellar"

  python3 - "$blade" <<'PY'
import sys, pathlib, re
path = pathlib.Path(sys.argv[1])
text = path.read_text()
text = re.sub(r"\n?\s*<!-- KAHFITZY_STELLAR_THEME_START -->.*?<!-- KAHFITZY_STELLAR_THEME_END -->\s*\n?", "\n", text, flags=re.S)
insert = """
    <!-- KAHFITZY_STELLAR_THEME_START -->
    <link rel=\"stylesheet\" href=\"/kahfitzy-stellar/stellar.css?v=4.0.0\">
    <script defer src=\"/kahfitzy-stellar/stellar.js?v=4.0.0\"></script>
    <!-- KAHFITZY_STELLAR_THEME_END -->
"""
if "</head>" in text:
    text = text.replace("</head>", insert + "</head>", 1)
elif "</body>" in text:
    text = text.replace("</body>", insert + "</body>", 1)
else:
    text += insert
path.write_text(text)
PY

  cd "$PANEL_DIR"
  php artisan view:clear || true
  php artisan cache:clear || true
  php artisan config:clear || true
  setup_permissions
  systemctl reload nginx || true
  ok "Stellar Pro v4 sudah tertanam di panel. Bukan web kedua."
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
  [[ -n "$ADMIN_EMAIL" ]] || die "Email admin wajib diisi."

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

  apply_stellar_theme
  setup_ssl "$PANEL_DOMAIN" "$ADMIN_EMAIL"

  echo ""
  ok "INSTALL PANEL CUSTOM SELESAI"
  echo -e "${GREEN}URL Panel:${NC} https://${PANEL_DOMAIN}"
  echo -e "${GREEN}Username:${NC} ${ADMIN_USER}"
  echo -e "${GREEN}Email:${NC} ${ADMIN_EMAIL}"
  echo -e "${GREEN}Password:${NC} ${ADMIN_PASS}"
  echo -e "${YELLOW}Simpan password ini sekarang. Setelah keluar tidak ditampilkan lagi.${NC}"
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

  curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${arch}"
  chmod u+x /usr/local/bin/wings

  cat > /etc/systemd/system/wings.service <<'EOF'
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

  warn "Wings sudah terinstall."
  warn "Sekarang buat Node di Panel > ambil Configuration > paste ke /etc/pterodactyl/config.yml"
  warn "Lalu jalankan: systemctl restart wings"
}

status_services() {
  banner
  echo "Panel dir: $PANEL_DIR"
  [[ -f "$PANEL_DIR/artisan" ]] && ok "Panel ditemukan" || warn "Panel belum ditemukan"
  systemctl --no-pager --type=service --state=running | grep -E 'nginx|mariadb|redis|php.*fpm|pteroq|wings' || true
  echo ""
  systemctl is-active nginx 2>/dev/null || true
  systemctl is-active mariadb 2>/dev/null || true
  systemctl is-active redis-server 2>/dev/null || true
  systemctl is-active pteroq 2>/dev/null || true
  systemctl is-active wings 2>/dev/null || true
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
    echo "1. Install Panel Custom Stellar"
    echo "2. Install Wings"
    echo "3. Install Panel Custom Stellar + Wings"
    echo "4. Re-Apply Stellar Pro Theme"
    echo "5. Repair Panel"
    echo "6. Status"
    echo "0. Exit"
    echo ""
    read -r -p "Pilih menu: " pilih
    case "$pilih" in
      1) install_panel_custom; break ;;
      2) install_wings; break ;;
      3) install_panel_custom; install_wings; break ;;
      4) need_root; apply_stellar_theme; break ;;
      5) repair_panel; break ;;
      6) status_services; break ;;
      0) exit 0 ;;
      *) warn "Pilihan tidak valid"; sleep 1 ;;
    esac
  done
}

menu
