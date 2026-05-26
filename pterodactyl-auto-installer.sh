#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="Stellar Ptero Panel"
APP_DIR="/opt/stellar-ptero-panel"
APP_PORT="${APP_PORT:-3300}"
LOG_FILE="/var/log/stellar-ptero-installer.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

trap 'echo -e "${RED}Installer gagal di line $LINENO. Cek ${LOG_FILE}${NC}"; exit 1' ERR
exec > >(tee -a "$LOG_FILE") 2>&1

banner() {
  clear || true
  echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
  echo -e "${CYAN}   STELLAR PTERO CUSTOM PANEL INSTALLER${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
  echo ""
}

check_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}Jalankan sebagai root.${NC}"
    exit 1
  fi
}

check_os() {
  if [[ ! -f /etc/os-release ]]; then
    echo -e "${RED}OS tidak dikenali.${NC}"
    exit 1
  fi
  . /etc/os-release
  case "${ID}:${VERSION_ID}" in
    ubuntu:22.04|ubuntu:24.04|debian:12|debian:13)
      echo -e "${GREEN}OS support terdeteksi: ${PRETTY_NAME}${NC}"
      ;;
    *)
      echo -e "${RED}OS belum support: ${PRETTY_NAME:-unknown}${NC}"
      echo "Support: Ubuntu 22.04/24.04, Debian 12/13"
      exit 1
      ;;
  esac
}

ask_config() {
  echo -e "${CYAN}Masukkan konfigurasi web custom.${NC}"
  read -rp "Domain web custom, contoh stellar.domain.com: " CUSTOM_DOMAIN
  read -rp "URL Panel Pterodactyl asli, contoh https://panel.domain.com: " PTERO_URL
  read -rsp "PTLA / Application API Key: " PTLA_KEY; echo ""
  read -rsp "PTLC / Client API Key opsional untuk power start/stop/restart, enter jika belum ada: " PTLC_KEY; echo ""
  read -rp "Username admin web custom [admin]: " ADMIN_USERNAME
  ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
  read -rsp "Password admin web custom: " ADMIN_PASSWORD; echo ""
  if [[ -z "${ADMIN_PASSWORD}" ]]; then
    ADMIN_PASSWORD="$(cat /proc/sys/kernel/random/uuid | tr -d '-' | head -c 16)"
    echo -e "${YELLOW}Password kosong, dibuat otomatis: ${ADMIN_PASSWORD}${NC}"
  fi

  PTERO_URL="${PTERO_URL%/}"
}

install_packages() {
  echo -e "${CYAN}Install dependency...${NC}"
  apt-get update -y
  apt-get install -y curl ca-certificates gnupg nginx certbot python3-certbot-nginx build-essential

  if ! command -v node >/dev/null 2>&1 || [[ "$(node -v | sed 's/v//' | cut -d. -f1)" -lt 18 ]]; then
    echo -e "${CYAN}Install Node.js 20...${NC}"
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
  fi

  if ! command -v pm2 >/dev/null 2>&1; then
    npm install -g pm2
  fi
}

write_app_files() {
  echo -e "${CYAN}Menulis file aplikasi ke ${APP_DIR}...${NC}"
  if [[ -d "${APP_DIR}" ]]; then
    BACKUP="${APP_DIR}.bak.$(date +%Y%m%d-%H%M%S)"
    echo -e "${YELLOW}Folder lama ditemukan. Backup ke ${BACKUP}${NC}"
    mv "${APP_DIR}" "${BACKUP}"
  fi
  mkdir -p "${APP_DIR}/views/partials" "${APP_DIR}/public/css" "${APP_DIR}/public/js"

  cat > "${APP_DIR}/package.json" <<'APPFILE'
{
  "name": "stellar-ptero-panel",
  "version": "1.0.0",
  "description": "Custom Stellar style web panel for Pterodactyl API",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "axios": "^1.7.9",
    "dotenv": "^16.4.7",
    "ejs": "^3.1.10",
    "express": "^4.21.2",
    "express-rate-limit": "^7.5.0",
    "express-session": "^1.18.1",
    "helmet": "^8.0.0"
  }
}
APPFILE

  cat > "${APP_DIR}/server.js" <<'APPFILE'
require('dotenv').config();

const express = require('express');
const session = require('express-session');
const rateLimit = require('express-rate-limit');
const helmet = require('helmet');
const axios = require('axios');
const crypto = require('crypto');

const app = express();
const PORT = Number(process.env.PORT || 3300);
const APP_NAME = process.env.APP_NAME || 'Stellar Panel';
const PTERO_URL = (process.env.PTERO_URL || '').replace(/\/$/, '');
const PTLA_KEY = process.env.PTLA_KEY || '';
const PTLC_KEY = process.env.PTLC_KEY || '';

if (!PTERO_URL || !PTLA_KEY) {
  console.error('PTERO_URL dan PTLA_KEY wajib diisi di .env');
  process.exit(1);
}

app.set('view engine', 'ejs');
app.set('views', `${__dirname}/views`);
app.set('trust proxy', 1);

app.use(helmet({ contentSecurityPolicy: false }));
app.use('/public', express.static(`${__dirname}/public`));
app.use(express.urlencoded({ extended: true, limit: '2mb' }));
app.use(express.json({ limit: '2mb' }));

app.use(rateLimit({ windowMs: 60 * 1000, max: 180, standardHeaders: true, legacyHeaders: false }));
app.use(session({
  name: 'stellar.sid',
  secret: process.env.SESSION_SECRET || crypto.randomBytes(32).toString('hex'),
  resave: false,
  saveUninitialized: false,
  cookie: {
    httpOnly: true,
    sameSite: 'lax',
    secure: process.env.COOKIE_SECURE === 'true',
    maxAge: 1000 * 60 * 60 * 12
  }
}));

function constantEqual(a, b) {
  const A = Buffer.from(String(a || ''));
  const B = Buffer.from(String(b || ''));
  if (A.length !== B.length) return false;
  return crypto.timingSafeEqual(A, B);
}

function auth(req, res, next) {
  if (req.session && req.session.auth === true) return next();
  return res.redirect('/login');
}

function flash(req, type, message) {
  req.session.flash = { type, message };
}

app.use((req, res, next) => {
  res.locals.appName = APP_NAME;
  res.locals.path = req.path;
  res.locals.hasPtlc = Boolean(PTLC_KEY);
  res.locals.pteroUrl = PTERO_URL;
  res.locals.flash = req.session.flash || null;
  delete req.session.flash;
  next();
});

const appApi = axios.create({
  baseURL: PTERO_URL,
  timeout: 30000,
  headers: {
    Authorization: `Bearer ${PTLA_KEY}`,
    Accept: 'application/json',
    'Content-Type': 'application/json'
  }
});

const clientApi = axios.create({
  baseURL: PTERO_URL,
  timeout: 30000,
  headers: {
    Authorization: `Bearer ${PTLC_KEY}`,
    Accept: 'application/json',
    'Content-Type': 'application/json'
  }
});

function attrs(item) {
  return item && item.attributes ? item.attributes : item;
}

function apiError(error) {
  const detail = error?.response?.data?.errors?.[0]?.detail || error?.response?.data?.message || error.message;
  return detail || 'Unknown error';
}

async function listAll(path) {
  let page = 1;
  const out = [];
  while (true) {
    const sep = path.includes('?') ? '&' : '?';
    const { data } = await appApi.get(`${path}${sep}per_page=100&page=${page}`);
    if (Array.isArray(data.data)) out.push(...data.data.map(attrs));
    const pagination = data.meta?.pagination;
    if (!pagination || page >= pagination.total_pages) break;
    page++;
  }
  return out;
}

async function getDashboardData() {
  const [servers, users, nodes] = await Promise.all([
    listAll('/api/application/servers?include=user,node'),
    listAll('/api/application/users'),
    listAll('/api/application/nodes')
  ]);
  return { servers, users, nodes };
}

async function getEggDetail(nestId, eggId) {
  const { data } = await appApi.get(`/api/application/nests/${nestId}/eggs/${eggId}?include=variables`);
  const egg = attrs(data);
  const vars = data.attributes?.relationships?.variables?.data || data.relationships?.variables?.data || [];
  const environment = {};
  for (const v of vars) {
    const va = attrs(v);
    if (va.env_variable) environment[va.env_variable] = va.default_value ?? '';
  }
  return { egg, environment };
}

function firstDockerImage(egg) {
  if (egg.docker_image) return egg.docker_image;
  if (egg.docker_images && typeof egg.docker_images === 'object') return Object.values(egg.docker_images)[0];
  return 'ghcr.io/pterodactyl/yolks:nodejs_20';
}

app.get('/login', (req, res) => {
  if (req.session.auth) return res.redirect('/dashboard');
  res.render('login');
});

app.post('/login', (req, res) => {
  const okUser = constantEqual(req.body.username, process.env.ADMIN_USERNAME || 'admin');
  const okPass = constantEqual(req.body.password, process.env.ADMIN_PASSWORD || 'admin');
  if (!okUser || !okPass) {
    flash(req, 'danger', 'Username atau password salah.');
    return res.redirect('/login');
  }
  req.session.auth = true;
  req.session.user = req.body.username;
  res.redirect('/dashboard');
});

app.post('/logout', auth, (req, res) => {
  req.session.destroy(() => res.redirect('/login'));
});

app.get('/', auth, (req, res) => res.redirect('/dashboard'));

app.get('/dashboard', auth, async (req, res) => {
  try {
    const { servers, users, nodes } = await getDashboardData();
    res.render('dashboard', { servers, users, nodes });
  } catch (error) {
    res.render('error', { title: 'Dashboard error', message: apiError(error) });
  }
});

app.get('/servers', auth, async (req, res) => {
  try {
    const servers = await listAll('/api/application/servers?include=user,node');
    res.render('servers', { servers });
  } catch (error) {
    res.render('error', { title: 'Server error', message: apiError(error) });
  }
});

app.post('/servers/:identifier/power', auth, async (req, res) => {
  try {
    if (!PTLC_KEY) throw new Error('PTLC_KEY belum diisi. Power action butuh Client API key.');
    const signal = String(req.body.signal || '').toLowerCase();
    if (!['start', 'stop', 'restart', 'kill'].includes(signal)) throw new Error('Signal tidak valid.');
    await clientApi.post(`/api/client/servers/${req.params.identifier}/power`, { signal });
    flash(req, 'success', `Power signal ${signal} terkirim.`);
  } catch (error) {
    flash(req, 'danger', apiError(error));
  }
  res.redirect('/servers');
});

app.post('/servers/:id/suspend', auth, async (req, res) => {
  try {
    await appApi.post(`/api/application/servers/${req.params.id}/suspend`);
    flash(req, 'success', 'Server berhasil disuspend.');
  } catch (error) { flash(req, 'danger', apiError(error)); }
  res.redirect('/servers');
});

app.post('/servers/:id/unsuspend', auth, async (req, res) => {
  try {
    await appApi.post(`/api/application/servers/${req.params.id}/unsuspend`);
    flash(req, 'success', 'Server berhasil diunsuspend.');
  } catch (error) { flash(req, 'danger', apiError(error)); }
  res.redirect('/servers');
});

app.post('/servers/:id/delete', auth, async (req, res) => {
  try {
    await appApi.delete(`/api/application/servers/${req.params.id}/force`);
    flash(req, 'success', 'Server berhasil dihapus paksa.');
  } catch (error) { flash(req, 'danger', apiError(error)); }
  res.redirect('/servers');
});

app.get('/create-server', auth, async (req, res) => {
  try {
    const [users, nodes] = await Promise.all([
      listAll('/api/application/users'),
      listAll('/api/application/nodes')
    ]);
    res.render('create-server', { users, nodes });
  } catch (error) {
    res.render('error', { title: 'Create server error', message: apiError(error) });
  }
});

app.post('/servers/create', auth, async (req, res) => {
  try {
    const nestId = Number(req.body.nest_id);
    const eggId = Number(req.body.egg_id);
    if (!nestId || !eggId) throw new Error('Nest ID dan Egg ID wajib diisi.');

    const { egg, environment: envDefault } = await getEggDetail(nestId, eggId);
    let envExtra = {};
    if (String(req.body.env_json || '').trim()) {
      envExtra = JSON.parse(req.body.env_json);
    }
    const environment = { ...envDefault, ...envExtra };

    const payload = {
      name: req.body.name,
      user: Number(req.body.user_id),
      egg: eggId,
      docker_image: req.body.docker_image || firstDockerImage(egg),
      startup: req.body.startup || egg.startup || 'npm start',
      environment,
      limits: {
        memory: Number(req.body.memory || 1024),
        swap: Number(req.body.swap || 0),
        disk: Number(req.body.disk || 1024),
        io: Number(req.body.io || 500),
        cpu: Number(req.body.cpu || 100)
      },
      feature_limits: {
        databases: Number(req.body.databases || 0),
        allocations: Number(req.body.allocations || 0),
        backups: Number(req.body.backups || 0)
      },
      allocation: {
        default: Number(req.body.allocation_id)
      }
    };

    await appApi.post('/api/application/servers', payload);
    flash(req, 'success', 'Server berhasil dibuat.');
    res.redirect('/servers');
  } catch (error) {
    flash(req, 'danger', apiError(error));
    res.redirect('/create-server');
  }
});

app.get('/users', auth, async (req, res) => {
  try {
    const users = await listAll('/api/application/users');
    res.render('users', { users });
  } catch (error) {
    res.render('error', { title: 'Users error', message: apiError(error) });
  }
});

app.post('/users/create', auth, async (req, res) => {
  try {
    await appApi.post('/api/application/users', {
      email: req.body.email,
      username: req.body.username,
      first_name: req.body.first_name || req.body.username,
      last_name: req.body.last_name || 'User',
      password: req.body.password
    });
    flash(req, 'success', 'User berhasil dibuat.');
  } catch (error) { flash(req, 'danger', apiError(error)); }
  res.redirect('/users');
});

app.post('/users/:id/delete', auth, async (req, res) => {
  try {
    await appApi.delete(`/api/application/users/${req.params.id}`);
    flash(req, 'success', 'User berhasil dihapus.');
  } catch (error) { flash(req, 'danger', apiError(error)); }
  res.redirect('/users');
});

app.get('/nodes', auth, async (req, res) => {
  try {
    const nodes = await listAll('/api/application/nodes');
    res.render('nodes', { nodes });
  } catch (error) {
    res.render('error', { title: 'Nodes error', message: apiError(error) });
  }
});

app.get('/eggs', auth, async (req, res) => {
  try {
    const nests = await listAll('/api/application/nests');
    const groups = [];
    for (const nest of nests) {
      const eggs = await listAll(`/api/application/nests/${nest.id}/eggs?include=variables`);
      groups.push({ nest, eggs });
    }
    res.render('eggs', { groups });
  } catch (error) {
    res.render('error', { title: 'Eggs error', message: apiError(error) });
  }
});

app.get('/settings', auth, (req, res) => {
  res.render('settings', {
    config: {
      PTERO_URL,
      PTLA_KEY: PTLA_KEY ? `${PTLA_KEY.slice(0, 12)}••••••••` : 'kosong',
      PTLC_KEY: PTLC_KEY ? `${PTLC_KEY.slice(0, 12)}••••••••` : 'kosong',
      PORT,
      COOKIE_SECURE: process.env.COOKIE_SECURE === 'true'
    }
  });
});

app.get('/health', (req, res) => res.json({ ok: true, app: APP_NAME }));

app.use((req, res) => res.status(404).render('error', { title: '404', message: 'Halaman tidak ditemukan.' }));

app.listen(PORT, '127.0.0.1', () => {
  console.log(`${APP_NAME} running on http://127.0.0.1:${PORT}`);
});
APPFILE

  cat > "${APP_DIR}/views/partials/header.ejs" <<'APPFILE'
<!doctype html>
<html lang="id">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title><%= appName %></title>
  <link rel="stylesheet" href="/public/css/style.css">
</head>
<body>
<div class="shell">
  <aside class="sidebar">
    <div class="brand">
      <div class="brand-orb"></div>
      <div>
        <b><%= appName %></b>
        <span>Custom Ptero Engine</span>
      </div>
    </div>
    <nav>
      <a class="<%= path === '/dashboard' ? 'active' : '' %>" href="/dashboard">Dashboard</a>
      <a class="<%= path === '/servers' ? 'active' : '' %>" href="/servers">Servers</a>
      <a class="<%= path === '/create-server' ? 'active' : '' %>" href="/create-server">Create Server</a>
      <a class="<%= path === '/users' ? 'active' : '' %>" href="/users">Users</a>
      <a class="<%= path === '/nodes' ? 'active' : '' %>" href="/nodes">Nodes</a>
      <a class="<%= path === '/eggs' ? 'active' : '' %>" href="/eggs">Eggs</a>
      <a class="<%= path === '/settings' ? 'active' : '' %>" href="/settings">Settings</a>
    </nav>
    <form method="post" action="/logout" class="logout"><button>Logout</button></form>
  </aside>
  <main class="main">
    <div class="topbar">
      <div>
        <p class="muted">Connected to</p>
        <h2><%= pteroUrl %></h2>
      </div>
      <div class="pill <%= hasPtlc ? 'ok' : 'warn' %>"><%= hasPtlc ? 'PTLC Ready' : 'PTLC Missing' %></div>
    </div>
    <% if (flash) { %>
      <div class="alert <%= flash.type %>"><%= flash.message %></div>
    <% } %>
APPFILE

  cat > "${APP_DIR}/views/partials/footer.ejs" <<'APPFILE'
  </main>
</div>
<script src="/public/js/app.js"></script>
</body>
</html>
APPFILE

  cat > "${APP_DIR}/views/login.ejs" <<'APPFILE'
<!doctype html>
<html lang="id">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Login - <%= appName %></title>
  <link rel="stylesheet" href="/public/css/style.css">
</head>
<body class="login-body">
  <div class="login-card">
    <div class="brand login-brand"><div class="brand-orb"></div><div><b><%= appName %></b><span>Stellar custom panel</span></div></div>
    <% if (flash) { %><div class="alert <%= flash.type %>"><%= flash.message %></div><% } %>
    <form method="post" action="/login" class="form">
      <label>Username</label>
      <input name="username" required autocomplete="username">
      <label>Password</label>
      <input name="password" type="password" required autocomplete="current-password">
      <button class="btn primary full">Masuk Dashboard</button>
    </form>
    <p class="muted center">Web ini bukan tampilan Pterodactyl bawaan. Ini frontend custom yang memakai API Pterodactyl.</p>
  </div>
</body>
</html>
APPFILE

  cat > "${APP_DIR}/views/dashboard.ejs" <<'APPFILE'
<%- include('partials/header') %>
<section class="hero">
  <div>
    <p class="eyebrow">STELLAR COMMAND CENTER</p>
    <h1>Panel custom aktif.</h1>
    <p>Kelola engine Pterodactyl dari tampilan web yang beda total.</p>
  </div>
  <a href="/create-server" class="btn primary">Create Server</a>
</section>

<section class="grid stats">
  <div class="card stat"><span>Total Servers</span><b><%= servers.length %></b></div>
  <div class="card stat"><span>Total Users</span><b><%= users.length %></b></div>
  <div class="card stat"><span>Total Nodes</span><b><%= nodes.length %></b></div>
  <div class="card stat"><span>Power API</span><b><%= hasPtlc ? 'Ready' : 'Off' %></b></div>
</section>

<section class="card">
  <div class="card-head"><h3>Recent Servers</h3><a href="/servers">Lihat semua</a></div>
  <div class="table-wrap">
    <table>
      <thead><tr><th>ID</th><th>Name</th><th>Identifier</th><th>Status</th><th>Limits</th></tr></thead>
      <tbody>
      <% servers.slice(0, 8).forEach(s => { %>
        <tr>
          <td>#<%= s.id %></td>
          <td><%= s.name %></td>
          <td><code><%= s.identifier %></code></td>
          <td><span class="badge <%= s.suspended ? 'danger' : 'ok' %>"><%= s.suspended ? 'Suspended' : 'Active' %></span></td>
          <td><%= s.limits?.memory || 0 %>MB / <%= s.limits?.disk || 0 %>MB / <%= s.limits?.cpu || 0 %>%</td>
        </tr>
      <% }) %>
      </tbody>
    </table>
  </div>
</section>
<%- include('partials/footer') %>
APPFILE

  cat > "${APP_DIR}/views/servers.ejs" <<'APPFILE'
<%- include('partials/header') %>
<section class="page-title"><h1>Servers</h1><a href="/create-server" class="btn primary">Create Server</a></section>
<section class="card">
  <div class="table-wrap">
    <table>
      <thead><tr><th>ID</th><th>Name</th><th>Identifier</th><th>Status</th><th>Limits</th><th>Power</th><th>Admin</th></tr></thead>
      <tbody>
      <% servers.forEach(s => { %>
        <tr>
          <td>#<%= s.id %></td>
          <td><%= s.name %></td>
          <td><code><%= s.identifier %></code></td>
          <td><span class="badge <%= s.suspended ? 'danger' : 'ok' %>"><%= s.suspended ? 'Suspended' : 'Active' %></span></td>
          <td><%= s.limits?.memory || 0 %>MB / <%= s.limits?.disk || 0 %>MB / CPU <%= s.limits?.cpu || 0 %>%</td>
          <td class="actions">
            <% ['start','restart','stop','kill'].forEach(sig => { %>
              <form method="post" action="/servers/<%= s.identifier %>/power"><input type="hidden" name="signal" value="<%= sig %>"><button class="mini" <%= hasPtlc ? '' : 'disabled' %>><%= sig %></button></form>
            <% }) %>
          </td>
          <td class="actions">
            <% if (s.suspended) { %>
              <form method="post" action="/servers/<%= s.id %>/unsuspend"><button class="mini ok">Unsuspend</button></form>
            <% } else { %>
              <form method="post" action="/servers/<%= s.id %>/suspend"><button class="mini warn">Suspend</button></form>
            <% } %>
            <form method="post" action="/servers/<%= s.id %>/delete" onsubmit="return confirm('Hapus server ini?')"><button class="mini danger">Delete</button></form>
          </td>
        </tr>
      <% }) %>
      </tbody>
    </table>
  </div>
</section>
<%- include('partials/footer') %>
APPFILE

  cat > "${APP_DIR}/views/create-server.ejs" <<'APPFILE'
<%- include('partials/header') %>
<section class="page-title"><h1>Create Server</h1><a href="/eggs" class="btn ghost">Lihat Egg ID</a></section>
<section class="card">
  <form method="post" action="/servers/create" class="form grid-form">
    <div><label>Nama Server</label><input name="name" required placeholder="Server WhatsApp Bot"></div>
    <div><label>User</label><select name="user_id" required><% users.forEach(u => { %><option value="<%= u.id %>">#<%= u.id %> - <%= u.username %> / <%= u.email %></option><% }) %></select></div>
    <div><label>Node</label><select name="node_id" required><% nodes.forEach(n => { %><option value="<%= n.id %>">#<%= n.id %> - <%= n.name %></option><% }) %></select></div>
    <div><label>Allocation ID</label><input name="allocation_id" type="number" required placeholder="contoh 12"></div>
    <div><label>Nest ID</label><input name="nest_id" type="number" required placeholder="lihat halaman Eggs"></div>
    <div><label>Egg ID</label><input name="egg_id" type="number" required placeholder="lihat halaman Eggs"></div>
    <div><label>Memory MB</label><input name="memory" type="number" value="1024" required></div>
    <div><label>Disk MB</label><input name="disk" type="number" value="1024" required></div>
    <div><label>CPU %</label><input name="cpu" type="number" value="100" required></div>
    <div><label>Swap</label><input name="swap" type="number" value="0"></div>
    <div><label>IO</label><input name="io" type="number" value="500"></div>
    <div><label>Databases</label><input name="databases" type="number" value="0"></div>
    <div><label>Backups</label><input name="backups" type="number" value="0"></div>
    <div><label>Extra Allocations</label><input name="allocations" type="number" value="0"></div>
    <div><label>Docker Image opsional</label><input name="docker_image" placeholder="kosongkan agar ambil dari egg"></div>
    <div><label>Startup opsional</label><input name="startup" placeholder="kosongkan agar ambil dari egg"></div>
    <div class="wide"><label>Environment JSON opsional</label><textarea name="env_json" rows="7" placeholder='{"BOT_TOKEN":"xxx","CMD_RUN":"npm start"}'></textarea></div>
    <div class="wide"><button class="btn primary">Buat Server</button></div>
  </form>
  <p class="muted">Catatan: allocation ID bisa dilihat dari Panel Pterodactyl asli atau API. Versi awal ini sengaja aman, tidak menjalankan command bebas dari web.</p>
</section>
<%- include('partials/footer') %>
APPFILE

  cat > "${APP_DIR}/views/users.ejs" <<'APPFILE'
<%- include('partials/header') %>
<section class="page-title"><h1>Users</h1></section>
<section class="card form-card">
  <h3>Create User</h3>
  <form method="post" action="/users/create" class="form grid-form small">
    <div><label>Email</label><input name="email" type="email" required></div>
    <div><label>Username</label><input name="username" required></div>
    <div><label>First name</label><input name="first_name"></div>
    <div><label>Last name</label><input name="last_name"></div>
    <div><label>Password</label><input name="password" required></div>
    <div><button class="btn primary">Create</button></div>
  </form>
</section>
<section class="card">
  <div class="table-wrap"><table>
    <thead><tr><th>ID</th><th>Username</th><th>Email</th><th>Name</th><th>Action</th></tr></thead>
    <tbody><% users.forEach(u => { %><tr><td>#<%= u.id %></td><td><%= u.username %></td><td><%= u.email %></td><td><%= u.first_name %> <%= u.last_name %></td><td><form method="post" action="/users/<%= u.id %>/delete" onsubmit="return confirm('Hapus user?')"><button class="mini danger">Delete</button></form></td></tr><% }) %></tbody>
  </table></div>
</section>
<%- include('partials/footer') %>
APPFILE

  cat > "${APP_DIR}/views/nodes.ejs" <<'APPFILE'
<%- include('partials/header') %>
<section class="page-title"><h1>Nodes</h1></section>
<section class="grid cards">
  <% nodes.forEach(n => { %>
    <div class="card node-card">
      <span class="badge ok">#<%= n.id %></span>
      <h3><%= n.name %></h3>
      <p><%= n.fqdn %></p>
      <div class="mini-grid"><span>Memory</span><b><%= n.memory %> MB</b><span>Disk</span><b><%= n.disk %> MB</b><span>Scheme</span><b><%= n.scheme %></b></div>
    </div>
  <% }) %>
</section>
<%- include('partials/footer') %>
APPFILE

  cat > "${APP_DIR}/views/eggs.ejs" <<'APPFILE'
<%- include('partials/header') %>
<section class="page-title"><h1>Eggs & Nests</h1></section>
<% groups.forEach(g => { %>
<section class="card">
  <div class="card-head"><h3>Nest #<%= g.nest.id %> - <%= g.nest.name %></h3><span class="badge"><%= g.eggs.length %> eggs</span></div>
  <div class="table-wrap"><table>
    <thead><tr><th>Egg ID</th><th>Name</th><th>Docker</th><th>Startup</th></tr></thead>
    <tbody><% g.eggs.forEach(e => { %><tr><td><code><%= e.id %></code></td><td><%= e.name %></td><td><code><%= e.docker_image || (e.docker_images ? Object.values(e.docker_images)[0] : '-') %></code></td><td><code><%= e.startup || '-' %></code></td></tr><% }) %></tbody>
  </table></div>
</section>
<% }) %>
<%- include('partials/footer') %>
APPFILE

  cat > "${APP_DIR}/views/settings.ejs" <<'APPFILE'
<%- include('partials/header') %>
<section class="page-title"><h1>Settings</h1></section>
<section class="card">
  <div class="kv"><span>Pterodactyl URL</span><b><%= config.PTERO_URL %></b></div>
  <div class="kv"><span>PTLA Key</span><b><%= config.PTLA_KEY %></b></div>
  <div class="kv"><span>PTLC Key</span><b><%= config.PTLC_KEY %></b></div>
  <div class="kv"><span>App Port</span><b><%= config.PORT %></b></div>
  <div class="kv"><span>Secure Cookie</span><b><%= config.COOKIE_SECURE %></b></div>
  <p class="muted">Untuk ubah setting, edit file <code>/opt/stellar-ptero-panel/.env</code> lalu jalankan <code>pm2 restart stellar-ptero-panel</code>.</p>
</section>
<%- include('partials/footer') %>
APPFILE

  cat > "${APP_DIR}/views/error.ejs" <<'APPFILE'
<%- include('partials/header') %>
<section class="card error-card">
  <h1><%= title %></h1>
  <p><%= message %></p>
  <a class="btn ghost" href="/dashboard">Kembali</a>
</section>
<%- include('partials/footer') %>
APPFILE

  cat > "${APP_DIR}/public/css/style.css" <<'APPFILE'
:root{--bg:#070813;--panel:rgba(17,20,40,.78);--panel2:rgba(30,35,65,.7);--text:#f6f7ff;--muted:#99a2c7;--line:rgba(255,255,255,.1);--accent:#f59e0b;--accent2:#8b5cf6;--good:#22c55e;--bad:#ef4444;--warn:#f97316}*{box-sizing:border-box}body{margin:0;font-family:Inter,ui-sans-serif,system-ui,Segoe UI,Arial;background:radial-gradient(circle at 10% 10%,rgba(139,92,246,.28),transparent 32%),radial-gradient(circle at 90% 0,rgba(245,158,11,.22),transparent 28%),linear-gradient(135deg,#050611,#11152c 55%,#050611);color:var(--text);min-height:100vh}a{color:inherit;text-decoration:none}.shell{display:grid;grid-template-columns:280px 1fr;min-height:100vh}.sidebar{position:sticky;top:0;height:100vh;padding:22px;border-right:1px solid var(--line);background:rgba(5,7,18,.72);backdrop-filter:blur(18px)}.brand{display:flex;gap:12px;align-items:center;margin-bottom:26px}.brand b{display:block;font-size:17px}.brand span,.muted{color:var(--muted);font-size:13px}.brand-orb{width:42px;height:42px;border-radius:18px;background:conic-gradient(from 180deg,var(--accent),var(--accent2),#06b6d4,var(--accent));box-shadow:0 0 34px rgba(245,158,11,.45)}nav{display:grid;gap:9px}nav a,.logout button{border:1px solid transparent;padding:12px 14px;border-radius:16px;color:var(--muted);background:transparent;text-align:left;font-weight:700;cursor:pointer}nav a:hover,nav a.active,.logout button:hover{background:linear-gradient(135deg,rgba(245,158,11,.18),rgba(139,92,246,.15));border-color:var(--line);color:var(--text)}.logout{position:absolute;bottom:22px;left:22px;right:22px}.logout button{width:100%}.main{padding:28px;overflow:auto}.topbar,.hero,.page-title,.card-head{display:flex;align-items:center;justify-content:space-between;gap:16px}.topbar{margin-bottom:22px}.topbar h2{margin:0;font-size:18px}.topbar p{margin:0 0 4px}.hero{padding:30px;border:1px solid var(--line);border-radius:28px;background:linear-gradient(135deg,rgba(245,158,11,.16),rgba(139,92,246,.13));box-shadow:0 24px 90px rgba(0,0,0,.25);margin-bottom:22px}.hero h1,.page-title h1{font-size:36px;margin:0 0 6px}.hero p{margin:0;color:var(--muted)}.eyebrow{font-size:12px;letter-spacing:.19em;color:#fbbf24!important;font-weight:900}.grid{display:grid;gap:16px}.stats{grid-template-columns:repeat(4,minmax(0,1fr));margin-bottom:16px}.cards{grid-template-columns:repeat(auto-fit,minmax(260px,1fr))}.card{border:1px solid var(--line);border-radius:24px;background:var(--panel);backdrop-filter:blur(18px);padding:18px;box-shadow:0 24px 70px rgba(0,0,0,.22);margin-bottom:16px}.stat span{color:var(--muted);font-weight:700}.stat b{font-size:34px;display:block;margin-top:8px}.btn,button{border:0;border-radius:14px;padding:11px 15px;font-weight:900;cursor:pointer}.btn.primary,.primary{background:linear-gradient(135deg,var(--accent),#fb7185,var(--accent2));color:#fff;box-shadow:0 10px 30px rgba(245,158,11,.25)}.btn.ghost{border:1px solid var(--line);background:rgba(255,255,255,.05)}.full{width:100%}.pill,.badge{display:inline-flex;align-items:center;gap:6px;border-radius:999px;padding:7px 10px;font-size:12px;font-weight:900;background:rgba(255,255,255,.08);border:1px solid var(--line)}.ok{color:#86efac}.warn{color:#fdba74}.danger{color:#fca5a5}.badge.ok,.pill.ok{background:rgba(34,197,94,.13)}.badge.danger{background:rgba(239,68,68,.13)}.table-wrap{overflow:auto}table{width:100%;border-collapse:collapse;min-width:820px}th,td{text-align:left;padding:13px 10px;border-bottom:1px solid var(--line);vertical-align:middle}th{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.08em}code{background:rgba(0,0,0,.25);padding:3px 7px;border-radius:8px;color:#fde68a}.actions{display:flex;flex-wrap:wrap;gap:6px}.mini{padding:7px 9px;border-radius:10px;background:rgba(255,255,255,.08);color:var(--text);border:1px solid var(--line)}.mini:disabled{opacity:.35;cursor:not-allowed}.form{display:grid;gap:12px}.form label{font-weight:900;color:var(--muted);font-size:13px}.form input,.form select,.form textarea{width:100%;border:1px solid var(--line);background:rgba(0,0,0,.24);color:var(--text);border-radius:14px;padding:12px;outline:none}.grid-form{grid-template-columns:repeat(2,minmax(0,1fr))}.grid-form.small{grid-template-columns:repeat(3,minmax(0,1fr))}.wide{grid-column:1/-1}.alert{padding:13px 15px;border-radius:16px;margin-bottom:16px;border:1px solid var(--line);background:rgba(255,255,255,.07);font-weight:800}.alert.success{color:#86efac}.alert.danger{color:#fca5a5}.login-body{display:grid;place-items:center;padding:22px}.login-card{width:min(440px,100%);border:1px solid var(--line);background:rgba(10,13,30,.78);border-radius:30px;padding:28px;box-shadow:0 30px 120px rgba(0,0,0,.4);backdrop-filter:blur(20px)}.login-brand{margin-bottom:20px}.center{text-align:center}.kv{display:flex;justify-content:space-between;gap:16px;padding:14px 0;border-bottom:1px solid var(--line)}.kv span{color:var(--muted)}.node-card h3{margin:14px 0 6px}.node-card p{color:var(--muted)}.mini-grid{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-top:16px}.mini-grid span{color:var(--muted)}.error-card h1{margin-top:0}@media(max-width:900px){.shell{grid-template-columns:1fr}.sidebar{position:relative;height:auto}.logout{position:relative;left:auto;right:auto;bottom:auto;margin-top:20px}.stats{grid-template-columns:repeat(2,1fr)}.grid-form,.grid-form.small{grid-template-columns:1fr}.topbar,.hero,.page-title{align-items:flex-start;flex-direction:column}.hero h1,.page-title h1{font-size:28px}}
APPFILE

  cat > "${APP_DIR}/public/js/app.js" <<'APPFILE'
document.querySelectorAll('form[action$="/power"] button').forEach(btn=>{btn.addEventListener('click',()=>{btn.textContent='Sending...';});});
APPFILE

  cat > "${APP_DIR}/ecosystem.config.js" <<'APPFILE'
module.exports = {
  apps: [{
    name: 'stellar-ptero-panel',
    script: 'server.js',
    cwd: '/opt/stellar-ptero-panel',
    instances: 1,
    autorestart: true,
    watch: false,
    max_memory_restart: '350M',
    env: { NODE_ENV: 'production' }
  }]
};
APPFILE
}

write_env() {
  SESSION_SECRET="$(cat /proc/sys/kernel/random/uuid | tr -d '-')$(cat /proc/sys/kernel/random/uuid | tr -d '-')"
  cat > "${APP_DIR}/.env" <<EOF
APP_NAME=Stellar Panel
PORT=${APP_PORT}
PTERO_URL=${PTERO_URL}
PTLA_KEY=${PTLA_KEY}
PTLC_KEY=${PTLC_KEY}
ADMIN_USERNAME=${ADMIN_USERNAME}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
SESSION_SECRET=${SESSION_SECRET}
COOKIE_SECURE=true
EOF
  chmod 600 "${APP_DIR}/.env"
}

install_node_modules() {
  echo -e "${CYAN}Install module Node.js...${NC}"
  cd "${APP_DIR}"
  npm install --omit=dev
}

setup_pm2() {
  echo -e "${CYAN}Setup PM2...${NC}"
  pm2 delete stellar-ptero-panel >/dev/null 2>&1 || true
  pm2 start "${APP_DIR}/ecosystem.config.js"
  pm2 save
  pm2 startup systemd -u root --hp /root >/tmp/stellar-pm2-startup.log 2>&1 || true
}

setup_nginx() {
  echo -e "${CYAN}Setup Nginx reverse proxy...${NC}"
  cat > "/etc/nginx/sites-available/stellar-ptero-panel" <<EOF
server {
    listen 80;
    server_name ${CUSTOM_DOMAIN};

    client_max_body_size 50m;

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF
  ln -sf /etc/nginx/sites-available/stellar-ptero-panel /etc/nginx/sites-enabled/stellar-ptero-panel
  nginx -t
  systemctl reload nginx
}

setup_ssl() {
  echo ""
  read -rp "Pasang SSL Let's Encrypt sekarang? (y/N): " SSL_ASK
  if [[ "${SSL_ASK,,}" == "y" ]]; then
    read -rp "Email untuk SSL: " SSL_EMAIL
    certbot --nginx -d "${CUSTOM_DOMAIN}" --non-interactive --agree-tos -m "${SSL_EMAIL}" --redirect
    systemctl reload nginx
  fi
}

finish() {
  echo ""
  echo -e "${GREEN}Install selesai.${NC}"
  echo -e "Web custom: ${CYAN}https://${CUSTOM_DOMAIN}${NC}"
  echo -e "User admin: ${CYAN}${ADMIN_USERNAME}${NC}"
  echo -e "Password: ${CYAN}${ADMIN_PASSWORD}${NC}"
  echo ""
  echo "Command penting:"
  echo "pm2 status"
  echo "pm2 logs stellar-ptero-panel"
  echo "pm2 restart stellar-ptero-panel"
  echo "nano ${APP_DIR}/.env"
}

main() {
  banner
  check_root
  check_os
  ask_config
  install_packages
  write_app_files
  write_env
  install_node_modules
  setup_pm2
  setup_nginx
  setup_ssl
  finish
}

main "$@"
