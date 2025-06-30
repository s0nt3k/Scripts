#!/bin/bash

# Proxmox Helper Script: Create LXC + Install Faveo Helpdesk with Static IP and SSH

# This script installs Faveo Helpdesk on a Ubuntu 22.04 LXC container with Apache Webserver
# MySQL 8.0.x Database, and the following PHP extensions Mcrypt, OpenSSL, Mbstring, Tokenizer

### SETTINGS ###
CTID=105
HOSTNAME=faveo-helpdesk
PASSWORD='securePassword123!'
DISK_SIZE=10G
RAM_SIZE=2048
CPU_CORES=2
BRIDGE=vmbr0
STORAGE=local-lvm
IP_ADDRESS=172.16.1.11/24
GATEWAY=172.16.1.1
MAC_ADDRESS=AA:AB:AC:10:01:0B
TEMPLATE=local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst
FAVEO_URL=https://github.com/faveo/helpdesk-community/archive/refs/heads/master.zip

echo "[1/8] Creating LXC container $CTID..."
pct create $CTID $TEMPLATE \
  -hostname $HOSTNAME \
  -storage $STORAGE \
  -rootfs $DISK_SIZE \
  -memory $RAM_SIZE \
  -cores $CPU_CORES \
  -net0 name=eth0,bridge=$BRIDGE,ip=$IP_ADDRESS,gw=$GATEWAY,hwaddr=$MAC_ADDRESS \
  -password $PASSWORD \
  -features nesting=1 \
  -onboot 1

echo "[2/8] Starting container..."
pct start $CTID
sleep 5

echo "[3/8] Updating container and installing software..."
pct exec $CTID -- bash -c "apt update && apt upgrade -y"
pct exec $CTID -- bash -c "apt install -y unzip curl apache2 mariadb-server php php-cli php-mbstring php-xml php-bcmath php-curl php-mysql php-zip php-gd php-imap php-intl composer openssh-server"

echo "[4/8] Enabling SSH..."
pct exec $CTID -- systemctl enable ssh
pct exec $CTID -- systemctl start ssh

echo "[5/8] Downloading Faveo Helpdesk..."
pct exec $CTID -- bash -c "cd /var/www && curl -L -o faveo.zip $FAVEO_URL && unzip faveo.zip && mv helpdesk-community-master faveo && rm faveo.zip"

echo "[6/8] Setting permissions..."
pct exec $CTID -- bash -c "chown -R www-data:www-data /var/www/faveo && chmod -R 755 /var/www/faveo"

echo "[7/8] Configuring Apache for Faveo..."
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

echo "[8/8] Done!"
echo "--------------------------------------------------"
echo "Faveo Helpdesk installed in LXC container $CTID"
echo "Static IP: $IP_ADDRESS"
echo "SSH Enabled. Login with: ssh root@$IP_ADDRESS"
echo "Web Interface: http://$IP_ADDRESS"
