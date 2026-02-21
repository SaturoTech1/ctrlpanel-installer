#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Ctrl Installer
BANNER="
  _____            _ _        _           _             
 / ____|          | (_)      | |         | |            
| |     ___  _ __ | |_  ___  | |     ___ | | _____ _ __ 
| |    / _ \| '_ \| | |/ _ \ | |    / _ \| |/ / _ \ '__|
| |___| (_) | | | | | |  __/ | |___| (_) |   <  __/ |   
 \_____\___/|_| |_|_|_|\___| |______\___/|_|\_\___/|_|   

                Ctrl Installer
                Powered By Saturo Tech
"

echo -e "$BANNER"

# Ensure script is run as root
if [[ "$EUID" -ne 0 ]]; then
  echo "This script must be run as root. Run: sudo $0"
  exit 1
fi

# Helper: prompt with default (non-hidden)
prompt() {
  local varname="$1"
  local prompt_text="$2"
  local default="$3"
  local input
  read -r -p "$prompt_text [$default]: " input
  if [[ -z "$input" ]]; then
    eval "$varname=\"$default\""
  else
    eval "$varname=\"$input\""
  fi
}

# Helper: prompt hidden (password)
prompt_hidden() {
  local varname="$1"
  local prompt_text="$2"
  local default="$3"
  local input
  read -r -s -p "$prompt_text [$default]: " input
  echo
  if [[ -z "$input" ]]; then
    eval "$varname=\"$default\""
  else
    eval "$varname=\"$input\""
  fi
}

# Helper: execute mysql safely (uses socket auth if no root pass)
run_mysql() {
  local sql="$1"
  local host="${2:-localhost}"
  local rootpass="${3:-}"
  if [[ -z "$rootpass" ]]; then
    # socket auth
    if [[ "$host" == "localhost" || "$host" == "127.0.0.1" ]]; then
      mysql -u root -e "$sql"
    else
      mysql -u root -h "$host" -e "$sql"
    fi
  else
    local tmpcnf
    tmpcnf="$(mktemp)"
    chmod 600 "$tmpcnf"
    cat > "$tmpcnf" <<EOF
[client]
user=root
password=$rootpass
host=$host
EOF
    mysql --defaults-file="$tmpcnf" -e "$sql"
    rm -f "$tmpcnf"
  fi
}

# Ensure PHP Redis extension is installed and enabled for both CLI and FPM
ensure_php_redis() {
  echo "[INFO] Checking for PHP Redis extension..."

  # Detect CLI PHP version (major.minor)
  if ! command -v php >/dev/null 2>&1; then
    echo "[WARN] php CLI not found. Skipping php-redis automatic install."
    return 1
  fi

  PHPVER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "")
  if [[ -z "$PHPVER" ]]; then
    echo "[WARN] Could not detect PHP version. Skipping automatic php-redis install."
    return 1
  fi
  echo "[INFO] Detected PHP version: $PHPVER"

  # Check CLI module first
  if php -m 2>/dev/null | grep -qi '^redis$'; then
    echo "[INFO] PHP CLI already has redis extension loaded."
    CLI_OK=1
  else
    CLI_OK=0
  fi

  # Try to check FPM loaded modules by calling php -m through php-fpm (best-effort)
  FPM_OK=0
  # Create a temporary phpinfo endpoint only if nginx is already configured and running
  TMP_PHPINFO="/tmp/ctrl_inst_phpinfo_$$.php"
  TMP_HTML="/tmp/ctrl_inst_phpinfo_$$.html"
  if systemctl is-active --quiet nginx 2>/dev/null && [[ -d /var/www/html || -d /var/www/ctrlpanel/public ]]; then
    # prefer ctrlpanel public if exists
    WEBROOT="/var/www/ctrlpanel/public"
    if [[ ! -d "$WEBROOT" ]]; then
      WEBROOT="/var/www/html"
    fi
    echo '<?php phpinfo();' > "$TMP_PHPINFO"
    mv "$TMP_PHPINFO" "$WEBROOT/phpinfo_ctrl_inst.php" 2>/dev/null || true
    # Try query localhost to hit FPM
    if curl -sS --max-time 5 "http://127.0.0.1/phpinfo_ctrl_inst.php" -o "$TMP_HTML" 2>/dev/null; then
      if grep -qi 'redis' "$TMP_HTML"; then
        FPM_OK=1
      fi
    fi
    rm -f "$WEBROOT/phpinfo_ctrl_inst.php" "$TMP_HTML" >/dev/null 2>&1 || true
  fi

  if [[ $CLI_OK -eq 1 && $FPM_OK -eq 1 ]]; then
    echo "[INFO] PHP Redis extension is available for both CLI and FPM."
    return 0
  fi

  echo "[INFO] Redis extension missing for CLI or FPM. Attempting automatic install."

  # Try apt install for the detected PHP version
  apt_get_update_if_needed() {
    if [[ ! -f /var/lib/apt/periodic/update-success-stamp ]] || [[ $(find /var/lib/apt/periodic/update-success-stamp -mmin +60 2>/dev/null || true) ]]; then
      apt-get update
    fi
  }
  apt_get_update_if_needed

  INSTALLED=0

  # Attempt versioned package first
  if apt-cache show "php${PHPVER}-redis" >/dev/null 2>&1; then
    echo "[INFO] Installing php${PHPVER}-redis via apt..."
    if apt-get install -y "php${PHPVER}-redis"; then INSTALLED=1; fi
  fi

  # Fallback to distro php-redis package
  if [[ $INSTALLED -eq 0 ]]; then
    echo "[INFO] Attempting apt install php-redis..."
    if apt-get install -y php-redis; then INSTALLED=1; fi
  fi

  # If apt failed, try pecl
  if [[ $INSTALLED -eq 0 ]]; then
    echo "[INFO] Apt packages unavailable or install failed — attempting pecl install (build dependencies will be installed)..."
    apt-get install -y php-dev php-pear build-essential || true
    if pecl install -f redis; then
      PHPINI_DIR="/etc/php/${PHPVER}/mods-available"
      mkdir -p "$PHPINI_DIR"
      echo "extension=redis.so" > "${PHPINI_DIR}/redis.ini"
      INSTALLED=1
    else
      echo "[ERROR] pecl install redis failed."
    fi
  fi

  if [[ $INSTALLED -eq 0 ]]; then
    echo "[ERROR] Could not install php redis extension automatically. Please install php${PHPVER}-redis or php-redis manually and re-run."
    return 1
  fi

  # Enable module and restart php-fpm services
  echo "[INFO] Enabling redis extension and restarting PHP-FPM..."
  # Try enabling for the detected PHP version, then globally
  if command -v phpenmod >/dev/null 2>&1; then
    phpenmod -v "$PHPVER" redis >/dev/null 2>&1 || phpenmod redis >/dev/null 2>&1 || true
  fi

  # Restart FPM service for detected php version; try multiple common service names
  if systemctl list-units --type=service --full | grep -q "php${PHPVER}-fpm"; then
    systemctl restart "php${PHPVER}-fpm" || true
  else
    systemctl restart "php-fpm" 2>/dev/null || systemctl restart "php7.4-fpm" 2>/dev/null || true
  fi

  systemctl restart nginx 2>/dev/null || true
  sleep 1

  # Verify CLI again
  if php -m 2>/dev/null | grep -qi '^redis$'; then
    echo "[INFO] PHP CLI redis extension OK."
    CLI_OK=1
  else
    CLI_OK=0
  fi

  # Try to detect via FPM again if possible (best-effort)
  if systemctl is-active --quiet nginx 2>/dev/null && [[ -d /var/www/ctrlpanel/public || -d /var/www/html ]]; then
    WEBROOT="/var/www/ctrlpanel/public"
    if [[ ! -d "$WEBROOT" ]]; then WEBROOT="/var/www/html"; fi
    echo '<?php phpinfo();' > "$WEBROOT/phpinfo_ctrl_inst.php"
    if curl -sS --max-time 5 "http://127.0.0.1/phpinfo_ctrl_inst.php" -o "$TMP_HTML" 2>/dev/null; then
      if grep -qi 'redis' "$TMP_HTML"; then
        FPM_OK=1
      else
        FPM_OK=0
      fi
    fi
    rm -f "$WEBROOT/phpinfo_ctrl_inst.php" "$TMP_HTML" >/dev/null 2>&1 || true
  fi

  if [[ $CLI_OK -eq 1 ]]; then
    echo "[INFO] php-redis is now loaded for CLI."
  else
    echo "[WARN] php-redis still not loaded for CLI."
  fi
  if [[ $FPM_OK -eq 1 ]]; then
    echo "[INFO] php-redis appears loaded for FPM (verified via HTTP phpinfo)."
  else
    echo "[WARN] Could not verify php-redis for FPM. If your site uses a different PHP-FPM version, enable redis for that version and restart its service."
  fi

  if [[ $CLI_OK -eq 1 ]]; then
    return 0
  else
    return 1
  fi
}

APP_DIR="/var/www/ctrlpanel"
REPO_URL="https://github.com/Ctrlpanel-gg/panel.git"
NGINX_CONF="/etc/nginx/sites-available/ctrlpanel"
CRON_FILE="/etc/cron.d/ctrlpanel"
SYSTEMD_SERVICE="/etc/systemd/system/ctrlpanel.service"

install() {
  echo "[INFO] Starting installation flow."

  # Prompts and defaults
  prompt DOMAIN "Enter domain to use for the panel (A record must point to this server)" "panel.localhost"
  prompt SSL_EMAIL "Enter email for SSL certificate (Let's Encrypt) or leave blank to skip" "admin@$DOMAIN"
  prompt DB_NAME "Enter database name" "ctrlpanel"
  prompt DB_USER "Enter database username" "ctrluser"

  DEFAULT_DB_PASS="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20 || echo 'ctrlpass')"
  read -r -p "Enter database password (press Enter to generate a strong one): " DB_PASS
  if [[ -z "$DB_PASS" ]]; then
    DB_PASS="$DEFAULT_DB_PASS"
  fi

  prompt DB_HOST "Enter database host" "localhost"
  prompt_hidden MYSQL_ROOT_PASS "Enter MySQL/MariaDB root password (leave blank to use socket auth)" ""

  echo
  echo "[INFO] Summary:"
  echo "  Domain: $DOMAIN"
  echo "  SSL Email: $SSL_EMAIL"
  echo "  DB Host: $DB_HOST"
  echo "  DB: $DB_NAME"
  echo "  DB User: $DB_USER"
  echo "  App dir: $APP_DIR"
  read -r -p "Proceed? [Y/n] " proceed; proceed=${proceed:-Y}
  if [[ ! "$proceed" =~ ^([Yy])$ ]]; then
    echo "Aborted."
    exit 0
  fi

  apt_get_update_if_needed() {
    if [[ ! -f /var/lib/apt/periodic/update-success-stamp ]] || [[ $(find /var/lib/apt/periodic/update-success-stamp -mmin +60 2>/dev/null || true) ]]; then
      apt-get update
    fi
  }

  echo "[INFO] Updating package lists..."
  apt_get_update_if_needed

  echo "[INFO] Installing required packages (nginx, php-fpm, mariadb, redis, certbot, etc)..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git curl wget unzip ca-certificates gnupg software-properties-common \
    nginx ufw redis-server \
    mariadb-server \
    php-fpm php-cli php-mysql php-xml php-mbstring php-bcmath php-zip php-gd php-curl php-intl \
    certbot python3-certbot-nginx

  # Ensure composer exists
  if ! command -v composer >/dev/null 2>&1; then
    echo "[INFO] Installing Composer..."
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
  fi

  # UFW
  echo "[INFO] Configuring UFW (OpenSSH, Nginx Full)..."
  ufw allow OpenSSH
  ufw allow 'Nginx Full'
  ufw --force enable || true

  # Clone repo
  if [[ ! -d "$APP_DIR" ]]; then
    echo "[INFO] Cloning repository into $APP_DIR..."
    mkdir -p "$APP_DIR"
    git clone "$REPO_URL" "$APP_DIR" || { echo "[ERROR] Failed to clone $REPO_URL"; exit 1; }
  else
    echo "[INFO] $APP_DIR exists — pulling latest..."
    git -C "$APP_DIR" fetch --all || true
    git -C "$APP_DIR" reset --hard origin/HEAD || true
  fi

  # Ensure php-redis is present BEFORE composer/artisan runs
  if ensure_php_redis; then
    echo "[INFO] php-redis check/install OK."
  else
    echo "[WARN] php-redis could not be fully installed/verified automatically. Composer may still fail. You can fix manually and re-run composer in $APP_DIR."
  fi

  # Install composer deps (as www-data)
  echo "[INFO] Installing PHP dependencies with Composer as www-data..."
  chown -R www-data:www-data "$APP_DIR"
  sudo -u www-data composer install --no-dev --optimize-autoloader -d "$APP_DIR" || {
    echo "[ERROR] Composer install failed. If the error mentions Redis, make sure php-redis is installed and php-fpm restarted."; exit 1;
  }

  # .env setup
  echo "[INFO] Preparing .env"
  if [[ -f "$APP_DIR/.env" ]]; then
    cp -n "$APP_DIR/.env" "$APP_DIR/.env.bak" || true
  fi
  if [[ -f "$APP_DIR/.env.example" ]]; then
    cp -f "$APP_DIR/.env.example" "$APP_DIR/.env"
  else
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

  sed -i "s|APP_URL=.*|APP_URL=https://$DOMAIN|" "$APP_DIR/.env" || true
  sed -i "s|DB_DATABASE=.*|DB_DATABASE=$DB_NAME|" "$APP_DIR/.env" || true
  sed -i "s|DB_USERNAME=.*|DB_USERNAME=$DB_USER|" "$APP_DIR/.env" || true
  sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=$DB_PASS|" "$APP_DIR/.env" || true

  # Create DB and user
  echo "[INFO] Creating database and user (if not exists)..."
  SQL="
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
"
  run_mysql "$SQL" "$DB_HOST" "$MYSQL_ROOT_PASS" || { echo "[ERROR] Database setup failed"; exit 1; }

  # Artisan commands
  echo "[INFO] Running artisan commands..."
  cd "$APP_DIR"
  sudo -u www-data php artisan key:generate --force
  sudo -u www-data php artisan migrate --force
  sudo -u www-data php artisan config:cache || true
  sudo -u www-data php artisan route:cache || true
  sudo -u www-data php artisan storage:link || true

  # Nginx config
  echo "[INFO] Setting up Nginx site..."
  PHP_FPM_SOCK=""
  for s in /run/php/php*-fpm.sock /var/run/php/php*-fpm.sock; do
    for f in $s; do
      if [[ -S "$f" ]]; then PHP_FPM_SOCK="$f"; break 2; fi
    done
  done
  PHP_FPM_SOCK=${PHP_FPM_SOCK:-/run/php/php7.4-fpm.sock}

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
  if [[ -f /etc/nginx/sites-enabled/default ]]; then rm -f /etc/nginx/sites-enabled/default; fi
  nginx -t
  systemctl reload nginx

  # Cron
  echo "[INFO] Installing cron job for schedule..."
  cat > "$CRON_FILE" <<EOL
* * * * * www-data /usr/bin/php $APP_DIR/artisan schedule:run >> /dev/null 2>&1
EOL
  chmod 644 "$CRON_FILE"

  # Systemd worker service
  echo "[INFO] Creating systemd service for queue worker..."
  cat > "$SYSTEMD_SERVICE" <<EOL
[Unit]
Description=Ctrlpanel Queue Worker
After=network.target

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php $APP_DIR/artisan queue:work --sleep=3 --tries=3
RestartSec=5

[Install]
WantedBy=multi-user.target
EOL

  systemctl daemon-reload
  systemctl enable --now ctrlpanel.service || true

  # Certbot
  if [[ "$DOMAIN" == "localhost" || "$DOMAIN" == "panel.localhost" || "$DOMAIN" =~ ^127\.0\.0\.1$ ]]; then
    echo "[INFO] Local domain detected; skipping Let's Encrypt."
  else
    if [[ -n "$SSL_EMAIL" ]]; then
      echo "[INFO] Attempting to obtain SSL certificate..."
      if certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$SSL_EMAIL" --redirect; then
        echo "[INFO] SSL issued."
      else
        echo "[WARN] Certbot failed. You can run certbot manually later."
      fi
    else
      echo "[INFO] No SSL email provided; skipping certbot."
    fi
  fi

  echo
  echo "Installation finished. Access: https://$DOMAIN"
  echo "DB: $DB_NAME | User: $DB_USER | Pass: $DB_PASS"
  echo "Powered By Saturo Tech"
}

uninstall() {
  echo "[INFO] Uninstall flow - will only remove Ctrlpanel artifacts (app dir, nginx site, cron, systemd service, DB, cert)."
  echo "This will NOT purge global packages (nginx/php/mysql/etc.) and will NOT touch other apps like Pterodactyl."
  read -r -p "Proceed with uninstall? [y/N] " ans; ans=${ans:-N}
  if [[ ! "$ans" =~ ^([Yy])$ ]]; then
    echo "Uninstall aborted."
    exit 0
  fi

  # Try to find domain and DB info from existing app .env
  if [[ -f "$APP_DIR/.env" ]]; then
    ENV_DOMAIN=$(grep -E '^APP_URL=' "$APP_DIR/.env" 2>/dev/null | sed -E 's/APP_URL=https?:\/\/(.*)/\1/' || true)
    ENV_DB_NAME=$(grep -E '^DB_DATABASE=' "$APP_DIR/.env" 2>/dev/null | cut -d'=' -f2 || true)
    ENV_DB_USER=$(grep -E '^DB_USERNAME=' "$APP_DIR/.env" 2>/dev/null | cut -d'=' -f2 || true)
    ENV_DB_HOST=$(grep -E '^DB_HOST=' "$APP_DIR/.env" 2>/dev/null | cut -d'=' -f2 || true)
  fi

  prompt DOMAIN "Domain to remove (used for nginx/site and cert)" "${ENV_DOMAIN:-panel.localhost}"
  prompt DB_NAME "Database name to drop" "${ENV_DB_NAME:-ctrlpanel}"
  prompt DB_USER "Database user to drop" "${ENV_DB_USER:-ctrluser}"
  prompt DB_HOST "Database host" "${ENV_DB_HOST:-localhost}"
  prompt_hidden MYSQL_ROOT_PASS "Enter MySQL/MariaDB root password (leave blank to use socket auth)" ""

  # Stop and disable systemd service if present
  if systemctl list-units --full -all | grep -q '^ctrlpanel.service'; then
    echo "[INFO] Stopping and disabling ctrlpanel.service..."
    systemctl stop ctrlpanel.service 2>/dev/null || true
    systemctl disable ctrlpanel.service 2>/dev/null || true
  fi
  if [[ -f "$SYSTEMD_SERVICE" ]]; then
    rm -f "$SYSTEMD_SERVICE"
    systemctl daemon-reload
  fi

  # Remove cron job
  if [[ -f "$CRON_FILE" ]]; then
    rm -f "$CRON_FILE"
    echo "[INFO] Removed cron file $CRON_FILE"
  fi

  # Remove nginx site
  if [[ -f "$NGINX_CONF" ]]; then
    rm -f "$NGINX_CONF"
  fi
  if [[ -f /etc/nginx/sites-enabled/ctrlpanel ]]; then
    rm -f /etc/nginx/sites-enabled/ctrlpanel
  fi
  systemctl reload nginx || true

  # Remove cert (if exists)
  if command -v certbot >/dev/null 2>&1 && [[ -n "$DOMAIN" ]]; then
    echo "[INFO] Attempting to delete cert for $DOMAIN (if it exists)..."
    certbot delete --cert-name "$DOMAIN" --non-interactive 2>/dev/null || true
  fi

  # Drop DB and user
  echo "[INFO] Dropping database and user (if they exist)..."
  SQL_DROP="DROP DATABASE IF EXISTS \`$DB_NAME\`; DROP USER IF EXISTS '$DB_USER'@'localhost'; FLUSH PRIVILEGES;"
  run_mysql "$SQL_DROP" "$DB_HOST" "$MYSQL_ROOT_PASS" || echo "[WARN] Could not drop DB or user - check credentials."

  # Remove application directory (only the ctrlpanel directory)
  if [[ -d "$APP_DIR" ]]; then
    rm -rf "$APP_DIR"
    echo "[INFO] Removed application directory $APP_DIR"
  fi

  echo
  echo "Uninstall complete. Only Ctrlpanel-specific files were removed."
  echo "Global packages (nginx/php/mysql/redis) were NOT removed to avoid affecting other panels (e.g., Pterodactyl)."
  echo "Powered By Saturo Tech"
}

# Main menu
echo
echo "Select action:"
echo "  1) Install Ctrlpanel"
echo "  2) Uninstall Ctrlpanel (only Ctrlpanel artifacts will be removed)"
echo "  3) Exit"
read -r -p "Choose [1-3]: " choice
case "$choice" in
  1) install ;;
  2) uninstall ;;
  *) echo "Exiting."; exit 0 ;;
esac
