#!/bin/bash

# ==========================================
# System Deployment & Management Menu
# ==========================================

set -e

# Root check
if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo"
    exit 1
fi

# ------------------------------------------
# Install whiptail if missing
# ------------------------------------------

if ! command -v whiptail >/dev/null 2>&1; then
    apt update
    apt install -y whiptail
fi

# ------------------------------------------
# Deploy Applications & Services Functions
# ------------------------------------------

install_gui_desktop() {
    whiptail --title "Desktop Install" \
    --msgbox "Installing GUI Desktop Environment with XRDP" 10 50

    apt update
    apt upgrade -y
    apt install -y tasksel

    whiptail --title "Tasksel" \
    --msgbox "Select:\n\n✔ Debian Desktop\n✔ KDE Plasma" 12 50

    tasksel

    apt install -y xrdp
    systemctl enable xrdp
    systemctl restart xrdp

    echo "startplasma-x11" > /etc/skel/.xsession
    chmod +x /etc/skel/.xsession

    whiptail --title "Completed" \
    --msgbox "GUI Desktop + XRDP Installed Successfully" 10 50
}

install_docker_ce() {
    whiptail --title "Docker Install" \
    --msgbox "Installing Docker CE + Docker Compose" 10 50

    apt update
    apt install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release

    mkdir -p /etc/apt/keyrings

    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

    apt update

    apt install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    systemctl enable docker
    systemctl start docker

    if [ -n "$SUDO_USER" ]; then
        usermod -aG docker "$SUDO_USER"
    fi

    whiptail --title "Completed" \
    --msgbox "Docker CE + Compose Installed\nLog out to activate permissions" 12 50
}

install_freepbx() {
    whiptail --title "FreePBX Install" \
    --msgbox "Installing FreePBX Phone System\n\nThis will take several minutes..." 12 50

    apt update
    apt install -y asterisk freepbx

    systemctl enable asterisk
    systemctl start asterisk

    whiptail --title "Completed" \
    --msgbox "FreePBX Phone System Installed\n\nAccess via: http://$(hostname -I | awk '{print $1}')" 12 60
}

install_nextcloud() {
    whiptail --title "NextCloud Install" \
    --msgbox "Installing NextCloud Server\n\nThis will install Apache, PHP, and NextCloud..." 12 50

    apt update
    apt install -y apache2 mariadb-server php php-{cli,gd,curl,mbstring,mysql,xml,zip,intl,bcmath,gmp,imagick}

    systemctl enable apache2
    systemctl enable mariadb
    systemctl start apache2
    systemctl start mariadb

    cd /tmp
    wget https://download.nextcloud.com/server/releases/latest.tar.bz2
    tar -xjf latest.tar.bz2 -C /var/www/html/
    chown -R www-data:www-data /var/www/html/nextcloud

    whiptail --title "Completed" \
    --msgbox "NextCloud Server Installed\n\nAccess via: http://$(hostname -I | awk '{print $1}')/nextcloud" 12 70
}

# ------------------------------------------
# Deploy Docker Compose Containers Functions
# ------------------------------------------

install_pihole() {
    whiptail --title "Pi-Hole Install" \
    --msgbox "Installing Unbound Pi-Hole DNS Ad-Blocker" 10 50

    local BASE_DIR="$HOME/opt/pihole"
    mkdir -p "$BASE_DIR"

    # Generate random password for Pi-Hole web interface
    local PIHOLE_PASSWORD=$(openssl rand -base64 12)

    cat > "$BASE_DIR/docker-compose.yaml" <<EOF
version: "3"

services:
  pihole:
    container_name: pihole
    image: pihole/pihole:latest
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "80:80/tcp"
    environment:
      TZ: 'America/New_York'
      WEBPASSWORD: '$PIHOLE_PASSWORD'
    volumes:
      - './etc-pihole:/etc/pihole'
      - './etc-dnsmasq.d:/etc/dnsmasq.d'
    restart: unless-stopped

  unbound:
    container_name: unbound
    image: mvance/unbound:latest
    ports:
      - "5335:53/tcp"
      - "5335:53/udp"
    volumes:
      - './unbound:/opt/unbound/etc/unbound'
    restart: unless-stopped
EOF

    cd "$BASE_DIR"
    docker compose up -d

    whiptail --title "Completed" \
    --msgbox "Pi-Hole + Unbound Installed\n\nLocation: $BASE_DIR\nAccess via: http://$(hostname -I | awk '{print $1}')\n\nWeb Password: $PIHOLE_PASSWORD\n\nSave this password!" 15 70
}

install_openproject() {
    whiptail --title "OpenProject Install" \
    --msgbox "Installing OpenProject Project Manager" 10 50

    local BASE_DIR="$HOME/opt/openproject"
    mkdir -p "$BASE_DIR"

    # Generate random secret key for OpenProject
    local SECRET_KEY=$(openssl rand -hex 32)

    cat > "$BASE_DIR/docker-compose.yaml" <<EOF
version: "3"

services:
  openproject:
    container_name: openproject
    image: openproject/openproject:latest
    ports:
      - "8080:80"
    environment:
      OPENPROJECT_SECRET_KEY_BASE: "$SECRET_KEY"
      OPENPROJECT_HOST__NAME: "localhost:8080"
      OPENPROJECT_HTTPS: "false"
    volumes:
      - './pgdata:/var/openproject/pgdata'
      - './assets:/var/openproject/assets'
    restart: unless-stopped
EOF

    cd "$BASE_DIR"
    docker compose up -d

    whiptail --title "Completed" \
    --msgbox "OpenProject Installed\n\nLocation: $BASE_DIR\nAccess via: http://$(hostname -I | awk '{print $1}'):8080" 12 70
}

install_rustdesk() {
    whiptail --title "RustDesk Install" \
    --msgbox "Installing RustDesk Remote Desktop" 10 50

    # Prompt for relay server domain
    local RELAY_SERVER=$(whiptail --inputbox "Enter your relay server domain name or IP address:" 10 60 "$(hostname -I | awk '{print $1}')" 3>&1 1>&2 2>&3)

    if [ -z "$RELAY_SERVER" ]; then
        whiptail --title "Error" --msgbox "Domain/IP required. Installation cancelled." 8 50
        return
    fi

    local BASE_DIR="$HOME/opt/rustdesk"
    mkdir -p "$BASE_DIR"

    cat > "$BASE_DIR/docker-compose.yaml" <<EOF
version: "3"

services:
  hbbs:
    container_name: rustdesk-hbbs
    image: rustdesk/rustdesk-server:latest
    command: hbbs -r $RELAY_SERVER:21117
    volumes:
      - './data:/root'
    ports:
      - "21115:21115"
      - "21116:21116"
      - "21116:21116/udp"
      - "21118:21118"
    restart: unless-stopped

  hbbr:
    container_name: rustdesk-hbbr
    image: rustdesk/rustdesk-server:latest
    command: hbbr
    volumes:
      - './data:/root'
    ports:
      - "21117:21117"
      - "21119:21119"
    restart: unless-stopped
EOF

    cd "$BASE_DIR"
    docker compose up -d

    whiptail --title "Completed" \
    --msgbox "RustDesk Remote Desktop Installed\n\nLocation: $BASE_DIR\nRelay Server: $RELAY_SERVER" 12 70
}

install_nginx_proxy() {
    whiptail --title "Nginx Proxy Manager Install" \
    --msgbox "Installing Nginx Proxy Manager" 10 50

    local BASE_DIR="$HOME/opt/nginx-proxy-manager"
    mkdir -p "$BASE_DIR"

    cat > "$BASE_DIR/docker-compose.yaml" <<'EOF'
version: "3"

services:
  app:
    container_name: nginx-proxy-manager
    image: 'jc21/nginx-proxy-manager:latest'
    restart: unless-stopped
    ports:
      - '80:80'
      - '81:81'
      - '443:443'
    volumes:
      - './data:/data'
      - './letsencrypt:/etc/letsencrypt'
EOF

    cd "$BASE_DIR"
    docker compose up -d

    whiptail --title "Completed" \
    --msgbox "Nginx Proxy Manager Installed\n\nLocation: $BASE_DIR\nAdmin UI: http://$(hostname -I | awk '{print $1}'):81\n\nDefault Login:\nEmail: admin@example.com\nPassword: changeme\n\n⚠️  IMPORTANT: Change these credentials immediately after first login!" 16 75
}

install_nodebb() {
    whiptail --title "NodeBB Install" \
    --msgbox "Installing NodeBB Forum Software" 10 50

    local BASE_DIR="$HOME/opt/nodebb"
    mkdir -p "$BASE_DIR"

    cat > "$BASE_DIR/docker-compose.yaml" <<'EOF'
version: "3"

services:
  nodebb:
    container_name: nodebb
    image: nodebb/docker:latest
    ports:
      - "4567:4567"
    environment:
      NODE_ENV: production
      DATABASE: redis
      REDIS_HOST: redis
      REDIS_PORT: 6379
    volumes:
      - './nodebb/build:/usr/src/app/build'
      - './nodebb/public/uploads:/usr/src/app/public/uploads'
    depends_on:
      - redis
    restart: unless-stopped

  redis:
    container_name: nodebb-redis
    image: redis:alpine
    volumes:
      - './redis:/data'
    restart: unless-stopped
EOF

    cd "$BASE_DIR"
    docker compose up -d

    whiptail --title "Completed" \
    --msgbox "NodeBB Forum Software Installed\n\nLocation: $BASE_DIR\nAccess via: http://$(hostname -I | awk '{print $1}'):4567" 12 70
}

# ------------------------------------------
# OS Administration & Management Functions
# ------------------------------------------

system_update() {
    whiptail --title "System Update" \
    --msgbox "Running system update, upgrade & clean..." 10 50

    apt update
    apt upgrade -y
    apt autoremove -y
    apt autoclean

    whiptail --title "Completed" \
    --msgbox "System Updated, Upgraded & Cleaned" 10 50
}

enable_ufw() {
    whiptail --title "Firewall" \
    --yesno "Enable UFW Firewall?\n\nThis will allow SSH (22) and RDP (3389)" 12 50

    if [ $? -eq 0 ]; then
        apt install -y ufw

        ufw allow ssh
        ufw allow 3389

        ufw --force enable

        whiptail --title "Firewall" \
        --msgbox "UFW Firewall Enabled\n\nSSH and RDP ports are open" 10 50
    fi
}

manage_cron() {
    whiptail --title "Cron Job Management" \
    --msgbox "Opening crontab editor...\n\nAdd your scheduled tasks here." 12 50

    if [ -n "$SUDO_USER" ]; then
        sudo -u "$SUDO_USER" crontab -e
    else
        crontab -e
    fi

    whiptail --title "Completed" \
    --msgbox "Cron jobs updated" 8 40
}

manage_users() {
    CHOICE=$(whiptail \
    --title "User & Group Management" \
    --menu "Select an option" 15 60 5 \
    "1" "Add New User" \
    "2" "Delete User" \
    "3" "List All Users" \
    "4" "Add User to Group" \
    "5" "Back to Main Menu" \
    3>&1 1>&2 2>&3)

    if [ $? -ne 0 ]; then
        return
    fi

    case $CHOICE in
        1)
            USERNAME=$(whiptail --inputbox "Enter new username:" 10 50 3>&1 1>&2 2>&3)
            if [ -n "$USERNAME" ]; then
                adduser "$USERNAME"
                whiptail --title "Success" --msgbox "User $USERNAME created" 8 40
            fi
            ;;
        2)
            USERNAME=$(whiptail --inputbox "Enter username to delete:" 10 50 3>&1 1>&2 2>&3)
            if [ -n "$USERNAME" ]; then
                whiptail --title "Confirm Deletion" --yesno "Are you sure you want to delete user: $USERNAME?\n\nThis action cannot be undone!" 12 60
                if [ $? -eq 0 ]; then
                    if id "$USERNAME" >/dev/null 2>&1; then
                        deluser "$USERNAME"
                        whiptail --title "Success" --msgbox "User $USERNAME deleted" 8 40
                    else
                        whiptail --title "Error" --msgbox "User $USERNAME does not exist" 8 40
                    fi
                fi
            fi
            ;;
        3)
            USERS=$(cut -d: -f1 /etc/passwd | grep -v "^_" | sort)
            whiptail --title "System Users" --msgbox "$USERS" 20 50
            ;;
        4)
            USERNAME=$(whiptail --inputbox "Enter username:" 10 50 3>&1 1>&2 2>&3)
            GROUPNAME=$(whiptail --inputbox "Enter group name:" 10 50 3>&1 1>&2 2>&3)
            if [ -n "$USERNAME" ] && [ -n "$GROUPNAME" ]; then
                usermod -aG "$GROUPNAME" "$USERNAME"
                whiptail --title "Success" --msgbox "User $USERNAME added to group $GROUPNAME" 8 50
            fi
            ;;
        5)
            return
            ;;
    esac
}

# ------------------------------------------
# About Script
# ------------------------------------------

about_script() {
INFO=$(cat <<'EOF'
System Deployment & Management Menu
-----------------------------------

Developed By: s0nt3k
Version: 1.0
Repository: https://github.com/s0nt3k/Scripts

--------------------------------
DISCLAIMER
--------------------------------

This software is provided "as is", without warranty of any kind.

The developer is not responsible for:

- Data loss
- System damage
- Security breaches
- Business interruption
- Compliance violations

You are solely responsible for testing, securing, and
maintaining systems configured using this tool.

Use in production environments is at your own risk.

Always review scripts and configurations before deployment.
Ensure proper backups are in place before making system changes.

--------------------------------
MIT LICENSE
--------------------------------

MIT License

Copyright (c) 2026 s0nt3k

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be included
in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

EOF
)

whiptail --title "About System Deployment & Management Menu" \
--scrolltext \
--msgbox "$INFO" 30 80
}

# ------------------------------------------
# Submenu Functions
# ------------------------------------------

menu_deploy_apps() {
    while true; do
        CHOICE=$(whiptail \
        --title "Deploy Applications & Services" \
        --menu "Select an application to install" 18 70 8 \
        "1" "Install GUI Desktop Environment" \
        "2" "Install Docker-CE & Docker Compose" \
        "3" "Install FreePBX Phone System" \
        "4" "Install NextCloud Server" \
        "5" "Back to Main Menu" \
        3>&1 1>&2 2>&3)

        if [ $? -ne 0 ]; then
            break
        fi

        case $CHOICE in
            1) install_gui_desktop ;;
            2) install_docker_ce ;;
            3) install_freepbx ;;
            4) install_nextcloud ;;
            5) break ;;
        esac
    done
}

menu_deploy_docker() {
    while true; do
        CHOICE=$(whiptail \
        --title "Deploy Docker Compose Containers" \
        --menu "Select a container to deploy" 18 70 8 \
        "1" "Install Unbound Pi-Hole DNS Ad-Blocker" \
        "2" "Install OpenProject Project Manager" \
        "3" "Install RustDesk Remote Desktop" \
        "4" "Install Nginx Proxy Manager" \
        "5" "Install NodeBB Forum Software" \
        "6" "Back to Main Menu" \
        3>&1 1>&2 2>&3)

        if [ $? -ne 0 ]; then
            break
        fi

        case $CHOICE in
            1) install_pihole ;;
            2) install_openproject ;;
            3) install_rustdesk ;;
            4) install_nginx_proxy ;;
            5) install_nodebb ;;
            6) break ;;
        esac
    done
}

menu_os_admin() {
    while true; do
        CHOICE=$(whiptail \
        --title "OS Administration & Management" \
        --menu "Select an option" 18 70 8 \
        "1" "Update, Upgrade & Clean System" \
        "2" "Enable Uncomplicated Firewall UFW" \
        "3" "Manage System Cron Job Scheduling" \
        "4" "Manage Users & Security Groups" \
        "5" "Back to Main Menu" \
        3>&1 1>&2 2>&3)

        if [ $? -ne 0 ]; then
            break
        fi

        case $CHOICE in
            1) system_update ;;
            2) enable_ufw ;;
            3) manage_cron ;;
            4) manage_users ;;
            5) break ;;
        esac
    done
}

# ------------------------------------------
# Main Menu Loop
# ------------------------------------------

while true; do
    CHOICE=$(whiptail \
    --title "System Deployment & Management Menu" \
    --menu "Select an option" 18 70 8 \
    "1" "Deploy Applications & Services" \
    "2" "Deploy Docker Compose Containers" \
    "3" "OS Administration & Management" \
    "4" "View About Script" \
    "5" "Exit" \
    3>&1 1>&2 2>&3)

    if [ $? -ne 0 ]; then
        exit 0
    fi

    case $CHOICE in
        1) menu_deploy_apps ;;
        2) menu_deploy_docker ;;
        3) menu_os_admin ;;
        4) about_script ;;
        5) exit 0 ;;
    esac
done
