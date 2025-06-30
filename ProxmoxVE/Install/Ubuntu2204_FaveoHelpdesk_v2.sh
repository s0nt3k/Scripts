#!/bin/bash

# Secure password generator
gen_pass() {
  tr -dc 'A-Za-z2-9!@#$%^&*()-_=+[]{}|;:,.<>/?' </dev/urandom | \
  tr -d "10lO'\"" | head -c 10
}

# Prompt for external MySQL
read -rp "Use external MySQL database? (y/n): " USE_EXTERNAL_MYSQL

if [[ "$USE_EXTERNAL_MYSQL" =~ ^[Yy]$ ]]; then
  read -rp "Enter MySQL Server IP or Domain: " MYSQL_HOST
  read -rp "Enter MySQL Port (default 3306): " MYSQL_PORT
  MYSQL_PORT=${MYSQL_PORT:-3306}
  read -rp "Enter MySQL root username: " MYSQL_USER
  read -rsp "Enter MySQL root password: " MYSQL_PASSWORD && echo
else
  MYSQL_HOST="localhost"
  MYSQL_PORT="3306"
  MYSQL_USER="root"
  MYSQL_PASSWORD=$(gen_pass)
  LOCAL_MYSQL=true
fi

# Default Values
DEFAULT_CTID=105
DEFAULT_HOSTNAME="faveo-helpdesk"
DEFAULT_MEMORY=4096
DEFAULT_SWAP=8192
DEFAULT_CPUS=2
DEFAULT_DISK="40G"
DEFAULT_IPV4="dhcp"
DEFAULT_GATEWAY=""
DEFAULT_IPV6="disable"
DEFAULT_STORAGE="local-lvm"
DEFAULT_ROOT_PASS=$(gen_pass)

# Prompt user with settings form
echo -e "\n--- Container Configuration ---"
read -rp "CTID [$DEFAULT_CTID]: " CTID; CTID=${CTID:-$DEFAULT_CTID}
read -rp "Hostname [$DEFAULT_HOSTNAME]: " HOSTNAME; HOSTNAME=${HOSTNAME:-$DEFAULT_HOSTNAME}
read -rp "Memory (MB) [$DEFAULT_MEMORY]: " MEMORY; MEMORY=${MEMORY:-$DEFAULT_MEMORY}
read -rp "Swap (MB) [$DEFAULT_SWAP]: " SWAP; SWAP=${SWAP:-$DEFAULT_SWAP}
read -rp "CPU cores [$DEFAULT_CPUS]: " CPUS; CPUS=${CPUS:-$DEFAULT_CPUS}
read -rp "Disk size [$DEFAULT_DISK]: " DISK; DISK=${DISK:-$DEFAULT_DISK}
read -rp "IPv4 config (dhcp/static) [$DEFAULT_IPV4]: " IPV4; IPV4=${IPV4:-$DEFAULT_IPV4}
if [[ "$IPV4" == "static" ]]; then
  read -rp "Enter static IPv4 address with subnet (e.g. 192.168.1.50/24): " STATIC_IP
  read -rp "Enter Gateway IP address: " GATEWAY
else
  STATIC_IP=""
  GATEWAY=""
fi
read -rp "IPv6 config (disable/dhcp/static) [$DEFAULT_IPV6]: " IPV6; IPV6=${IPV6:-$DEFAULT_IPV6}

# SSH Key Option
echo -e "\nSSH Key Options:"
echo "1) Generate new SSH key"
echo "2) Use existing SSH public key file"
echo "3) Do not use SSH key"
read -rp "Choose SSH option (1/2/3): " SSH_OPTION

SSH_KEY_PATH=""
if [[ "$SSH_OPTION" == "1" ]]; then
  SSH_KEY_PATH="/usr/faveo_ssh_key"
  ssh-keygen -t rsa -b 2048 -f "$SSH_KEY_PATH" -N ""
  SSH_PUB_KEY=$(<"${SSH_KEY_PATH}.pub")
elif [[ "$SSH_OPTION" == "2" ]]; then
  read -rp "Enter path to existing public SSH key: " SSH_KEY_PATH
  SSH_PUB_KEY=$(<"$SSH_KEY_PATH")
else
  SSH_PUB_KEY=""
fi

# Create container
TEMPLATE="local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
ROOTFS="${DEFAULT_STORAGE}:${DISK}"
NET_CONFIG="name=eth0,bridge=vmbr0"
[[ "$IPV4" == "dhcp" ]] && NET_CONFIG+=",ip=dhcp"
[[ "$IPV4" == "static" ]] && NET_CONFIG+=",ip=${STATIC_IP},gw=${GATEWAY}"
[[ "$IPV6" == "disable" ]] && NET_CONFIG+=",ip6=off"

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
  --password "$DEFAULT_ROOT_PASS" \
  $( [[ -n "$SSH_PUB_KEY" ]] && echo "--ssh-public-keys - <<< \"$SSH_PUB_KEY\"" )

# Wait to boot
echo "Waiting for container startup..."
sleep 10

# Optional MySQL Install
if [[ "$LOCAL_MYSQL" == true ]]; then
  pct exec "$CTID" -- bash -c "
    apt update &&
    DEBIAN_FRONTEND=noninteractive apt install -y mysql-server &&
    mysql -e \"
      ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$MYSQL_PASSWORD';
      FLUSH PRIVILEGES;
    \"
  "
fi

# Install stack
pct exec "$CTID" -- bash -c "
  apt update &&
  DEBIAN_FRONTEND=noninteractive apt install -y apache2 php8.2 php8.2-{cli,common,mysql,mbstring,xml,zip,curl,bcmath,tokenizer,openssl} cron unzip git &&
  systemctl enable apache2 &&
  systemctl enable cron &&
  systemctl enable ssh
"

# Setup Faveo
DB_NAME="faveodb"
DB_USER="faveouser"

if [[ "$LOCAL_MYSQL" == true ]]; then
  pct exec "$CTID" -- bash -c "
    mysql -u root -p'$MYSQL_PASSWORD' -e \"
      CREATE DATABASE $DB_NAME;
      CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$MYSQL_PASSWORD';
      GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
      FLUSH PRIVILEGES;
    \"
  "
fi

pct exec "$CTID" -- bash -c "
  cd /var/www/html &&
  rm index.html &&
  wget https://github.com/ladybirdweb/faveo-helpdesk/archive/refs/heads/master.zip &&
  unzip master.zip &&
  mv faveo-helpdesk-master/* . &&
  rm -rf faveo-helpdesk-master master.zip &&
  chown -R www-data:www-data /var/www/html
"

# Collect and write credentials
IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
SUBNET=$(pct exec "$CTID" -- ip -o -f inet addr show eth0 | awk '{print $4}')
GATEWAY=${GATEWAY:-$(pct exec "$CTID" -- ip route | grep default | awk '{print $3}')}
APACHE_VER=$(pct exec "$CTID" -- apache2 -v | grep "Server version" | awk '{print $3}')
PHP_VER=$(pct exec "$CTID" -- php -v | head -n 1 | awk '{print $2}')
MYSQL_VER=$(pct exec "$CTID" -- mysql -V | awk '{print $5}' | sed 's/,//')
NOW=$(date)
CREDS_FILE="/usr/container.creds"

cat <<EOF > "$CREDS_FILE"
OS: Ubuntu 22.04
Apache Version: $APACHE_VER
PHP Version: $PHP_VER
PHP Extensions: mcrypt, openssl, mbstring, tokenizer
Root Username: root
Root Password: $DEFAULT_ROOT_PASS
SSH Key: ${SSH_KEY_PATH:-None}
MySQL:
  Location: $MYSQL_HOST
  Port: $MYSQL_PORT
  Version: $MYSQL_VER
  DB: $DB_NAME
  DB User: $DB_USER
  DB Password: $MYSQL_PASSWORD
Network:
  IPv4 Address: $IP
  Subnet: $SUBNET
  Gateway: $GATEWAY
  IPv6: $IPV6
Installation Date: $NOW
EOF

echo -e "\n✅ Installation complete."
echo "📄 Credentials saved to: $CREDS_FILE"
