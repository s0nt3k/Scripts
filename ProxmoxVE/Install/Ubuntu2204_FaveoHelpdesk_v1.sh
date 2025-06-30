#!/bin/bash

# Function to generate 10-character secure password
gen_pass() {
  tr -dc 'A-Za-z2-9!@#$%^&*()-_=+[]{}|;:,.<>/?' </dev/urandom | \
  tr -d "10lO'\"" | head -c 10
}

# Prompt user for default or advanced install
read -rp "Would you like to use the default settings? (y = Default / n = Advanced): " USE_DEFAULT

if [[ "$USE_DEFAULT" =~ ^[Yy]$ ]]; then
  # Default configuration
  CTID=105
  HOSTNAME="faveo-helpdesk"
  MEMORY=4096
  SWAP=8192
  CPUS=2
  DISK_SIZE="40G"
  STORAGE="local-lvm"
  SSH_PORT=22
else
  # Advanced configuration
  read -rp "Enter Container ID (e.g. 105): " CTID
  read -rp "Enter Hostname (e.g. faveo-helpdesk): " HOSTNAME
  read -rp "Enter Memory (MB): " MEMORY
  read -rp "Enter Swap (MB): " SWAP
  read -rp "Enter CPU Cores: " CPUS
  read -rp "Enter Disk Size (e.g. 40G): " DISK_SIZE
  read -rp "Enter Storage Name (e.g. local-lvm): " STORAGE
  read -rp "Enter SSH Port (default 22): " SSH_PORT
  SSH_PORT=${SSH_PORT:-22}
fi

# Common settings
TEMPLATE="local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
NET_CONFIG="name=eth0,ip=dhcp,bridge=vmbr0"
ROOTFS="$STORAGE:$DISK_SIZE"
SSH_KEY_PATH="/usr/faveo_ssh_key"
CREDS_FILE="/usr/container.creds"

OS_PASSWORD=$(gen_pass)
MYSQL_PASSWORD=$(gen_pass)

# Generate SSH key
ssh-keygen -t rsa -b 2048 -f "$SSH_KEY_PATH" -N ""

# Create the container
pct create "$CTID" "$TEMPLATE" \
  --hostname "$HOSTNAME" \
  --memory "$MEMORY" \
  --swap "$SWAP" \
  --cpus "$CPUS" \
  --net0 "$NET_CONFIG" \
  --rootfs "$ROOTFS" \
  --unprivileged 1 \
  --features nesting=1 \
  --start 1 \
  --password "$OS_PASSWORD" \
  --ssh-public-keys "${SSH_KEY_PATH}.pub"

echo "Waiting for container to boot..."
sleep 10

# Install required packages
pct exec "$CTID" -- bash -c "
  apt update &&
  DEBIAN_FRONTEND=noninteractive apt install -y apache2 php8.2 php8.2-{cli,common,mysql,mbstring,xml,zip,curl,bcmath,tokenizer,openssl} mysql-server cron unzip git &&
  systemctl enable apache2 &&
  systemctl enable cron &&
  systemctl enable ssh
"

# Secure MySQL and create Faveo DB
DB_NAME="faveodb"
DB_USER="faveouser"

pct exec "$CTID" -- bash -c "
  mysql -e \"
    ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$MYSQL_PASSWORD';
    FLUSH PRIVILEGES;
    CREATE DATABASE $DB_NAME;
    CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$MYSQL_PASSWORD';
    GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
    FLUSH PRIVILEGES;
  \"
"

# Download Faveo Helpdesk
pct exec "$CTID" -- bash -c "
  cd /var/www/html &&
  rm index.html &&
  wget https://github.com/ladybirdweb/faveo-helpdesk/archive/refs/heads/master.zip &&
  unzip master.zip &&
  mv faveo-helpdesk-master/* . &&
  rm -rf faveo-helpdesk-master master.zip &&
  chown -R www-data:www-data /var/www/html
"

# Get container network details
IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
GATEWAY=$(pct exec "$CTID" -- ip route | grep default | awk '{print $3}')
SUBNET=$(pct exec "$CTID" -- ip -o -f inet addr show eth0 | awk '{print $4}')

# Get version info
APACHE_VER=$(pct exec "$CTID" -- apache2 -v | grep "Server version" | awk '{print $3}')
PHP_VER=$(pct exec "$CTID" -- php -v | head -n 1 | awk '{print $2}')
MYSQL_VER=$(pct exec "$CTID" -- mysql -V | awk '{print $5}' | sed 's/,//')
NOW=$(date)

# Save credentials to file
cat <<EOF > "$CREDS_FILE"
OS: Ubuntu 22.04
Apache Version: $APACHE_VER
PHP Version: $PHP_VER
PHP Extensions: mcrypt, openssl, mbstring, tokenizer
Root Username: root
Root Password: $OS_PASSWORD
SSH Key File: $(basename "$SSH_KEY_PATH")
MySQL Version: $MYSQL_VER
Database: $DB_NAME
DB Username: $DB_USER
DB Password: $MYSQL_PASSWORD
IPv4 Address: $IP
Subnet: $SUBNET
Gateway: $GATEWAY
Installation Date: $NOW
EOF

echo -e "\n✅ Faveo Helpdesk LXC setup complete."
echo "🔐 Credentials saved to $CREDS_FILE"
