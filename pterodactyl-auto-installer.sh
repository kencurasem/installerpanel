#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
#  Stellar Theme Patcher for Pterodactyl Panel
#  Fungsi:
#  - Mengubah tampilan web Pterodactyl menjadi dark/stellar style
#  - TIDAK mengubah engine, database, user, server, node, egg, atau Wings
#  - Bisa restore / hapus theme
# ==========================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PANEL_DIR="${PANEL_DIR:-/var/www/pterodactyl}"
THEME_SLUG="kahfitzy-stellar-theme"
MARK_START="KAHFITZY_STELLAR_THEME_START"
MARK_END="KAHFITZY_STELLAR_THEME_END"

trap 'echo -e "${RED}Error di line $LINENO. Cek command terakhir.${NC}"' ERR

say() { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }
bad() { echo -e "${RED}$*${NC}"; }
info() { echo -e "${CYAN}$*${NC}"; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    bad "Jalankan sebagai root."
    exit 1
  fi
}

detect_panel_dir() {
  if [[ ! -f "$PANEL_DIR/artisan" ]]; then
    warn "Folder default tidak ditemukan: $PANEL_DIR"
    read -rp "Masukkan path Pterodactyl panel, contoh /var/www/pterodactyl: " input_dir
    PANEL_DIR="${input_dir:-/var/www/pterodactyl}"
  fi

  if [[ ! -f "$PANEL_DIR/artisan" || ! -d "$PANEL_DIR/public" ]]; then
    bad "Ini bukan folder Pterodactyl panel yang valid: $PANEL_DIR"
    bad "Pastikan Pterodactyl sudah terinstall dulu."
    exit 1
  fi
}

find_head_file() {
  local candidates=(
    "$PANEL_DIR/resources/views/templates/base/core.blade.php"
    "$PANEL_DIR/resources/views/layouts/app.blade.php"
    "$PANEL_DIR/resources/views/index.blade.php"
    "$PANEL_DIR/resources/views/welcome.blade.php"
  )

  for f in "${candidates[@]}"; do
    if [[ -f "$f" ]] && grep -qi '</head>' "$f"; then
      echo "$f"
      return 0
    fi
  done

  local found
  found="$(grep -Ril '</head>' "$PANEL_DIR/resources/views" 2>/dev/null | head -n 1 || true)"
  if [[ -n "$found" ]]; then
    echo "$found"
    return 0
  fi

  return 1
}

write_theme_files() {
  local theme_dir="$PANEL_DIR/public/$THEME_SLUG"
  mkdir -p "$theme_dir"

  cat > "$theme_dir/stellar.css" <<'CSS'
/* ==========================================================
   Kahfitzy Stellar Theme for Pterodactyl
   Safe visual layer only. Engine tetap Pterodactyl.
   ========================================================== */

:root {
  --stellar-bg-0: #05050b;
  --stellar-bg-1: #080816;
  --stellar-bg-2: #10102a;
  --stellar-card: rgba(15, 17, 34, .74);
  --stellar-card-2: rgba(22, 25, 48, .86);
  --stellar-border: rgba(255, 255, 255, .10);
  --stellar-border-strong: rgba(255, 164, 76, .34);
  --stellar-text: #f7f7fb;
  --stellar-muted: #aeb1c7;
  --stellar-orange: #ff9f43;
  --stellar-orange-2: #ff6b35;
  --stellar-purple: #8b5cf6;
  --stellar-cyan: #22d3ee;
  --stellar-green: #22c55e;
  --stellar-red: #ef4444;
  --stellar-radius: 18px;
  --stellar-shadow: 0 20px 60px rgba(0,0,0,.45);
}

html,
body {
  background:
    radial-gradient(circle at 10% 10%, rgba(255, 159, 67, .16), transparent 28%),
    radial-gradient(circle at 90% 12%, rgba(139, 92, 246, .17), transparent 32%),
    radial-gradient(circle at 45% 100%, rgba(34, 211, 238, .10), transparent 34%),
    linear-gradient(135deg, var(--stellar-bg-0), var(--stellar-bg-1) 45%, var(--stellar-bg-2)) !important;
  color: var(--stellar-text) !important;
  min-height: 100vh;
}

body::before {
  content: "";
  position: fixed;
  inset: 0;
  pointer-events: none;
  z-index: 0;
  background-image:
    radial-gradient(circle, rgba(255,255,255,.72) 0 1px, transparent 1.4px),
    radial-gradient(circle, rgba(255,159,67,.40) 0 1px, transparent 1.6px),
    radial-gradient(circle, rgba(34,211,238,.42) 0 1px, transparent 1.6px);
  background-size: 80px 80px, 140px 140px, 220px 220px;
  background-position: 0 0, 35px 65px, 90px 40px;
  opacity: .19;
}

body::after {
  content: "";
  position: fixed;
  inset: 0;
  pointer-events: none;
  z-index: 1;
  background:
    linear-gradient(180deg, rgba(255,255,255,.05), transparent 18%),
    radial-gradient(circle at 50% 0%, rgba(255,255,255,.07), transparent 35%);
  mix-blend-mode: screen;
  opacity: .5;
}

#app,
.app,
[class*="App"],
[class*="Layout"],
[class*="Content"] {
  position: relative;
  z-index: 2;
}

a {
  color: #ffd29a;
  transition: .18s ease;
}

a:hover {
  color: #fff0d8;
  text-shadow: 0 0 18px rgba(255, 159, 67, .38);
}

button,
[type="button"],
[type="submit"],
[class*="Button"],
[class*="button"] {
  border-radius: 14px !important;
  transition: transform .16s ease, box-shadow .16s ease, border-color .16s ease, background .16s ease !important;
}

button:hover,
[type="button"]:hover,
[type="submit"]:hover,
[class*="Button"]:hover,
[class*="button"]:hover {
  transform: translateY(-1px);
  box-shadow: 0 14px 28px rgba(0, 0, 0, .28), 0 0 24px rgba(255, 159, 67, .18) !important;
}

input,
textarea,
select {
  border-radius: 14px !important;
  background: rgba(9, 11, 24, .72) !important;
  border: 1px solid rgba(255,255,255,.12) !important;
  color: var(--stellar-text) !important;
  box-shadow: inset 0 1px 0 rgba(255,255,255,.03);
}

input:focus,
textarea:focus,
select:focus {
  border-color: rgba(255, 159, 67, .55) !important;
  box-shadow: 0 0 0 3px rgba(255, 159, 67, .13), 0 0 34px rgba(255, 159, 67, .10) !important;
  outline: none !important;
}

label,
small,
p,
span {
  color: inherit;
}

table,
[class*="Table"] {
  border-radius: var(--stellar-radius) !important;
  overflow: hidden !important;
  background: rgba(13, 15, 31, .62) !important;
  border: 1px solid var(--stellar-border) !important;
}

thead,
[class*="TableHead"] {
  background: rgba(255,255,255,.06) !important;
}

tr,
[class*="TableRow"] {
  border-color: rgba(255,255,255,.08) !important;
}

code,
pre,
[class*="Console"],
[class*="Terminal"],
.xterm {
  background: rgba(3, 5, 13, .88) !important;
  border-radius: 16px !important;
  border: 1px solid rgba(255,255,255,.10) !important;
  box-shadow: inset 0 0 35px rgba(0,0,0,.55), 0 18px 50px rgba(0,0,0,.30) !important;
}

[class*="Card"],
[class*="Box"],
[class*="Container"],
[class*="Modal"],
[class*="Dialog"],
[class*="Dropdown"],
[class*="ServerRow"],
[class*="ServerCard"],
[class*="grey"],
[class*="gray"] {
  border-radius: var(--stellar-radius) !important;
}

main > div,
section,
article,
[class*="Card"],
[class*="ServerRow"],
[class*="ServerCard"],
[class*="Modal"],
[class*="Dialog"],
[class*="Dropdown"],
[class*="ContentBox"],
[class*="TitledGreyBox"] {
  border-color: var(--stellar-border) !important;
  box-shadow: var(--stellar-shadow) !important;
}

main > div,
[class*="Card"],
[class*="ServerRow"],
[class*="ServerCard"],
[class*="Modal"],
[class*="Dialog"],
[class*="Dropdown"],
[class*="ContentBox"],
[class*="TitledGreyBox"] {
  background:
    linear-gradient(135deg, rgba(255,255,255,.08), rgba(255,255,255,.03)),
    var(--stellar-card) !important;
  backdrop-filter: blur(14px);
  -webkit-backdrop-filter: blur(14px);
  border: 1px solid var(--stellar-border) !important;
}

nav,
aside,
header,
[class*="Navigation"],
[class*="Sidebar"],
[class*="Header"],
[class*="TopBar"] {
  background:
    linear-gradient(180deg, rgba(15,17,34,.92), rgba(9,10,22,.86)) !important;
  border-color: rgba(255,255,255,.10) !important;
  backdrop-filter: blur(18px);
  -webkit-backdrop-filter: blur(18px);
}

nav a,
aside a,
header a,
[class*="Navigation"] a,
[class*="Sidebar"] a {
  border-radius: 14px !important;
}

nav a:hover,
aside a:hover,
header a:hover,
[class*="Navigation"] a:hover,
[class*="Sidebar"] a:hover {
  background: rgba(255, 159, 67, .12) !important;
}

[class*="active"],
[aria-current="page"] {
  box-shadow: inset 0 0 0 1px rgba(255, 159, 67, .22);
}

[class*="btn-primary"],
button[type="submit"],
[type="submit"],
[class*="Button"][class*="Primary"] {
  background: linear-gradient(135deg, var(--stellar-orange), var(--stellar-orange-2)) !important;
  border: 0 !important;
  color: #120a05 !important;
  font-weight: 700 !important;
}

[class*="btn-danger"],
[class*="Danger"],
button.danger {
  background: linear-gradient(135deg, #ff6b6b, #ef4444) !important;
  color: white !important;
}

[class*="Badge"],
[class*="Pill"],
[class*="Status"] {
  border-radius: 999px !important;
  border: 1px solid rgba(255,255,255,.12) !important;
  background: rgba(255,255,255,.08) !important;
}

::-webkit-scrollbar {
  width: 10px;
  height: 10px;
}

::-webkit-scrollbar-track {
  background: rgba(255,255,255,.04);
}

::-webkit-scrollbar-thumb {
  background: linear-gradient(180deg, rgba(255,159,67,.85), rgba(139,92,246,.75));
  border-radius: 999px;
}

::selection {
  background: rgba(255, 159, 67, .32);
}

.stellar-theme-badge {
  position: fixed;
  right: 16px;
  bottom: 14px;
  z-index: 99999;
  padding: 8px 12px;
  border-radius: 999px;
  background: rgba(10, 10, 22, .66);
  color: rgba(255,255,255,.72);
  border: 1px solid rgba(255,255,255,.12);
  font: 600 11px/1.2 Inter, system-ui, sans-serif;
  backdrop-filter: blur(14px);
  box-shadow: 0 12px 32px rgba(0,0,0,.25);
}

@media (max-width: 768px) {
  .stellar-theme-badge {
    display: none;
  }

  main > div,
  [class*="Card"],
  [class*="ServerRow"],
  [class*="ServerCard"],
  [class*="ContentBox"] {
    border-radius: 16px !important;
  }
}
CSS

  cat > "$theme_dir/stellar.js" <<'JS'
(function () {
  const MARK = 'stellar-theme-loaded';

  if (document.documentElement.classList.contains(MARK)) return;
  document.documentElement.classList.add(MARK);
  document.documentElement.classList.add('stellar-theme');

  function addBadge() {
    if (document.querySelector('.stellar-theme-badge')) return;
    const badge = document.createElement('div');
    badge.className = 'stellar-theme-badge';
    badge.textContent = 'Stellar Panel';
    document.body.appendChild(badge);
  }

  function improveInputs() {
    document.querySelectorAll('input, textarea, select').forEach((el) => {
      el.setAttribute('autocomplete', el.getAttribute('autocomplete') || 'off');
    });
  }

  function run() {
    addBadge();
    improveInputs();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', run);
  } else {
    run();
  }

  const obs = new MutationObserver(() => run());
  obs.observe(document.documentElement, { childList: true, subtree: true });
})();
JS

  chown -R www-data:www-data "$theme_dir" 2>/dev/null || true
}

inject_theme() {
  local blade_file="$1"
  local theme_url="/$THEME_SLUG/stellar.css"
  local script_url="/$THEME_SLUG/stellar.js"

  if grep -q "$MARK_START" "$blade_file"; then
    warn "Theme sudah terpasang di: $blade_file"
    return 0
  fi

  local backup="${blade_file}.bak-stellar-$(date +%Y%m%d-%H%M%S)"
  cp "$blade_file" "$backup"
  say "Backup dibuat: $backup"

  python3 - "$blade_file" "$theme_url" "$script_url" "$MARK_START" "$MARK_END" <<'PY'
import sys
from pathlib import Path

file_path, theme_url, script_url, mark_start, mark_end = sys.argv[1:]
p = Path(file_path)
s = p.read_text(encoding="utf-8", errors="ignore")

inject = f"""    <!-- {mark_start} -->
    <link rel="stylesheet" href="{theme_url}?v=stellar-1">
    <script defer src="{script_url}?v=stellar-1"></script>
    <!-- {mark_end} -->
"""

lower = s.lower()
idx = lower.find("</head>")
if idx == -1:
    raise SystemExit("Tidak menemukan </head>")

s = s[:idx] + inject + s[idx:]
p.write_text(s, encoding="utf-8")
PY
}

clear_cache() {
  cd "$PANEL_DIR"
  php artisan view:clear >/dev/null 2>&1 || true
  php artisan cache:clear >/dev/null 2>&1 || true
  php artisan config:clear >/dev/null 2>&1 || true
  php artisan optimize:clear >/dev/null 2>&1 || true
  chown -R www-data:www-data "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" 2>/dev/null || true
  systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
  systemctl restart php8.3-fpm 2>/dev/null || systemctl restart php8.2-fpm 2>/dev/null || true
}

set_panel_name() {
  read -rp "Nama panel baru, kosongkan jika tidak ingin ubah [Stellar Panel]: " new_name
  new_name="${new_name:-Stellar Panel}"

  if [[ -f "$PANEL_DIR/.env" ]]; then
    if grep -q '^APP_NAME=' "$PANEL_DIR/.env"; then
      sed -i "s|^APP_NAME=.*|APP_NAME=\"${new_name}\"|g" "$PANEL_DIR/.env"
    else
      echo "APP_NAME=\"${new_name}\"" >> "$PANEL_DIR/.env"
    fi
    say "APP_NAME diubah menjadi: $new_name"
  fi
}

apply_theme() {
  detect_panel_dir
  local blade_file
  blade_file="$(find_head_file)" || {
    bad "Tidak menemukan file blade yang punya </head>."
    bad "Panel kamu mungkin beda versi. Kirim isi folder resources/views kalau mau saya sesuaikan."
    exit 1
  }

  info "Panel dir: $PANEL_DIR"
  info "Inject file: $blade_file"
  write_theme_files
  inject_theme "$blade_file"
  set_panel_name
  clear_cache

  say "Theme Stellar berhasil dipasang."
  echo ""
  info "Buka panel kamu di browser, lalu hard refresh:"
  echo "CTRL + F5 / hapus cache browser"
}

restore_theme() {
  detect_panel_dir
  local injected
  injected="$(grep -Ril "$MARK_START" "$PANEL_DIR/resources/views" 2>/dev/null | head -n 1 || true)"

  if [[ -n "$injected" ]]; then
    python3 - "$injected" "$MARK_START" "$MARK_END" <<'PY'
import sys, re
from pathlib import Path

file_path, start, end = sys.argv[1:]
p = Path(file_path)
s = p.read_text(encoding="utf-8", errors="ignore")
pattern = rf"\s*<!-- {re.escape(start)} -->.*?<!-- {re.escape(end)} -->\s*"
s = re.sub(pattern, "\n", s, flags=re.S)
p.write_text(s, encoding="utf-8")
PY
    say "Inject theme dihapus dari: $injected"
  else
    warn "Tidak ada inject theme yang ditemukan."
  fi

  rm -rf "$PANEL_DIR/public/$THEME_SLUG"
  clear_cache
  say "Theme Stellar sudah dihapus / restore tampilan panel."
}

status_theme() {
  detect_panel_dir
  echo ""
  info "Panel dir: $PANEL_DIR"
  if [[ -d "$PANEL_DIR/public/$THEME_SLUG" ]]; then
    say "File theme: ADA"
  else
    warn "File theme: TIDAK ADA"
  fi

  if grep -Ril "$MARK_START" "$PANEL_DIR/resources/views" >/dev/null 2>&1; then
    say "Inject blade: AKTIF"
    grep -Ril "$MARK_START" "$PANEL_DIR/resources/views" 2>/dev/null | head -n 3
  else
    warn "Inject blade: TIDAK AKTIF"
  fi
  echo ""
}

menu() {
  clear
  echo -e "${CYAN}"
  echo "╔══════════════════════════════════════╗"
  echo "   KAHFITZY STELLAR THEME PATCHER"
  echo "   For Pterodactyl Panel Web"
  echo "╚══════════════════════════════════════╝"
  echo -e "${NC}"
  echo "1. Apply Stellar Theme ke Panel"
  echo "2. Restore / Hapus Theme"
  echo "3. Status Theme"
  echo "0. Exit"
  echo ""
  read -rp "Pilih menu: " pilih

  case "$pilih" in
    1) apply_theme ;;
    2) restore_theme ;;
    3) status_theme ;;
    0) exit 0 ;;
    *) bad "Pilihan tidak valid." ;;
  esac
}

require_root
menu
