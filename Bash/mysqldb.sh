#!/bin/bash
# Undo script for the accidental install of MariaDB + Apache + PHP + phpMyAdmin on Proxmox host
# Run as root on the Proxmox VE host
# Use at your own risk - backs up nothing!

set -e  # exit on error

echo "=== Step 1: Stop and disable services ==="
systemctl stop apache2 mariadb mysql || true
systemctl disable apache2 mariadb mysql || true

echo "=== Step 2: Purge all related packages ==="
apt purge -y --autoremove \
  mariadb-server mariadb-client mariadb-common mariadb* mysql* \
  apache2 apache2-utils apache2-bin apache2-data libapache2-mod-php* \
  php* phpmyadmin dbconfig-common dbconfig-mysql \
  libapache2-mod-auth-mysql* || true

apt autoremove -y --purge
apt autoclean

echo "=== Step 3: Remove leftover directories and files ==="
rm -rf /var/lib/mysql* \
       /var/log/mysql* /var/log/mariadb* /var/log/apache2* \
       /var/www/html/phpmyadmin* \
       /etc/mysql* /etc/mariadb* \
       /etc/php* \
       /etc/phpmyadmin* /usr/share/phpmyadmin* \
       /etc/apache2/conf-enabled/phpmyadmin* \
       /etc/apache2/conf-available/phpmyadmin* \
       /etc/apache2/sites-enabled/*default*  # only touches default if present

# More aggressive cleanup for stragglers (optional but thorough)
find /etc   -type d -name '*mysql*'    -o -name '*mariadb*'    -o -name '*phpmyadmin*'    -o -name '*apache2*' | xargs rm -rf 2>/dev/null || true
find /var    -type d -name '*mysql*'    -o -name '*phpmyadmin*' -o -name '*apache2*' | xargs rm -rf 2>/dev/null || true
find /usr/share -type d -name '*phpmyadmin*' | xargs rm -rf 2>/dev/null || true

echo "=== Step 4: Final cleanup ==="
apt update  # refresh package lists just in case
journalctl --vacuum-time=2weeks  # optional: shrink logs a bit

echo ""
echo "Undo complete."
echo "Check for leftovers:"
echo "  dpkg -l | grep -iE 'mysql|maria|apache|php|phpmyadmin'"
echo "  systemctl list-units --type=service | grep -iE 'mysql|maria|apache'"
echo ""
echo "Reboot recommended now:"
echo "  reboot"
