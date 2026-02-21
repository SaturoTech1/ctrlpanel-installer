#!/bin/bash

# Script for automatic installation of Ctrlpanel on Ubuntu 20.04
# WARNING: Run this script as a user with sudo privileges or as root.
# The script will install all necessary components and configure the control panel.

# --- Banner ---
echo -e "\e[1;36m"
echo "  ____             _ __  __          "
echo " |  _ \\           | |  \\/  |         "
echo " | |_) | __ _  ___| | \\  / | ___ ___ "
echo " |  _ < / _\` |/ _ \\ | |\\/| |/ _ \\ __|"
echo " | |_) | (_| |  __/ | |  | |  __/ |  "
echo " |____/ \\__,_|\\___|_|_|  |_|\\___|_|  "
echo "                                     "
echo "          by Saturo Tech            "
echo -e "\e[0m"

# --- Functions ---
# Function to print informational messages
function print_info {
    echo -e "\n\e[34m[INFO]\e[0m $1"
}

# Function to clean up the installation
function cleanup_installation {
    print_info "Stopping services..."
    sudo systemctl stop ctrlpanel.service 2>/dev/null
    sudo systemctl disable ctrlpanel.service 2>/dev/null
    sudo rm -f /etc/systemd/system/ctrlpanel.service 2>/dev/null
    sudo systemctl daemon-reload 2>/dev/null
    sudo systemctl stop nginx 2>/dev/null
    sudo systemctl stop mariadb 2>/dev/null
    sudo systemctl stop mysql 2>/dev/null # Added for MySQL
    sudo systemctl stop redis-server 2>/dev/null

    print_info "Removing cron job..."
    # Check if crontab exists before attempting to remove the job
    if command -v crontab &> /dev/null; then
        (sudo crontab -l 2>/dev/null | grep -v "/var/www/ctrlpanel/artisan schedule:run") | sudo crontab - 2>/dev/null
    fi

    print_info "Removing Nginx configs and SSL certificates..."
    sudo rm -f /etc/nginx/sites-enabled/ctrlpanel.conf 2>/dev/null
    sudo rm -f /etc/nginx/sites-available/ctrlpanel.conf 2>/dev/null
    # Remove SSL certificates and related Certbot configuration
    sudo certbot delete --non-interactive --cert-name "$DOMAIN" 2>/dev/null

    print_info "Removing database and user..."
    # Ensure the database service is started for cleanup
    if [[ "$DB_TYPE" == "mariadb" ]]; then
        sudo systemctl start mariadb 2>/dev/null
    elif [[ "$DB_TYPE" == "mysql" ]]; then
        sudo systemctl start mysql 2>/dev/null
    fi

    # Use sudo mysql -u root with password for cleanup
    if sudo mysql -u root -p"$DB_PASSWORD" -e "DROP DATABASE IF EXISTS $DB_NAME;" 2>/dev/null; then
        print_info "Database '$DB_NAME' dropped."
    fi
    # Remove the user only if it was created on the specified host
    if sudo mysql -u root -p"$DB_PASSWORD" -e "DROP USER IF EXISTS '$DB_USER'@'$DB_HOST';" 2>/dev/null; then
        print_info "Database user '$DB_USER'@'$DB_HOST' removed."
    fi

    if [[ "$DB_TYPE" == "mariadb" ]]; then
        sudo systemctl stop mariadb 2>/dev/null
    elif [[ "$DB_TYPE" == "mysql" ]]; then
        sudo systemctl stop mysql 2>/dev/null
    fi

    print_info "Removing application directory..."
    sudo rm -rf /var/www/ctrlpanel 2>/dev/null

    print_info "Removing installed packages..."
    # List of packages that might have been installed by the script
    PACKAGES_TO_REMOVE="php8.3 php8.3-common php8.3-cli php8.3-gd php8.3-mysql php8.3-mbstring php8.3-bcmath php8.3-xml php8.3-fpm php8.3-curl php8.3-zip php8.3-intl php8.3-redis nginx git redis-server certbot python3-certbot-nginx ufw composer cron"
    if [[ "$DB_TYPE" == "mariadb" ]]; then
        PACKAGES_TO_REMOVE+=" mariadb-server"
    elif [[ "$DB_TYPE" == "mysql" ]]; then
        PACKAGES_TO_REMOVE+=" mysql-server mysql-client mysql-common"
        # Remove MySQL APT repository
        sudo rm -f /etc/apt/sources.list.d/mysql.list 2>/dev/null
        sudo rm -f /etc/apt/trusted.gpg.d/mysql.gpg 2>/dev/null
    fi

    for pkg in $PACKAGES_TO_REMOVE; do
        if dpkg -s "$pkg" &>/dev/null; then # Check if package is installed
            print_info "Removing package: $pkg"
            sudo apt-get -y purge "$pkg" 2>/dev/null
        fi
    done
    sudo apt-get -y autoremove 2>/dev/null
    sudo apt-get -y clean 2>/dev/null

    print_info "Removing added PPAs and repositories (if applicable, be careful)..."
    # This part is commented out because it can be too aggressive; uncomment if really necessary.
    # sudo add-apt-repository --remove ppa:ondrej/php -y 2>/dev/null
    # sudo rm -f /etc/apt/sources.list.d/redis.list 2>/dev/null
    # sudo rm -f /etc/apt/sources.list.d/mariadb.list 2>/dev/null # For MariaDB
    # sudo apt-get update 2>/dev/null
}

# Function to print error and exit
function print_error {
    echo -e "\n\e[31m[ERROR]\e[0m $1" >&2 # Output to stderr
    echo -e "\n\e[31mInstallation cannot continue due to an error.\e[0m" >&2
    echo -e "Do you want to clean up everything that the script installed so far? (Press Y to confirm, any other key to exit)"
    read -n 1 -s -r KEY # Read a single character silently
    echo # Newline after input
    if [[ "$KEY" == "Y" || "$KEY" == "y" ]]; then
        print_info "Starting cleanup..."
        cleanup_installation
        print_info "Cleanup finished. Exiting."
    else
        print_info "Cleanup cancelled. Exiting."
    fi
    exit 1
}

# Function to ask user for input
function get_user_input {
    local prompt_message=$1
    local default_value=$2
    local input_var=$3

    read -p "$(echo -e "\n\e[33m[QUESTION]\e[0m $prompt_message [Default: $default_value]: ")" user_input
    if [[ -z "$user_input" ]]; then
        eval "$input_var=\"$default_value\""
    else
        eval "$input_var=\"$user_input\""
    fi
}

# Function to check and configure UFW firewall
function check_and_configure_firewall {
    print_info "Checking and configuring UFW firewall..."
    if command -v ufw &> /dev/null; then
        UFW_STATUS=$(sudo ufw status | grep "Status: active")
        if [[ "$UFW_STATUS" == *"Status: active"* ]]; then
            print_info "UFW is active. Checking rules for ports 80, 443 and OpenSSH..."
            
            # Check and allow port 80
            PORT_80_ALLOWED=$(sudo ufw status | grep -E "80\s+(ALLOW|ALLOW IN)")
            if [[ -z "$PORT_80_ALLOWED" ]]; then
                print_info "Port 80 is not allowed. Adding rule..."
                sudo ufw allow 80/tcp
                if [ $? -ne 0 ]; then print_error "Failed to allow port 80 in UFW."; fi
            else
                print_info "Port 80 is already allowed."
            fi

            # Check and allow port 443
            PORT_443_ALLOWED=$(sudo ufw status | grep -E "443\s+(ALLOW|ALLOW IN)")
            if [[ -z "$PORT_443_ALLOWED" ]]; then
                print_info "Port 443 is not allowed. Adding rule..."
                sudo ufw allow 443/tcp
                if [ $? -ne 0 ]; then print_error "Failed to allow port 443 in UFW."; fi
            else
                print_info "Port 443 is already allowed."
            fi
            
            # Check and allow OpenSSH (so you don't lock yourself out)
            SSH_ALLOWED=$(sudo ufw status | grep -E "OpenSSH\s+ALLOW")
            if [[ -z "$SSH_ALLOWED" ]]; then
                print_info "OpenSSH is not allowed. Adding rule..."
                sudo ufw allow OpenSSH
                if [ $? -ne 0 ]; then print_error "Failed to allow OpenSSH in UFW."; fi
            else
                print_info "OpenSSH is already allowed."
            fi

            print_info "Reloading UFW to apply changes..."
            sudo ufw reload
            print_info "UFW configured."
        else
            print_info "UFW is not active. Continuing without configuring UFW."
        fi
    else
        print_info "UFW is not installed. Continuing without configuring UFW."
    fi
}


# --- User inputs ---
print_info "Configuring installation parameters:"

get_user_input "Enter the website address (domain or IP)" "my.yoogo.su" DOMAIN
get_user_input "Enter email for SSL certificate (e.g., admin@example.com)" "admin@example.com" ADMIN_EMAIL

DB_TYPE_CHOICE="mysql"
while true; do
    read -p "$(echo -e "\n\e[33m[QUESTION]\e[0m Choose database type (mariadb/mysql) [Default: mysql]: ")" DB_TYPE_INPUT
    DB_TYPE_INPUT=${DB_TYPE_INPUT:-$DB_TYPE_CHOICE} # Use default if input is empty
    if [[ "$DB_TYPE_INPUT" == "mariadb" || "$DB_TYPE_INPUT" == "mysql" ]]; then
        DB_TYPE="$DB_TYPE_INPUT"
        break
    else
        echo -e "\e[31mInvalid choice. Please enter 'mariadb' or 'mysql'.\e[0m"
    fi
done

get_user_input "Enter database host address" "127.0.0.1" DB_HOST
get_user_input "Enter database port" "3306" DB_PORT
get_user_input "Enter database name" "ctrlpanel" DB_NAME
get_user_input "Enter database username" "ctrlpaneluser" DB_USER

DEFAULT_DB_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)
get_user_input "Enter database user password (or press Enter to generate a random one)" "$DEFAULT_DB_PASSWORD" DB_PASSWORD


# --- Start installation ---
print_info "Starting Ctrlpanel installation for domain $DOMAIN"
sleep 3

# --- 1. Install dependencies ---
print_info "Updating system and installing base dependencies..."
sudo apt-get update || print_error "Failed to update package list."
sudo apt-get -y install software-properties-common curl apt-transport-https ca-certificates gnupg wget || print_error "Failed to install base dependencies."

# Add PHP repository
print_info "Adding PPA for PHP 8.3..."
sudo LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php || print_error "Failed to add PHP PPA."

# Add Redis repository
print_info "Adding Redis repository..."
curl -fsSL https://packages.redis.io/gpg | sudo gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg || print_error "Failed to add Redis GPG key."
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/redis.list || print_error "Failed to add Redis repository."

# Add database repository
if [[ "$DB_TYPE" == "mariadb" ]]; then
    print_info "Adding MariaDB repository..."
    curl -LsS https://r.mariadb.com/downloads/mariadb_repo_setup | sudo bash || print_error "Failed to add MariaDB repository."
elif [[ "$DB_TYPE" == "mysql" ]]; then
    print_info "Adding MySQL 8 repository..."
    # Download and install MySQL APT config package
    wget https://dev.mysql.com/get/mysql-apt-config_0.8.29-1_all.deb -O /tmp/mysql-apt-config.deb || print_error "Failed to download MySQL APT config package."
    
    # Preconfigure debconf for MySQL
    echo "mysql-apt-config mysql-apt-config/select-server select mysql-8.0" | sudo debconf-set-selections
    echo "mysql-community-server mysql-community-server/root-pass password $DB_PASSWORD" | sudo debconf-set-selections
    echo "mysql-community-server mysql-community-server/re-root-pass password $DB_PASSWORD" | sudo debconf-set-selections
    echo "mysql-community-server mysql-community-server/default-auth-plugin select mysql_native_password" | sudo debconf-set-selections # Choose more compatible auth plugin

    sudo DEBIAN_FRONTEND=noninteractive dpkg -i /tmp/mysql-apt-config.deb || print_error "Failed to install MySQL APT config package."
    rm /tmp/mysql-apt-config.deb
fi

# Update package list after adding repositories
print_info "Updating package list and cleaning apt cache..."
sudo apt-get clean && sudo apt-get update || print_error "Failed to update package list or clean apt cache."

# Install main packages (ufw and cron added)
print_info "Installing PHP, $DB_TYPE, Nginx, Redis, UFW, Cron and other utilities..."
DB_PACKAGE=""
if [[ "$DB_TYPE" == "mariadb" ]]; then
    DB_PACKAGE="mariadb-server"
elif [[ "$DB_TYPE" == "mysql" ]]; then
    DB_PACKAGE="mysql-server"
fi
sudo apt-get -y install php8.3 php8.3-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip,intl,redis} "$DB_PACKAGE" nginx git redis-server certbot python3-certbot-nginx ufw cron || print_error "An error occurred while installing PHP 8.3 or other packages. Check the PPA and package availability."

# Call firewall configuration function
check_and_configure_firewall

# Enable Redis
print_info "Enabling and starting Redis service..."
sudo systemctl enable --now redis-server || print_error "Failed to enable and start Redis service."

# --- 2. Install Composer ---
print_info "Installing Composer..."
if ! command -v composer &> /dev/null
then
    curl -sS https://getcomposer.org/installer | sudo php -- --install-dir=/usr/local/bin --filename=composer || print_error "Failed to install Composer."
else
    print_info "Composer is already installed."
fi


# --- 3. Download panel files ---
print_info "Creating directory and downloading Ctrlpanel files..."
sudo mkdir -p /var/www/ctrlpanel || print_error "Failed to create /var/www/ctrlpanel directory."
cd /var/www/ctrlpanel || print_error "Failed to change to /var/www/ctrlpanel directory."
sudo git clone https://github.com/Ctrlpanel-gg/panel.git . || print_error "Failed to download files from GitHub."


# --- 4. Database setup ---
print_info "Setting up $DB_TYPE database..."
# Create user and database
# Use sudo mysql -u root with the password set via debconf
sudo mysql -u root -p"$DB_PASSWORD" <<MYSQL_SCRIPT
CREATE USER '$DB_USER'@'$DB_HOST' IDENTIFIED BY '$DB_PASSWORD';
CREATE DATABASE $DB_NAME;
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'$DB_HOST';
FLUSH PRIVILEGES;
MYSQL_SCRIPT
if [ $? -ne 0 ]; then print_error "Failed to create database or user. Check the root password for MySQL/MariaDB or authentication settings."; fi
print_info "Database '$DB_NAME' and user '$DB_USER'@'$DB_HOST' created successfully."


# --- 5. Composer dependencies and app setup ---
print_info "Installing Composer dependencies..."
cd /var/www/ctrlpanel || print_error "Failed to change to /var/www/ctrlpanel to install Composer dependencies."
sudo COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader || print_error "Error installing Composer dependencies."

print_info "Creating storage symlink..."
sudo php artisan storage:link || print_error "Failed to create storage symlink."


# --- 6. Nginx and SSL setup ---
print_info "Configuring Nginx and obtaining SSL certificate..."
# Remove default nginx config
sudo rm -f /etc/nginx/sites-enabled/default

# Create initial Nginx server block for the domain
print_info "Creating initial Nginx config for $DOMAIN..."
sudo tee /etc/nginx/sites-available/ctrlpanel.conf > /dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    root /var/www/ctrlpanel/public;
    index index.php;

    access_log /var/log/nginx/ctrlpanel.app-access.log;
    error_log  /var/log/nginx/ctrlpanel.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
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

# Enable the site
print_info "Enabling Nginx config..."
sudo ln -s -f /etc/nginx/sites-available/ctrlpanel.conf /etc/nginx/sites-enabled/ctrlpanel.conf

# Test and restart Nginx so Certbot can use the server block
print_info "Testing and restarting Nginx before requesting SSL..."
sudo nginx -t || print_error "Nginx configuration test failed after creating the initial file."
sudo systemctl restart nginx || print_error "Failed to restart Nginx after creating the initial file."


# Obtain SSL certificate with retries
MAX_RETRIES=3
RETRY_DELAY=10
CERT_SUCCESS=false

for i in $(seq 1 $MAX_RETRIES); do
    print_info "Attempt $i of $MAX_RETRIES: Obtaining SSL certificate for $DOMAIN..."
    # Certbot should find the existing server block and configure it
    if sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$ADMIN_EMAIL"; then
        CERT_SUCCESS=true
        print_info "SSL certificate obtained and installed successfully!"
        break
    else
        print_info "Failed to obtain or install SSL certificate. Retrying in $RETRY_DELAY seconds..."
        sleep $RETRY_DELAY
    fi
done

if [ "$CERT_SUCCESS" = false ]; then
    print_error "Failed to obtain or install SSL certificate after $MAX_RETRIES attempts. Make sure that:\n" \
                "  - The DNS A record for $DOMAIN points to this server's IP and has fully propagated.\n" \
                "  - There are no firewall blocks (for example, UFW configured correctly as attempted, or external firewalls).\n" \
                "  - You have not exceeded Let's Encrypt rate limits (wait 1-2 hours and try again).\n" \
                "  Please check Certbot logs: /var/log/letsencrypt/letsencrypt.log for more details."
fi

# --- 7. File permissions ---
print_info "Setting file permissions..."
sudo chown -R www-data:www-data /var/www/ctrlpanel/ || print_error "Failed to change owner of /var/www/ctrlpanel/."
sudo chmod -R 755 /var/www/ctrlpanel/storage/* /var/www/ctrlpanel/bootstrap/cache/ || print_error "Failed to set permissions for storage and bootstrap/cache directories."


# --- 8. Background jobs setup ---
print_info "Configuring queue worker and cron..."

# Configure cron
(sudo crontab -l 2>/dev/null; echo "* * * * * php /var/www/ctrlpanel/artisan schedule:run >> /dev/null 2>&1") | sudo crontab - || print_error "Failed to add cron job."
print_info "Cron job added."

# Create systemd service for the queue worker
print_info "Creating systemd service for the queue worker..."
sudo tee /etc/systemd/system/ctrlpanel.service > /dev/null <<EOF
[Unit]
Description=Ctrlpanel Queue Worker

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/ctrlpanel/artisan queue:work --sleep=3 --tries=3
StartLimitBurst=0

[Install]
WantedBy=multi-user.target
EOF
if [ $? -ne 0 ]; then print_error "Failed to create systemd service for the queue worker."; fi

# Enable and start the service
sudo systemctl enable --now ctrlpanel.service || print_error "Failed to enable and start the queue worker service."
print_info "Queue worker service enabled and started."


# --- Finish ---
print_info "\e[32mInstallation completed successfully!\e[0m"
echo -e "----------------------------------------------------"
echo -e "You can now open in a browser: \e[1mhttps://$DOMAIN\e[0m"
echo -e "You will need to finish the setup through the web interface."
echo -e ""
echo -e "Database connection details:"
echo -e "  DB Type:        \e[1m$DB_TYPE\e[0m"
echo -e "  Host:           \e[1m$DB_HOST\e[0m"
echo -e "  Port:           \e[1m$DB_PORT\e[0m"
echo -e "  Database:       \e[1m$DB_NAME\e[0m"
echo -e "  Username:       \e[1m$DB_USER\e[0m"
echo -e "  Password:       \e[1m$DB_PASSWORD\e[0m"
echo -e "----------------------------------------------------"