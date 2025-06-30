#!/bin/bash

echo "=============================================="
echo "  Faveo Helpdesk Installer for Proxmox LXC"
echo "  - External MySQL/MariaDB Integration -"
echo "=============================================="

# Prompt user for credentials
read -s -p "Enter password for the LXC root user: " PASSWORD
echo ""
read -p "Enter external MySQL server IP or domain (default 172.16.1.8): " DB_HOST
DB_HOST=${DB_HOST:-172.16.1.8}
read -p "Enter external MySQL username (default root): " DB_USER
DB_USER=${DB_USER:-root}
read -s -p "Enter password for MySQL user '$DB_USER': " DB_PASS
echo ""

# Confirm values
echo "--------------------------------------------------"
echo "LXC root password set"
echo "External DB Host: $DB_HOST"
echo "External DB User: $DB_USER"
echo "--------------------------------------------------"

# Ask about default settings or advanced
read -p "Would you like to use the default LXC settings? (Y/n): " use_defaults

# Advanced settings prompt
advanced_install() {
  read -p "Container ID (default 105): " CTID
  CTID=${CTID:-105}
  read -p "Hostname (default faveo-helpdesk): " HOSTNAME
  HOSTNAME=${HOSTNAME:-faveo-helpdesk}
  read -p "Disk Size (default 10G): " DISK_SIZE
  DISK_SIZE=${DISK_SIZE:-10G}
  read -p "RAM in MB (default 2048): " RAM_SIZE
  RAM_SIZE=${RAM_SIZE:-2048}
  read -p "CPU Cores (default 2): " CPU_CORES
  CPU_CORES=${CPU_CORES:-2}
  read -p "Static IP Address (default 172.16.1.11/24): " IP_ADDRESS
  IP_ADDRESS=${IP_ADDRESS:-172.16.1.11/24}
  read -p "Gateway (default 172.16.1.1): " GATEWAY
  GATEWAY=${GATEWAY:-172.16.1.1}
  read -p "MAC Address (default AA:AB:AC:10:01:0B): " MAC_ADDRESS
  MAC_ADDRESS=${MAC_ADDRESS:-AA:AB:AC:10:01:0B}
}

# Set values
if [[ "$use_defaults" =~ ^(n|N) ]]; then
  advanced_install
else
  CTID=105
  HOSTNAME=faveo-helpdesk
  DISK_SIZE=10G
  RAM_SIZE=2048
  CPU_CORES=2
  IP_ADDRESS=172.16.1.11/24
  GATEWAY=172.16.1.1
  MAC_ADDRESS=AA:AB:AC:10:01:0B
fi

# Static values
BRIDGE=vmbr0
STORAGE=local-lvm
DB_NAME=faveo_db
TEMPLATE=local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst
FAVEO_URL=https://github.com/faveo/helpdesk-community/archive/refs/heads/master.zip

echo "[1/9] Creating LXC container $CTID..."
pct create $CTID $TEMPLATE \
  -hostname $HOSTNAME \
  -storage $STORAGE \
  -rootfs $DISK_SIZE \
  -memory $RAM_SIZE \
  -cores $CPU_CORES \
  -net0 name=eth0,bridge=$BRIDGE,ip=$IP_ADDRESS,gw=$GATEWAY,hwaddr=$MAC_ADDRESS \
  -password "$PASSWORD" \
  -features nesting=1 \
  -onboot 1

echo "[2/9] Starting container..."
pct start $CTID
sleep 5

echo "[3/9] Installing dependencies (excluding local MariaDB)..."
pct exec $CTID -- bash -c "apt update && apt upgrade -y"
pct exec $CTID -- bash -c "apt install -y unzip curl apache2 php php-cli php-mbstring php-xml php-bcmath php-curl php-mysql php-zip php-gd php-imap php-intl composer openssh-server"

echo "[4/9] Enabling SSH..."
pct exec $CTID -- systemctl enable ssh
pct exec $CTID -- systemctl start ssh

echo "[5/9] Downloading Faveo Helpdesk..."
pct exec $CTID -- bash -c "cd /var/www && curl -L -o faveo.zip $FAVEO_URL && unzip faveo.zip && mv helpdesk-community-master faveo && rm faveo.zip"

echo "[6/9] Setting permissions..."
pct exec $CTID -- bash -c "chown -R www-data:www-data /var/www/faveo && chmod -R 755 /var/www/faveo"

echo "[7/9] Creating .env file for external MySQL..."
pct exec $CTID -- bash -c "cp /var/www/faveo/.env.example /var/www/faveo/.env"

# Use heredoc to inject the password into sed commands inside the container
pct exec $CTID -- bash -c "
  sed -i \
    -e 's/DB_HOST=.*/DB_HOST=$DB_HOST/' \
    -e 's/DB_DATABASE=.*/DB_DATABASE=$DB_NAME/' \
    -e 's/DB_USERNAME=.*/DB_USERNAME=$DB_USER/' \
    -e \"s/DB_PASSWORD=.*/DB_PASSWORD=$DB_PASS/\" \
    /var/www/faveo/.env
"

echo "[8/9] Configuring Apache for Faveo..."
pct exec $CTID -- bash -c "cat > /etc/apache2/sites-available/faveo.conf <<EOF
<VirtualHost *:80>
    ServerAdmin admin@localhost
    DocumentRoot /var/www/faveo/public
    <Directory /var/www/faveo/public>
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/faveo_error.log
    CustomLog \${APACHE_LOG_DIR}/faveo_access.log combined
</VirtualHost>
EOF"

pct exec $CTID -- bash -c "a2ensite faveo && a2enmod rewrite && systemctl reload apache2"

echo "[9/9] Done!"
echo "--------------------------------------------------"
echo "Faveo Helpdesk installed in LXC container $CTID"
echo "Static IP: $IP_ADDRESS"
echo "External DB: mysql://$DB_USER@$DB_HOST/$DB_NAME"
echo "SSH Access: ssh root@$IP_ADDRESS"
echo "Web Interface: http://$IP_ADDRESS"
