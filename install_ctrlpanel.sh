#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Powered By Saturo Tech
BANNER="
  ____        _ _       _           ____  _           _     
 / ___|  __ _| (_) __ _| |__  _   _|  _ \\| |__   ___ | |___ 
 \\___ \\ / _\` | | |/ _\` | '_ \\| | | | |_) | '_ \\ / _ \\| / __|
  ___) | (_| | | | (_| | |_) | |_| |  __/| | | | (_) | \\__ \\
 |____/ \\__,_|_|_|\\__,_|_.__/ \\__, |_|   |_| |_|\\___/|_|___/
                              |___/                        
                 Powered By Saturo Tech
"

echo -e "$BANNER"

# Ensure script is run as root
if [[ "$EUID" -ne 0 ]]; then
  echo "This script must be run as root. Run: sudo $0"
  exit 1
fi

# Helper: prompt with default
prompt() {
  local varname="$1"
  local prompt_text="$2"
  local default="$3"
  local silent="${4:-no}" # "yes" to hide input
  local input

  if [[ "$silent" == "yes" ]]; then
    read -r -s -p "$prompt_text [$default]: " input
    echo
  else
    read -r -p "$prompt_text [$default]: " input
  fi
  if [[ -z "$input" ]]; then
    eval "$varname=\"$default\""
  else
    eval "$varname=\"$input\""
  fi
}

# Defaults and prompts
prompt DOMAIN "Enter domain to use for the panel (A record must point to this server)" "panel.localhost"
prompt SSL_EMAIL "Enter email for SSL certificate (Let's Encrypt) or leave blank to skip" "admin@$DOMAIN"

# Database prompts (defaults accepted by pressing Enter)
prompt DB_NAME "Enter database name" "ctrlpanel"
prompt DB_USER "Enter database username" "ctrluser"

# Generate random DB password if left empty (not shown in prompt as default)
DEFAULT_DB_PASS="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20 || echo 'ctrlpass')"
read -r -p "Enter database password (press Enter to generate a strong one): " DB_PASS
if [[ -z "$DB_PASS" ]]; then
  DB_PASS="$DEFAULT_DB_PASS"
fi

prompt DB_HOST "Enter database host" "localhost"

# Ask for root password (hidden). If blank, socket auth will be attempted.
prompt MYSQL_ROOT_PASS "Enter MySQL/MariaDB root password (leave blank to use socket auth)" "" "yes"

# Application and repo settings
APP_DIR="/var/www/ctrlpanel"
REPO_URL="https://github.com/Ctrlpanel-gg/panel.git"

echo
echo "[INFO] Summary of inputs:"
echo "  Domain:        $DOMAIN"
echo "  SSL Email:     $SSL_EMAIL"
echo "  DB Host:       $DB_HOST"
echo "  DB Name:       $DB_NAME"
echo "  DB User:       $DB_USER"
echo "  App directory: $APP_DIR"
echo

read -r -p "Proceed with installation? [Y/n] " proceed
proceed=${proceed:-Y}
if [[ ! "$proceed" =~ ^([Yy])$ ]]; then
  echo "Installation aborted."
  exit 0
fi

apt_get_update_if_needed() {
  if [[ ! -f /var/lib/apt/periodic/update-success-stamp ]] || [[ $(find /var/lib/apt/periodic/update-success-stamp -mmin +60 2>/dev/null || true) ]]; then
    apt-get update
  fi
}

echo "[INFO] Updating package lists..."
apt_get_update_if_needed

# Install packages (adjust PHP version via meta-package php)
echo "[INFO] Installing required packages..."
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  git curl wget unzip ca-certificates gnupg software-properties-common \
  nginx ufw redis-server \
  mariadb-server \
  php-fpm php-cli php-mysql php-xml php-mbstring php-bcmath php-zip php-gd php-curl php-intl \
  certbot python3-certbot-nginx

# Composer may not be in package; install if missing
if ! command -v composer >/dev/null 2>&1; then
  echo "[INFO] Installing Composer..."
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
fi

# Configure UFW
echo "[INFO] Configuring UFW (allow OpenSSH and Nginx Full)..."
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw --force enable

# Clone/app setup
if [[ ! -d "$APP_DIR" ]]; then
  echo "[INFO] Cloning repository into $APP_DIR..."
  mkdir -p "$APP_DIR"
  chown "$SUDO_USER":"$SUDO_USER" "$APP_DIR" 2>/dev/null || true
  git clone "$REPO_URL" "$APP_DIR" || { echo "[ERROR] Failed to clone $REPO_URL"; exit 1; }
else
  echo "[INFO] $APP_DIR already exists — pulling latest changes..."
  git -C "$APP_DIR" fetch --all || true
  git -C "$APP_DIR" reset --hard origin/HEAD || true
fi

# Detect php-fpm socket
PHP_FPM_SOCK=""
SOCKS=(/run/php/php*-fpm.sock /var/run/php/php*-fpm.sock)
for pattern in "${SOCKS[@]}"; do
  for f in $pattern; do
    if [[ -S "$f" ]]; then
      PHP_FPM_SOCK="$f"
      break 2
    fi
  done
done
# If not found, try to start php-fpm then retry
if [[ -z "$PHP_FPM_SOCK" ]]; then
  echo "[INFO] php-fpm socket not found — attempting to start php-fpm and retry..."
  systemctl enable --now 'php*-fpm.service' 2>/dev/null || true
  sleep 2
  for pattern in "${SOCKS[@]}"; do
    for f in $pattern; do
      if [[ -S "$f" ]]; then
        PHP_FPM_SOCK="$f"
        break 2
      fi
    done
  done
fi

if [[ -z "$PHP_FPM_SOCK" ]]; then
  # Fallback to generic socket path (may need manual fix)
  PHP_FPM_SOCK="/run/php/php7.4-fpm.sock"
  echo "[WARN] Could not detect php-fpm socket automatically. Using fallback $PHP_FPM_SOCK — verify this is correct."
fi

# Install Composer dependencies as www-data (safer)
echo "[INFO] Installing PHP dependencies with Composer (as www-data)..."
chown -R www-data:www-data "$APP_DIR"
sudo -u www-data composer install --no-dev --optimize-autoloader -d "$APP_DIR" || { echo "[ERROR] Composer install failed"; exit 1; }

# Environment setup
echo "[INFO] Preparing .env"
if [[ -f "$APP_DIR/.env" ]]; then
  cp -n "$APP_DIR/.env" "$APP_DIR/.env.bak" || true
fi
if [[ -f "$APP_DIR/.env.example" ]]; then
  cp -f "$APP_DIR/.env.example" "$APP_DIR/.env"
else
  echo "[WARN] .env.example not found — creating minimal .env"
  cat > "$APP_DIR/.env" <<EOL
APP_NAME=CtrlPanel
APP_ENV=production
APP_KEY=
APP_DEBUG=false
APP_URL=https://$DOMAIN

DB_CONNECTION=mysql
DB_HOST=$DB_HOST
DB_PORT=3306
DB_DATABASE=$DB_NAME
DB_USERNAME=$DB_USER
DB_PASSWORD=$DB_PASS
EOL
fi

# Replace or set values in .env reliably
sed -i "s|APP_URL=.*|APP_URL=https://$DOMAIN|" "$APP_DIR/.env" || true
sed -i "s|DB_DATABASE=.*|DB_DATABASE=$DB_NAME|" "$APP_DIR/.env" || true
sed -i "s|DB_USERNAME=.*|DB_USERNAME=$DB_USER|" "$APP_DIR/.env" || true
sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=$DB_PASS|" "$APP_DIR/.env" || true

# Database creation: use socket auth if no root password supplied, else use temp defaults file
run_mysql() {
  local sql="$1"
  if [[ -z "$MYSQL_ROOT_PASS" ]]; then
    # Use socket auth; host may be localhost or remote
    if [[ "$DB_HOST" == "localhost" || "$DB_HOST" == "127.0.0.1" ]]; then
      mysql -u root -e "$sql"
    else
      mysql -u root -h "$DB_HOST" -e "$sql"
    fi
  else
    # Use temporary defaults file to avoid showing password on cmdline
    local tmpcnf
    tmpcnf="$(mktemp)"
    chmod 600 "$tmpcnf"
    cat > "$tmpcnf" <<EOF
[client]
user=root
password=$MYSQL_ROOT_PASS
host=$DB_HOST
EOF
    mysql --defaults-file="$tmpcnf" -e "$sql"
    rm -f "$tmpcnf"
  fi
}

echo "[INFO] Creating database and user (if not exists)..."
SQL="
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
"
run_mysql "$SQL" || { echo "[ERROR] Database setup failed"; exit 1; }

# Run artisan commands as www-data
echo "[INFO] Running Laravel artisan commands..."
cd "$APP_DIR"
sudo -u www-data php artisan key:generate --force
sudo -u www-data php artisan migrate --force
sudo -u www-data php artisan config:cache || true
sudo -u www-data php artisan route:cache || true
sudo -u www-data php artisan storage:link || true

# Prompt to create admin user via documented command
echo
read -r -p "Create initial admin user now using 'php artisan panel:admin'? [Y/n] " create_admin
create_admin=${create_admin:-Y}
if [[ "$create_admin" =~ ^([Yy])$ ]]; then
  if sudo -u www-data php artisan panel:admin; then
    echo "[INFO] Admin user created via php artisan panel:admin."
  else
    echo "[WARN] 'php artisan panel:admin' failed or is unavailable. You can create an admin user manually:"
    echo "  - SSH to $APP_DIR and run: sudo -u www-data php artisan panel:admin"
    echo "  - Or use artisan tinker to create a user model if needed."
  fi
else
  echo "[INFO] Skipping admin creation. You can run 'php artisan panel:admin' later in $APP_DIR."
fi

# Permissions
echo "[INFO] Setting permissions..."
chown -R www-data:www-data "$APP_DIR"
find "$APP_DIR" -type f -exec chmod 644 {} \;
find "$APP_DIR" -type d -exec chmod 755 {} \;
chmod -R ug+rwx "$APP_DIR"/storage "$APP_DIR"/bootstrap/cache || true

# Nginx site config
NGINX_CONF="/etc/nginx/sites-available/ctrlpanel"
echo "[INFO] Creating Nginx configuration ($NGINX_CONF)..."
cat > "$NGINX_CONF" <<EOL
server {
    listen 80;
    server_name $DOMAIN;

    root $APP_DIR/public;
    index index.php index.html;

    access_log /var/log/nginx/ctrlpanel.access.log;
    error_log  /var/log/nginx/ctrlpanel.error.log;

    client_max_body_size 100m;
    client_body_timeout 120s;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_FPM_SOCK;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOL

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/ctrlpanel
# Remove default if present
if [[ -f /etc/nginx/sites-enabled/default ]]; then
  rm -f /etc/nginx/sites-enabled/default
fi

echo "[INFO] Testing and reloading Nginx..."
nginx -t
systemctl reload nginx

# Setup cron (system cron file so it runs as www-data; artisan schedule uses php binary path)
echo "[INFO] Installing cron job for Laravel schedule..."
cat > /etc/cron.d/ctrlpanel <<EOL
* * * * * www-data /usr/bin/php $APP_DIR/artisan schedule:run >> /dev/null 2>&1
EOL
chmod 644 /etc/cron.d/ctrlpanel

# Obtain SSL certificate (skip if using local domain)
if [[ "$DOMAIN" == "localhost" || "$DOMAIN" == "panel.localhost" || "$DOMAIN" =~ ^127\.0\.0\.1$ ]]; then
  echo "[INFO] Local domain detected; skipping Let's Encrypt certificate issuance."
else
  if [[ -n "$SSL_EMAIL" ]]; then
    echo "[INFO] Attempting to obtain SSL certificate for $DOMAIN via Certbot..."
    certbot_args=(--nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$SSL_EMAIL")
    # Try with --redirect to enable HTTPS
    if certbot "${certbot_args[@]}" --redirect; then
      echo "[INFO] SSL certificate obtained and configured."
    else
      echo "[WARN] Certbot failed. You can try to run: certbot --nginx -d $DOMAIN -m $SSL_EMAIL"
    fi
  else
    echo "[INFO] No SSL email provided — skipping Certbot. You can run certbot later to obtain a certificate."
  fi
fi

echo
echo "------------------------------------------------------------"
echo "CtrlPanel installation finished."
echo "Access:   https://$DOMAIN"
echo "App dir:  $APP_DIR"
echo "DB name:  $DB_NAME"
echo "DB user:  $DB_USER"
echo "DB pass:  $DB_PASS"
echo "------------------------------------------------------------"
echo "Powered By Saturo Tech"
