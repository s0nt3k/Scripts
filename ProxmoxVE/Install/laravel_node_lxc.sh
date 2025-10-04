#!/usr/bin/env bash
# Proxmox helper: Create Debian 12 LXC with Nginx + PHP (Laravel) + Node/Express
# Tested on Proxmox VE 8.x. Run as root on the Proxmox host.
# Usage: bash proxmox_laravel_node_lxc.sh
set -euo pipefail

### -------- USER CONFIG (edit as needed) --------
CTID="${CTID:-120}"                         # Container ID (must be unique)
HOSTNAME="${HOSTNAME_LXC:-webapp}"          # Container hostname
PASSWORD="${PASSWORD_LXC:-ChangeMeNow!}"    # Root password for the container
STORAGE="${STORAGE:-local-lvm}"             # Proxmox storage for rootfs
BRIDGE="${BRIDGE:-vmbr0}"                   # Network bridge on the host
IP4="${IP4:-dhcp}"                          # Static like '192.168.1.50/24,gw=192.168.1.1' or 'dhcp'
NESTING="${NESTING:-1}"                     # Enable nesting (needed for some builds)
UNPRIV="${UNPRIV:-1}"                       # Unprivileged container (recommended)
CORES="${CORES:-2}"
MEMORY_MB="${MEMORY_MB:-2048}"
DISK_GB="${DISK_GB:-12}"
TIMEZONE="${TIMEZONE:-Etc/UTC}"
#
# App settings
LARAVEL_DIR="/var/www/laravel"
NODE_DIR="/opt/express-app"
DOMAIN="${DOMAIN:-example.local}"           # Nginx server_name
API_PATH="${API_PATH:-/api}"                # Reverse proxy path to Express
NODE_PORT="${NODE_PORT:-3000}"
PHP_FPM_SOCK="/run/php/php8.2-fpm.sock"     # Debian 12 default
#
# Bootstrap settings
BOOTSTRAP_URL="${BOOTSTRAP_URL:-https://github.com/twbs/bootstrap/releases/download/v5.0.2/bootstrap-5.0.2-dist.zip}"
### --------------------------------------------

echo "==> Creating Debian 12 LXC ${CTID} (${HOSTNAME}) on storage ${STORAGE}..."

# Get Debian 12 template if missing
template_name="$(pveam available --section system | awk '/debian-12-standard/ {print $2}' | sort -V | tail -n1)"
if [[ -z "${template_name}" ]]; then
  echo "Could not find Debian 12 template in catalog. Updating template catalog..."
  pveam update
  template_name="$(pveam available --section system | awk '/debian-12-standard/ {print $2}' | sort -V | tail -n1)"
fi

if ! pveam list ${STORAGE} | awk '{print $2}' | grep -q "${template_name}"; then
  echo "==> Downloading template ${template_name} to ${STORAGE}..."
  pveam download "${STORAGE}" "${template_name}"
fi

if pct status "${CTID}" &>/dev/null; then
  echo "==> Container ${CTID} already exists. Skipping creation."
else
  echo "==> Creating container..."
  pct create "${CTID}" "${STORAGE}:vztmpl/${template_name}" \
    -hostname "${HOSTNAME}" \
    -password "${PASSWORD}" \
    -cores "${CORES}" \
    -memory "${MEMORY_MB}" \
    -rootfs "${STORAGE}:${DISK_GB}" \
    -net0 "name=eth0,bridge=${BRIDGE},ip=${IP4}" \
    -features "nesting=${NESTING}" \
    -unprivileged "${UNPRIV}" \
    -start 0 \
    -timezone "${TIMEZONE}"
fi

# Ensure nesting feature (sometimes not applied on existing CTs)
pct set "${CTID}" -features "nesting=${NESTING}"

echo "==> Starting container ${CTID}..."
pct start "${CTID}" || true

echo "==> Waiting for network..."
sleep 5

# Helper to run commands in the container
run() { pct exec "${CTID}" -- bash -lc "$*"; }

echo "==> Updating container packages..."
run "export DEBIAN_FRONTEND=noninteractive; apt-get update -y && apt-get upgrade -y"

echo "==> Installing base tools..."
run "apt-get install -y ca-certificates curl wget git unzip ufw rsync"

echo "==> Installing Nginx + PHP for Laravel..."
run "apt-get install -y nginx php8.2-fpm php8.2-cli php8.2-common php8.2-mbstring php8.2-xml php8.2-zip php8.2-curl php8.2-sqlite3 php8.2-gd php8.2-bcmath php8.2-intl"

echo '==> Enabling and starting services...'
run "systemctl enable --now nginx php8.2-fpm"

echo "==> Installing Composer..."
run "EXPECTED_CHECKSUM=\$(wget -q -O - https://composer.github.io/installer.sig) && \
    php -r \"copy('https://getcomposer.org/installer','composer-setup.php');\" && \
    ACTUAL_CHECKSUM=\$(php -r \"echo hash_file('sha384', 'composer-setup.php');\") && \
    [ \"\$EXPECTED_CHECKSUM\" = \"\$ACTUAL_CHECKSUM\" ] && \
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer && \
    rm composer-setup.php"

echo "==> Creating Laravel app at ${LARAVEL_DIR}..."
run "mkdir -p ${LARAVEL_DIR} && cd \$(dirname ${LARAVEL_DIR}) && \
    COMPOSER_ALLOW_SUPERUSER=1 composer create-project laravel/laravel $(basename ${LARAVEL_DIR}) --no-interaction"

echo "==> Adjusting permissions for Laravel..."
run "chown -R www-data:www-data ${LARAVEL_DIR}/storage ${LARAVEL_DIR}/bootstrap/cache"

echo "==> Downloading Bootstrap 5.0.2 and extracting to /var/www ..."
run "tmpdir=\$(mktemp -d) && cd \${tmpdir} && \
    wget -qO bootstrap.zip '${BOOTSTRAP_URL}' && \
    unzip -q bootstrap.zip && \
    rsync -a bootstrap-5.0.2-dist/ /var/www/ && \
    chown -R www-data:www-data /var/www/css /var/www/js || true && \
    rm -rf \${tmpdir}"

echo "==> Configuring Nginx server block for Laravel + Express proxy..."
NGINX_CONF="/etc/nginx/sites-available/${HOSTNAME}.conf"
run "cat > ${NGINX_CONF} <<'NGINX'
server {
    listen 80;
    server_name ${DOMAIN};
    root ${LARAVEL_DIR}/public;
    index index.php index.html;

    # Proxy ${API_PATH} to Node/Express
    location ${API_PATH}/ {
        proxy_pass http://127.0.0.1:${NODE_PORT}${API_PATH}/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_FPM_SOCK};
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ {
        try_files \$uri \$uri/ =404;
        expires max;
        log_not_found off;
    }
}
NGINX"

run "ln -sf ${NGINX_CONF} /etc/nginx/sites-enabled/${HOSTNAME}.conf && rm -f /etc/nginx/sites-enabled/default && nginx -t && systemctl reload nginx"

echo "==> Installing Node.js (20.x LTS) and PM2..."
run "curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt-get install -y nodejs && npm i -g pm2"

echo "==> Creating sample Express API at ${NODE_DIR} (listens on ${NODE_PORT})..."
run "mkdir -p ${NODE_DIR} && cd ${NODE_DIR} && \
    cat > package.json <<'PKG'
{
  \"name\": \"express-api\",
  \"version\": \"1.0.0\",
  \"main\": \"index.js\",
  \"type\": \"module\",
  \"scripts\": {
    \"start\": \"node index.js\"
  },
  \"dependencies\": {
    \"express\": \"^4.19.2\"
  }
}
PKG
    npm install
    cat > index.js <<'JS'
import express from 'express';
const app = express();
const port = process.env.PORT || ${NODE_PORT};
const apiBase = '${API_PATH}';
app.get(apiBase + '/', (req, res) => res.json({ ok: true, message: 'Express API root' }));
app.get(apiBase + '/health', (req, res) => res.json({ status: 'healthy', ts: new Date().toISOString() }));
app.listen(port, '0.0.0.0', () => console.log(\`Express listening on \${port} (base:\${apiBase})\`));
JS"

echo "==> Launching Express with PM2 and enabling startup on boot..."
run "pm2 start ${NODE_DIR}/index.js --name express-api && pm2 save && pm2 startup systemd -u root --hp /root >/tmp/pm2_startup.txt 2>&1 || true"
run "bash -lc \"$(grep -oE 'sudo .*pm2.*startup.*' /tmp/pm2_startup.txt || true)\" || true
     systemctl daemon-reload || true"

echo "==> Optional: Basic UFW firewall (allow 80/tcp)"
run "ufw allow 80/tcp || true; ufw --force enable || true"

echo "==> All done!"
echo "------------------------------------------------------------"
echo "Container ID: ${CTID}"
echo "Hostname    : ${HOSTNAME}"
echo "Laravel     : http://<container-ip>/"
echo "Express API : http://<container-ip>${API_PATH}/ (proxied)"
echo "Nginx cfg   : ${NGINX_CONF}"
echo "Laravel dir : ${LARAVEL_DIR}"
echo "Node dir    : ${NODE_DIR}"
echo "Bootstrap   : /var/www/css and /var/www/js"
echo "To get the container's IP: pct exec ${CTID} -- hostname -I"
echo "------------------------------------------------------------"
