#!/usr/bin/env bash
# Pterodactyl Auto Installer
# Support: Ubuntu 22.04/24.04, Debian 12/13
# Author: Custom installer template
# Usage:
#   bash install.sh
#   or: curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/install.sh -o install.sh && bash install.sh

set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

PANEL_DIR="/var/www/pterodactyl"
LOG_FILE="/var/log/ptero-installer.log"
PHP_VER="8.3"
DB_NAME="panel"
DB_USER="pterodactyl"
DEFAULT_TZ="Asia/Jakarta"

OS_ID=""
OS_VERSION=""
OS_CODENAME=""
APP_URL=""
PANEL_DOMAIN=""
ADMIN_EMAIL=""
ADMIN_USER=""
ADMIN_PASS=""
DB_PASS=""
SSL_MODE="yes"

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
NC="\033[0m"

touch "$LOG_FILE"

on_error() {
  local exit_code=$?
  echo -e "${RED}Installer gagal di line $1. Exit code: ${exit_code}${NC}"
  echo -e "${YELLOW}Cek log: ${LOG_FILE}${NC}"
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

banner() {
  clear
  echo -e "${CYAN}"
  cat <<'EOF'
╔══════════════════════════════════════════════╗
   PTERODACTYL AUTO INSTALLER
   Ubuntu 22/24 • Debian 12/13 • Panel/Wings
╚══════════════════════════════════════════════╝
EOF
  echo -e "${NC}"
}

log() {
  echo -e "$1" | tee -a "$LOG_FILE"
}

ok() {
  log "${GREEN}✅ $1${NC}"
}

warn() {
  log "${YELLOW}⚠️  $1${NC}"
}

err() {
  log "${RED}❌ $1${NC}"
}

run() {
  log "${BLUE}CMD:${NC} $*"
  "$@" 2>&1 | tee -a "$LOG_FILE"
}

confirm() {
  local prompt="${1:-Lanjut?}"
  local ans
  read -r -p "$prompt [y/N]: " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Jalankan sebagai root."
    echo "Contoh: sudo bash install.sh"
    exit 1
  fi
}

need_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    err "Systemd tidak ditemukan. Installer ini butuh systemd."
    exit 1
  fi
}

detect_os() {
  if [[ ! -f /etc/os-release ]]; then
    err "Tidak bisa membaca /etc/os-release."
    exit 1
  fi

  # shellcheck disable=SC1091
  source /etc/os-release

  OS_ID="${ID:-}"
  OS_VERSION="${VERSION_ID:-}"
  OS_CODENAME="${VERSION_CODENAME:-$(lsb_release -sc 2>/dev/null || true)}"

  case "${OS_ID}:${OS_VERSION}" in
    ubuntu:22.04|ubuntu:24.04|debian:12|debian:13)
      ok "OS support terdeteksi: ${PRETTY_NAME:-$OS_ID $OS_VERSION}"
      ;;
    *)
      err "OS tidak support: ${PRETTY_NAME:-$OS_ID $OS_VERSION}"
      echo "Support: Ubuntu 22.04, Ubuntu 24.04, Debian 12, Debian 13"
      exit 1
      ;;
  esac
}

random_string() {
  local len="${1:-32}"
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len"
}

valid_domain() {
  local d="$1"
  [[ "$d" =~ ^[A-Za-z0-9.-]+$ ]] && [[ "$d" == *.* ]]
}

valid_email() {
  local e="$1"
  [[ "$e" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

prompt_panel_data() {
  echo ""
  log "${CYAN}Masukkan data Panel${NC}"

  while true; do
    read -r -p "Domain panel, contoh panel.domain.com: " PANEL_DOMAIN
    PANEL_DOMAIN="${PANEL_DOMAIN,,}"
    if valid_domain "$PANEL_DOMAIN"; then
      break
    fi
    warn "Domain tidak valid. Jangan pakai http:// atau https://"
  done

  APP_URL="https://${PANEL_DOMAIN}"

  while true; do
    read -r -p "Email admin: " ADMIN_EMAIL
    if valid_email "$ADMIN_EMAIL"; then
      break
    fi
    warn "Email tidak valid."
  done

  read -r -p "Username admin [admin]: " ADMIN_USER
  ADMIN_USER="${ADMIN_USER:-admin}"

  read -r -s -p "Password admin panel, kosongkan untuk auto-generate: " ADMIN_PASS
  echo ""
  if [[ -z "$ADMIN_PASS" ]]; then
    ADMIN_PASS="$(random_string 18)"
    ok "Password admin dibuat otomatis."
  fi

  DB_PASS="$(random_string 32)"

  read -r -p "Pakai SSL Let's Encrypt? [Y/n]: " SSL_MODE
  SSL_MODE="${SSL_MODE:-yes}"
  if [[ "$SSL_MODE" =~ ^[Nn]$ ]]; then
    APP_URL="http://${PANEL_DOMAIN}"
  fi

  echo ""
  log "${CYAN}Ringkasan:${NC}"
  echo "Domain     : $PANEL_DOMAIN"
  echo "URL        : $APP_URL"
  echo "Admin email: $ADMIN_EMAIL"
  echo "Username   : $ADMIN_USER"
  echo "Timezone   : $DEFAULT_TZ"
  echo ""
  if ! confirm "Data sudah benar?"; then
    err "Dibatalkan."
    exit 1
  fi
}

apt_prepare() {
  ok "Menyiapkan package dasar..."
  run apt-get update -y
  run apt-get install -y curl wget ca-certificates gnupg lsb-release apt-transport-https software-properties-common sudo unzip tar git jq ufw
}

setup_repositories() {
  ok "Menyiapkan repository sesuai OS..."

  if [[ "$OS_ID" == "ubuntu" && "$OS_VERSION" == "22.04" ]]; then
    run add-apt-repository -y ppa:ondrej/php

    # Redis official repo, aman untuk Ubuntu 22.04
    if [[ ! -f /usr/share/keyrings/redis-archive-keyring.gpg ]]; then
      curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
    fi
    echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb ${OS_CODENAME} main" > /etc/apt/sources.list.d/redis.list

  elif [[ "$OS_ID" == "debian" ]]; then
    # PHP Sury repo untuk Debian 12/13
    echo "deb https://packages.sury.org/php/ ${OS_CODENAME} main" > /etc/apt/sources.list.d/sury-php.list
    curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/sury-keyring.gpg

    if [[ "$OS_VERSION" == "12" ]]; then
      # Redis official repo untuk Debian 12
      if [[ ! -f /usr/share/keyrings/redis-archive-keyring.gpg ]]; then
        curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
      fi
      echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb ${OS_CODENAME} main" > /etc/apt/sources.list.d/redis.list

      # MariaDB repo untuk Debian 12 agar versi lebih aman
      curl -LsS https://r.mariadb.com/downloads/mariadb_repo_setup | bash
    fi
  fi

  run apt-get update -y
}

install_panel_dependencies() {
  ok "Install dependency Panel..."
  run apt-get install -y \
    php${PHP_VER} php${PHP_VER}-common php${PHP_VER}-cli php${PHP_VER}-gd \
    php${PHP_VER}-mysql php${PHP_VER}-mbstring php${PHP_VER}-bcmath \
    php${PHP_VER}-xml php${PHP_VER}-fpm php${PHP_VER}-curl php${PHP_VER}-zip \
    php${PHP_VER}-intl php${PHP_VER}-redis \
    mariadb-server mariadb-client nginx redis-server certbot python3-certbot-nginx

  run systemctl enable --now mariadb
  run systemctl enable --now redis-server
  run systemctl enable --now php${PHP_VER}-fpm
  run systemctl enable --now nginx

  install_composer
}

install_composer() {
  if command -v composer >/dev/null 2>&1; then
    ok "Composer sudah ada: $(composer --version 2>/dev/null || true)"
    return
  fi

  ok "Install Composer..."
  cd /tmp
  local expected actual
  expected="$(curl -fsSL https://composer.github.io/installer.sig)"
  php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
  actual="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"

  if [[ "$expected" != "$actual" ]]; then
    rm -f composer-setup.php
    err "Signature Composer tidak cocok."
    exit 1
  fi

  php composer-setup.php --install-dir=/usr/local/bin --filename=composer
  rm -f composer-setup.php
  ok "Composer berhasil diinstall."
}

backup_existing_panel() {
  if [[ -d "$PANEL_DIR" && -n "$(ls -A "$PANEL_DIR" 2>/dev/null || true)" ]]; then
    warn "Folder $PANEL_DIR sudah ada dan tidak kosong."
    if confirm "Backup lalu kosongkan folder ini untuk install baru?"; then
      local backup="/root/pterodactyl-panel-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
      tar -czf "$backup" -C "$PANEL_DIR" . || true
      ok "Backup dibuat: $backup"
      rm -rf "${PANEL_DIR:?}/"*
    else
      err "Install Panel dibatalkan supaya data lama aman."
      exit 1
    fi
  fi
}

create_database() {
  ok "Membuat database Panel..."

  mariadb -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

  ok "Database siap."
}

set_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  local escaped
  escaped="$(printf '%s' "$value" | sed -e 's/[\/&]/\\&/g')"

  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${escaped}|g" "$file"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

download_panel_files() {
  ok "Download file Panel..."
  mkdir -p "$PANEL_DIR"
  cd "$PANEL_DIR"

  curl -L -o panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
  tar -xzvf panel.tar.gz
  rm -f panel.tar.gz

  chmod -R 755 storage/* bootstrap/cache/
  cp .env.example .env
}

configure_panel_env() {
  ok "Install dependency composer Panel..."
  cd "$PANEL_DIR"
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader

  ok "Generate APP_KEY..."
  php artisan key:generate --force

  ok "Setup environment Panel..."
  local env_args
  env_args=(
    p:environment:setup
    "--author=${ADMIN_EMAIL}"
    "--url=${APP_URL}"
    "--timezone=${DEFAULT_TZ}"
    "--cache=redis"
    "--session=database"
    "--queue=redis"
    "--redis-host=127.0.0.1"
    "--redis-pass=null"
    "--redis-port=6379"
  )

  if php artisan p:environment:setup --help | grep -q -- "--settings-ui"; then
    env_args+=("--settings-ui=1")
  fi

  if ! php artisan "${env_args[@]}"; then
    warn "Setup environment otomatis gagal, fallback tulis .env manual."
    set_env_value .env APP_URL "$APP_URL"
    set_env_value .env APP_TIMEZONE "$DEFAULT_TZ"
    set_env_value .env CACHE_DRIVER redis
    set_env_value .env QUEUE_CONNECTION redis
    set_env_value .env SESSION_DRIVER database
    set_env_value .env REDIS_HOST 127.0.0.1
    set_env_value .env REDIS_PASSWORD null
    set_env_value .env REDIS_PORT 6379
  fi

  ok "Setup database environment..."
  if ! php artisan p:environment:database \
    --host=127.0.0.1 \
    --port=3306 \
    --database="$DB_NAME" \
    --username="$DB_USER" \
    --password="$DB_PASS"; then
    warn "Setup DB otomatis gagal, fallback tulis .env manual."
    set_env_value .env DB_CONNECTION mysql
    set_env_value .env DB_HOST 127.0.0.1
    set_env_value .env DB_PORT 3306
    set_env_value .env DB_DATABASE "$DB_NAME"
    set_env_value .env DB_USERNAME "$DB_USER"
    set_env_value .env DB_PASSWORD "$DB_PASS"
  fi

  # Mail default dibuat log/mail supaya panel tetap bisa jalan tanpa SMTP.
  set_env_value .env MAIL_MAILER log
  set_env_value .env MAIL_DRIVER log
  set_env_value .env MAIL_FROM "$ADMIN_EMAIL"
  set_env_value .env MAIL_FROM_ADDRESS "$ADMIN_EMAIL"
  set_env_value .env MAIL_FROM_NAME Pterodactyl

  ok "Migrasi database dan seed eggs..."
  php artisan migrate --seed --force

  ok "Membuat user admin..."
  if ! php artisan p:user:make \
    --email="$ADMIN_EMAIL" \
    --username="$ADMIN_USER" \
    --name-first=Admin \
    --name-last=User \
    --password="$ADMIN_PASS" \
    --admin=1; then
    warn "User admin mungkin sudah ada. Lewati pembuatan user."
  fi

  chown -R www-data:www-data "$PANEL_DIR"/*
}

setup_queue_and_cron() {
  ok "Setup cron scheduler dan queue worker..."

  cat > /etc/cron.d/pterodactyl-schedule <<EOF
* * * * * www-data php ${PANEL_DIR}/artisan schedule:run >> /dev/null 2>&1
EOF

  cat > /etc/systemd/system/pteroq.service <<EOF
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php ${PANEL_DIR}/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now pteroq
  ok "Queue worker aktif."
}

write_nginx_http_config() {
  local domain="$1"

  rm -f /etc/nginx/sites-enabled/default || true

  cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
server {
    listen 80;
    server_name ${domain};

    root ${PANEL_DIR}/public;
    index index.php index.html index.htm;
    charset utf-8;

    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
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

  ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
  nginx -t
  systemctl reload nginx
}

write_nginx_ssl_config() {
  local domain="$1"

  cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
server {
    listen 80;
    server_name ${domain};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${domain};

    root ${PANEL_DIR}/public;
    index index.php;
    charset utf-8;

    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Robots-Tag none;
    add_header Content-Security-Policy "frame-ancestors 'self'";
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
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
        include /etc/nginx/fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

  ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
  nginx -t
  systemctl reload nginx
}

setup_nginx_and_ssl() {
  ok "Setup Nginx Panel..."
  write_nginx_http_config "$PANEL_DOMAIN"

  if [[ "$SSL_MODE" =~ ^[Yy] || "$SSL_MODE" == "yes" ]]; then
    ok "Request SSL Let's Encrypt..."
    if certbot certonly --nginx -d "$PANEL_DOMAIN" --non-interactive --agree-tos -m "$ADMIN_EMAIL"; then
      write_nginx_ssl_config "$PANEL_DOMAIN"
      set_env_value "$PANEL_DIR/.env" APP_URL "https://${PANEL_DOMAIN}"
      ok "SSL aktif untuk ${PANEL_DOMAIN}"
    else
      warn "SSL gagal. Panel tetap jalan mode HTTP. Pastikan DNS domain mengarah ke IP VPS dan port 80/443 terbuka."
      set_env_value "$PANEL_DIR/.env" APP_URL "http://${PANEL_DOMAIN}"
      write_nginx_http_config "$PANEL_DOMAIN"
    fi
  fi

  systemctl restart nginx
}

open_firewall_basic() {
  ok "Membuka port dasar firewall jika UFW aktif/tersedia..."

  if command -v ufw >/dev/null 2>&1; then
    ufw allow OpenSSH || true
    ufw allow 22/tcp || true
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true
    ufw allow 8080/tcp || true
    ufw allow 2022/tcp || true
    ok "Port dibuka: 22, 80, 443, 8080, 2022"
  fi
}

install_panel() {
  banner
  need_root
  need_systemd
  detect_os
  prompt_panel_data
  apt_prepare
  setup_repositories
  install_panel_dependencies
  backup_existing_panel
  create_database
  download_panel_files
  configure_panel_env
  setup_queue_and_cron
  setup_nginx_and_ssl
  open_firewall_basic
  panel_summary
}

check_virtualization_for_wings() {
  local virt
  virt="$(systemd-detect-virt 2>/dev/null || true)"

  if [[ "$virt" =~ openvz|lxc|lxc-libvirt ]]; then
    warn "Virtualisasi terdeteksi: $virt"
    warn "Wings/Docker sering gagal di OpenVZ/LXC."
    if ! confirm "Tetap lanjut install Wings?"; then
      exit 1
    fi
  else
    ok "Virtualisasi terdeteksi: ${virt:-none}. Lanjut Wings."
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    ok "Docker sudah ada: $(docker --version)"
  else
    ok "Install Docker..."
    curl -sSL https://get.docker.com/ | CHANNEL=stable bash
  fi

  systemctl enable --now docker
}

download_wings() {
  ok "Download Wings binary..."
  local arch
  case "$(uname -m)" in
    x86_64|amd64)
      arch="amd64"
      ;;
    aarch64|arm64)
      arch="arm64"
      ;;
    *)
      err "Arsitektur tidak support untuk auto download Wings: $(uname -m)"
      exit 1
      ;;
  esac

  mkdir -p /etc/pterodactyl
  curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${arch}"
  chmod u+x /usr/local/bin/wings
  ok "Wings terpasang di /usr/local/bin/wings"
}

create_wings_service() {
  ok "Membuat wings.service..."

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
}

paste_wings_config() {
  banner
  need_root
  mkdir -p /etc/pterodactyl

  echo -e "${YELLOW}Paste config.yml Wings dari Panel.${NC}"
  echo "Di Panel: Admin Area > Nodes > pilih node > Configuration"
  echo "Paste semuanya di bawah ini."
  echo "Kalau sudah selesai, tekan CTRL+D."
  echo ""

  cat > /etc/pterodactyl/config.yml

  if [[ ! -s /etc/pterodactyl/config.yml ]]; then
    warn "config.yml kosong, tidak disimpan."
    rm -f /etc/pterodactyl/config.yml
    return
  fi

  chmod 600 /etc/pterodactyl/config.yml
  ok "Config tersimpan: /etc/pterodactyl/config.yml"

  if systemctl list-unit-files | grep -q '^wings.service'; then
    systemctl restart wings || true
    systemctl status wings --no-pager || true
  fi
}

install_wings() {
  banner
  need_root
  need_systemd
  detect_os
  apt_prepare
  check_virtualization_for_wings
  install_docker
  download_wings
  create_wings_service
  open_firewall_basic

  echo ""
  if confirm "Mau paste config.yml Wings sekarang?"; then
    paste_wings_config
  else
    warn "Wings belum bisa running normal sebelum /etc/pterodactyl/config.yml diisi dari Panel."
  fi

  wings_summary
}

repair_panel() {
  banner
  need_root

  if [[ ! -d "$PANEL_DIR" ]]; then
    err "Folder Panel tidak ditemukan: $PANEL_DIR"
    exit 1
  fi

  ok "Repair Panel..."
  cd "$PANEL_DIR"

  chown -R www-data:www-data "$PANEL_DIR"/*
  chmod -R 755 storage/* bootstrap/cache/

  sudo -u www-data php artisan optimize:clear || true
  sudo -u www-data php artisan config:clear || true
  sudo -u www-data php artisan cache:clear || true
  sudo -u www-data php artisan view:clear || true

  systemctl restart php${PHP_VER}-fpm || true
  systemctl restart redis-server || true
  systemctl restart pteroq || true
  nginx -t && systemctl restart nginx

  ok "Repair Panel selesai."
}

repair_wings() {
  banner
  need_root

  ok "Repair Wings..."
  mkdir -p /etc/pterodactyl /var/lib/pterodactyl /var/log/pterodactyl
  systemctl daemon-reload
  systemctl restart docker || true

  if [[ -f /etc/pterodactyl/config.yml ]]; then
    systemctl restart wings || true
  else
    warn "/etc/pterodactyl/config.yml belum ada. Paste config dulu dari menu."
  fi

  systemctl status wings --no-pager || true
}

show_status() {
  banner
  echo -e "${CYAN}Status service:${NC}"
  for svc in nginx php${PHP_VER}-fpm mariadb redis-server pteroq docker wings; do
    if systemctl list-unit-files | grep -q "^${svc}.service"; then
      printf "%-18s : " "$svc"
      systemctl is-active "$svc" || true
    fi
  done

  echo ""
  echo -e "${CYAN}Port listen:${NC}"
  ss -tulpn | grep -E ':(80|443|8080|2022|3306|6379)\b' || true

  echo ""
  echo -e "${CYAN}Log penting:${NC}"
  echo "Installer : $LOG_FILE"
  echo "Panel     : /var/log/nginx/pterodactyl.app-error.log"
  echo "Wings     : journalctl -u wings -n 100 --no-pager"
}

safe_uninstall() {
  banner
  need_root

  warn "Menu ini bisa menghapus service/file Panel/Wings."
  echo "Tidak akan menghapus database kecuali kamu ketik DELETE_DB."
  echo ""

  if ! confirm "Lanjut uninstall service dan file?"; then
    exit 0
  fi

  systemctl stop pteroq wings nginx php${PHP_VER}-fpm || true
  systemctl disable pteroq wings || true

  rm -f /etc/systemd/system/pteroq.service
  rm -f /etc/systemd/system/wings.service
  rm -f /etc/cron.d/pterodactyl-schedule
  rm -f /etc/nginx/sites-enabled/pterodactyl.conf
  rm -f /etc/nginx/sites-available/pterodactyl.conf
  systemctl daemon-reload

  if [[ -d "$PANEL_DIR" ]]; then
    local backup="/root/pterodactyl-panel-before-uninstall-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -czf "$backup" -C "$PANEL_DIR" . || true
    ok "Backup panel dibuat: $backup"
    rm -rf "$PANEL_DIR"
  fi

  if confirm "Hapus Wings binary dan config?"; then
    rm -f /usr/local/bin/wings
    rm -rf /etc/pterodactyl
  fi

  echo ""
  read -r -p "Ketik DELETE_DB untuk hapus database panel: " deldb
  if [[ "$deldb" == "DELETE_DB" ]]; then
    mariadb -u root <<SQL
DROP DATABASE IF EXISTS \`${DB_NAME}\`;
DROP USER IF EXISTS '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
    ok "Database dihapus."
  else
    warn "Database tidak dihapus."
  fi

  systemctl restart nginx || true
  ok "Uninstall selesai."
}

panel_summary() {
  echo ""
  echo -e "${GREEN}╔════════════════════════════════════╗${NC}"
  echo -e "${GREEN}   PANEL BERHASIL DIINSTALL${NC}"
  echo -e "${GREEN}╚════════════════════════════════════╝${NC}"
  echo "URL Panel       : $APP_URL"
  echo "Admin email     : $ADMIN_EMAIL"
  echo "Username        : $ADMIN_USER"
  echo "Password        : $ADMIN_PASS"
  echo "Database name   : $DB_NAME"
  echo "Database user   : $DB_USER"
  echo "Database pass   : $DB_PASS"
  echo ""
  echo -e "${YELLOW}SIMPAN DATA DI ATAS. Terutama password admin, DB password, dan APP_KEY.${NC}"
  echo "APP_KEY bisa dicek:"
  echo "grep APP_KEY ${PANEL_DIR}/.env"
  echo ""
}

wings_summary() {
  echo ""
  echo -e "${GREEN}╔════════════════════════════════════╗${NC}"
  echo -e "${GREEN}   WINGS INSTALL SELESAI${NC}"
  echo -e "${GREEN}╚════════════════════════════════════╝${NC}"
  echo "Config Wings : /etc/pterodactyl/config.yml"
  echo "Service      : systemctl status wings"
  echo "Log          : journalctl -u wings -n 100 --no-pager"
  echo ""
  echo "Port umum Wings:"
  echo "- 8080/tcp untuk Wings API"
  echo "- 2022/tcp untuk SFTP"
  echo "- port allocation game server sesuai node"
  echo ""
}

install_panel_and_wings() {
  install_panel
  echo ""
  if confirm "Panel selesai. Lanjut install Wings di VPS yang sama?"; then
    install_wings
  fi
}

main_menu() {
  while true; do
    banner
    echo "1. Install Panel"
    echo "2. Install Wings"
    echo "3. Install Panel + Wings"
    echo "4. Paste / Ganti config.yml Wings"
    echo "5. Status Service"
    echo "6. Repair Panel"
    echo "7. Repair Wings"
    echo "8. Safe Uninstall"
    echo "0. Exit"
    echo ""
    read -r -p "Pilih menu: " pilih

    case "$pilih" in
      1) install_panel ;;
      2) install_wings ;;
      3) install_panel_and_wings ;;
      4) paste_wings_config ;;
      5) show_status ;;
      6) repair_panel ;;
      7) repair_wings ;;
      8) safe_uninstall ;;
      0) exit 0 ;;
      *) warn "Pilihan tidak valid." ;;
    esac

    echo ""
    read -r -p "Tekan ENTER untuk kembali ke menu..."
  done
}

need_root
main_menu
