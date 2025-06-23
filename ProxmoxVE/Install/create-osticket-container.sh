#!/bin/bash

# Variables
CTID=150                         # Change if needed
HOSTNAME="osticket"
IP="172.16.0.50/24"
GATEWAY="172.16.0.1"
PASSWORD="P@ssword123"
STORAGE="local-lvm"             # Change to your desired storage location
MEMORY="4096"
SWAP="0"
DISK="16"
OSTEMPLATE="debian-12-standard_12.0-1_amd64.tar.zst"

# Download latest Debian 12 template if not found
if ! pveam list local | grep -q $OSTEMPLATE; then
  echo "Downloading Debian 12 LXC template..."
  pveam update
  pveam download $STORAGE $OSTEMPLATE
fi

# Create the container
echo "Creating LXC container..."
pct create $CTID $STORAGE:vztmpl/$OSTEMPLATE \
  --hostname $HOSTNAME \
  --cores 2 \
  --memory $MEMORY \
  --swap $SWAP \
  --rootfs ${STORAGE}:${DISK} \
  --net0 name=eth0,bridge=vmbr0,ip=$IP,gw=$GATEWAY \
  --password $PASSWORD \
  --unprivileged 0 \
  --features nesting=1 \
  --ostype debian \
  --onboot 1 \
  --start 1

# Disable IPv6 and Enable SSH
echo "Post-configuring LXC container..."
pct exec $CTID -- bash -c "echo 'net.ipv6.conf.all.disable_ipv6 = 1' >> /etc/sysctl.conf"
pct exec $CTID -- bash -c "echo 'net.ipv6.conf.default.disable_ipv6 = 1' >> /etc/sysctl.conf"
pct exec $CTID -- sysctl -p

# Install osTicket and dependencies
pct exec $CTID -- bash -c "apt update && apt install -y apache2 mariadb-server php php-mysqli php-imap php-apcu php-intl php-common php-curl php-mbstring php-gd php-xml unzip curl gnupg2 lsb-release ca-certificates apt-transport-https wget nano sudo openssh-server ufw"

# Enable Apache & MariaDB
pct exec $CTID -- systemctl enable apache2
pct exec $CTID -- systemctl enable mariadb

# Download and extract osTicket
pct exec $CTID -- bash -c "wget -O /tmp/osticket.zip https://github.com/osTicket/osTicket/releases/download/v1.18.1/osTicket-v1.18.1.zip"
pct exec $CTID -- bash -c "unzip /tmp/osticket.zip -d /var/www/html/"
pct exec $CTID -- bash -c "cp -R /var/www/html/upload /var/www/html/osticket"
pct exec $CTID -- bash -c "cp /var/www/html/osticket/include/ost-sampleconfig.php /var/www/html/osticket/include/ost-config.php"

# Set permissions
pct exec $CTID -- bash -c "chown -R www-data:www-data /var/www/html/osticket"
pct exec $CTID -- bash -c "chmod 0666 /var/www/html/osticket/include/ost-config.php"

# Configure Apache
pct exec $CTID -- bash -c 'cat <<EOF > /etc/apache2/sites-available/osticket.conf
<VirtualHost *:80>
    DocumentRoot /var/www/html/osticket
    <Directory /var/www/html/osticket>
        Require all granted
        AllowOverride All
    </Directory>
</VirtualHost>
EOF'

pct exec $CTID -- bash -c "a2ensite osticket.conf && a2dissite 000-default.conf && a2enmod rewrite && systemctl restart apache2"

# Secure MariaDB and create database
pct exec $CTID -- bash -c "mysql -e \"
CREATE DATABASE osticket;
CREATE USER 'ostuser'@'localhost' IDENTIFIED BY 'osTicketDBpass!';
GRANT ALL PRIVILEGES ON osticket.* TO 'ostuser'@'localhost';
FLUSH PRIVILEGES;\""

echo "osTicket LXC container setup complete."
echo "Visit http://$IP to complete the web installation."
