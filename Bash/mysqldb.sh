#!/bin/bash

# Proxmox Helper Script: Install MySQL and phpMyAdmin on Debian 13 LXC
# This script must be run as root inside a Debian 13 LXC container on Proxmox.
# It installs MySQL Server, Apache2, PHP, and phpMyAdmin.
# Assumptions: The container has internet access and is freshly installed.
# Warning: This sets a default MySQL root password 'rootpassword' - CHANGE IT IN PRODUCTION!

set -e  # Exit on error

# Update and upgrade packages
echo "Updating package lists..."
apt update -y
apt upgrade -y

# Install MySQL Server
echo "Installing MySQL Server..."
apt install -y mariadb-server mariadb-client  # Using MariaDB as it's the default in Debian

# Secure MySQL installation (non-interactive)
echo "Securing MySQL installation..."
mysql_secure_installation <<EOF
n
y
y
y
y
EOF

# Set MySQL root password (change this in production!)
MYSQL_ROOT_PASSWORD="rootpassword"
echo "Setting MySQL root password..."
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD'; FLUSH PRIVILEGES;"

# Install Apache2 web server
echo "Installing Apache2..."
apt install -y apache2

# Install PHP and required extensions
echo "Installing PHP and extensions..."
apt install -y php libapache2-mod-php php-mysql php-mbstring php-zip php-gd php-json php-curl

# Enable Apache modules and restart
a2enmod php8.2  # Adjust if PHP version differs (Debian 13 likely PHP 8.2+)
systemctl restart apache2

# Install phpMyAdmin
echo "Installing phpMyAdmin..."
apt install -y phpmyadmin

# Configure phpMyAdmin for Apache
echo "Configuring phpMyAdmin..."
ln -s /usr/share/phpmyadmin /var/www/html/phpmyadmin

# Set permissions
chown -R www-data:www-data /var/www/html/phpmyadmin
chmod -R 755 /var/www/html/phpmyadmin

# Create phpMyAdmin config if needed (basic setup)
if [ ! -f /etc/phpmyadmin/config.inc.php ]; then
    cp /etc/phpmyadmin/config.inc.php.sample /etc/phpmyadmin/config.inc.php
    # Generate blowfish secret
    BLOWFISH_SECRET=$(openssl rand -base64 32)
    sed -i "s|\$cfg\['blowfish_secret'\] = ''|\$cfg\['blowfish_secret'\] = '$BLOWFISH_SECRET'|g" /etc/phpmyadmin/config.inc.php
fi

# Restart services
systemctl restart apache2
systemctl restart mariadb

echo "Installation complete!"
echo "Access phpMyAdmin at http://<container-ip>/phpmyadmin"
echo "MySQL root user: root"
echo "MySQL root password: $MYSQL_ROOT_PASSWORD (CHANGE THIS!)"
echo "For security, run 'mysql_secure_installation' manually if needed."
