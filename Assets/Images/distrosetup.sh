#!/bin/bash

set -e

# ==========================================
# WSL / Linux Setup Manager
# ==========================================

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


DEPLOYED_SERVICES=()


# ==========================================
# Install GUI
# ==========================================

install_gui() {

(
echo 20
echo "# Updating repositories..."
apt update >/dev/null 2>&1

echo 40
echo "# Installing tasksel..."
apt install -y tasksel >/dev/null 2>&1

echo 60
echo "# Launching Desktop installer..."
sleep 2

tasksel

echo 80
echo "# Installing XRDP..."
apt install -y xrdp >/dev/null 2>&1

echo 100
) | whiptail --gauge "Installing KDE Desktop + XRDP..." 8 60 0

systemctl enable xrdp
systemctl restart xrdp

echo "startplasma-x11" > /etc/skel/.xsession
chmod +x /etc/skel/.xsession

whiptail --msgbox "Desktop Installed Successfully" 8 40
}


# ==========================================
# Install Docker
# ==========================================

install_docker() {

(
echo 10
echo "# Updating packages..."
apt update >/dev/null 2>&1

echo 30
echo "# Installing dependencies..."
apt install -y ca-certificates curl gnupg lsb-release >/dev/null 2>&1

echo 50
echo "# Adding Docker repository..."

mkdir -p /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
 | gpg --dearmor -o /etc/apt/keyrings/docker.gpg >/dev/null 2>&1

echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(lsb_release -cs) stable" \
> /etc/apt/sources.list.d/docker.list

apt update >/dev/null 2>&1

echo 70
echo "# Installing Docker Engine..."

apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1

echo 90
echo "# Starting Docker..."

systemctl enable docker >/dev/null 2>&1
systemctl start docker >/dev/null 2>&1

echo 100
) | whiptail --gauge "Installing Docker Engine..." 8 60 0


docker run hello-world

whiptail --msgbox "Docker Hello World executed successfully." 8 50

docker rm $(docker ps -aq --filter ancestor=hello-world) >/dev/null 2>&1


whiptail --yesno "Install Portainer Docker Manager?" 10 50

if [ $? -eq 0 ]; then

docker volume create portainer_data

docker run -d \
-p 9000:9000 \
--name portainer \
--restart=always \
-v /var/run/docker.sock:/var/run/docker.sock \
-v portainer_data:/data \
portainer/portainer-ce

DEPLOYED_SERVICES+=("portainer.localhost:9000")

fi

}


# ==========================================
# Deploy Containers
# ==========================================

deploy_containers() {

CHOICE=$(whiptail --title "Docker Deployments" \
--menu "Select container to deploy" 25 70 15 \
"01" "Deploy Pi-Hole w/ Unbound Recursive DNS" \
"02" "Deploy Radicale CalDAV/CardDAV Server" \
"03" "Deploy Open WebUI w/ Ollama & NVIDIA GPU" \
"04" "Deploy Nginx Reverse Proxy Manager" \
"05" "Deploy Graylog Server" \
"06" "Deploy Wordpress CMS" \
"07" "Deploy Trilium Knowledgebase" \
"08" "Deploy Dozzle Log Viewer" \
"09" "Deploy Watchtower Container Manager" \
"10" "Deploy Komodo Docker Manager" \
"11" "Deploy NetData Monitoring" \
"12" "Deploy Uptime Kuma" \
"13" "Deploy Cloudflared Tunnel" \
3>&1 1>&2 2>&3)


case $CHOICE in

01)

docker run -d \
--name pihole \
-p 53:53/tcp -p 53:53/udp \
-p 80:80 \
--restart=unless-stopped \
pihole/pihole

DEPLOYED_SERVICES+=("pihole.localhost")

;;

02)

USERNAME=$(whiptail --inputbox "Radicale Username" 10 50 3>&1 1>&2 2>&3)

PASSWORD=$(whiptail --passwordbox "Radicale Password" 10 50 3>&1 1>&2 2>&3)

HASH=$(htpasswd -bnBC 10 "" $PASSWORD | tr -d ':\n')

mkdir -p radicale/data

echo "$USERNAME:$HASH" > radicale/users

docker run -d \
--name radicale \
-p 5232:5232 \
-v $(pwd)/radicale:/data \
tomsquest/docker-radicale

DEPLOYED_SERVICES+=("radicale.localhost:5232")

;;

03)

docker run -d \
--gpus all \
-p 3000:8080 \
--name openwebui \
ghcr.io/open-webui/open-webui:main

DEPLOYED_SERVICES+=("openwebui.localhost:3000")

;;

04)

docker run -d \
-p 81:81 -p 80:80 -p 443:443 \
--name npm \
jc21/nginx-proxy-manager

DEPLOYED_SERVICES+=("npm.localhost")

;;

05)

docker run -d \
-p 9001:9000 \
--name graylog \
graylog/graylog

DEPLOYED_SERVICES+=("graylog.localhost")

;;

06)

docker run -d \
-p 8080:80 \
--name wordpress \
wordpress

DEPLOYED_SERVICES+=("wordpress.localhost")

;;

07)

docker run -d \
-p 8081:8080 \
--name trilium \
zadam/trilium

DEPLOYED_SERVICES+=("trilium.localhost")

;;

08)

docker run -d \
-p 9999:8080 \
--name dozzle \
amir20/dozzle

DEPLOYED_SERVICES+=("dozzle.localhost")

;;

09)

docker run -d \
--name watchtower \
-v /var/run/docker.sock:/var/run/docker.sock \
containrrr/watchtower

;;

10)

docker run -d \
-p 5000:5000 \
--name komodo \
komodorio/komodo

DEPLOYED_SERVICES+=("komodo.localhost")

;;

11)

docker run -d \
-p 19999:19999 \
--name netdata \
netdata/netdata

DEPLOYED_SERVICES+=("netdata.localhost")

;;

12)

docker run -d \
-p 3001:3001 \
--name uptime-kuma \
louislam/uptime-kuma

DEPLOYED_SERVICES+=("uptime.localhost")

;;

13)

docker run -d \
--name cloudflared \
cloudflare/cloudflared:latest tunnel run

show_fqdns

;;

esac

}


# ==========================================
# Show FQDN List
# ==========================================

show_fqdns() {

LIST="Deployed Application Routes\n\n"

for svc in "${DEPLOYED_SERVICES[@]}"
do
 LIST="$LIST$svc\n"
done

whiptail --msgbox "$LIST" 20 60

}


# ==========================================
# System Update
# ==========================================

system_update() {

(
echo 5
echo "# Updating package index..."
apt update >/dev/null 2>&1

echo 30
echo "# Package index updated"

sleep 1
echo 100
) | whiptail --gauge "Running apt update..." 8 60 0


# ------------------------------------------
# Upgrade Type Selection
# ------------------------------------------

UPGRADE_TYPE=$(whiptail \
--title "System Upgrade Options" \
--menu "Choose Upgrade Type

Regular Upgrade:
Installs available updates but NEVER removes or installs packages.

Full Upgrade:
May install new dependencies or remove old packages to complete upgrades.
Recommended for major system updates." \
20 70 2 \
"1" "Regular Upgrade (apt upgrade)" \
"2" "Full Upgrade (apt full-upgrade)" \
3>&1 1>&2 2>&3)

if [ $? -ne 0 ]; then
    return
fi


# ------------------------------------------
# Run Upgrade with Progress
# ------------------------------------------

if [ "$UPGRADE_TYPE" == "1" ]; then

(
echo 10
echo "# Running apt upgrade..."
apt upgrade -y >/dev/null 2>&1

echo 100
) | whiptail --gauge "Installing updates..." 8 60 0

else

(
echo 10
echo "# Running apt full-upgrade..."
apt full-upgrade -y >/dev/null 2>&1

echo 100
) | whiptail --gauge "Running full system upgrade..." 8 60 0

fi


# ------------------------------------------
# Autoremove
# ------------------------------------------

(
echo 10
echo "# Removing unused packages..."
apt autoremove -y >/dev/null 2>&1

echo 100
) | whiptail --gauge "Running apt autoremove..." 8 60 0


# ------------------------------------------
# Clean Options
# ------------------------------------------

CLEAN_TYPE=$(whiptail \
--title "APT Cache Cleanup" \
--menu "Choose cleanup option

Clean:
Removes ALL downloaded package files from /var/cache/apt.

Autoclean:
Removes only outdated packages that can no longer be downloaded." \
20 70 2 \
"1" "Clean (apt clean)" \
"2" "Autoclean (apt autoclean)" \
3>&1 1>&2 2>&3)

if [ $? -ne 0 ]; then
    return
fi


if [ "$CLEAN_TYPE" == "1" ]; then

(
echo 10
echo "# Cleaning APT cache..."
apt clean

echo 100
) | whiptail --gauge "Running apt clean..." 8 60 0

else

(
echo 10
echo "# Cleaning obsolete packages..."
apt autoclean -y

echo 100
) | whiptail --gauge "Running apt autoclean..." 8 60 0

fi


# ------------------------------------------
# Restart Option
# ------------------------------------------

whiptail --title "Restart System" \
--yesno "Updates completed.

Would you like to restart the Linux distribution now?" 10 60

if [ $? -eq 0 ]; then
    reboot
else
    whiptail --msgbox "Restart skipped. Some updates may require a reboot." 8 50
fi

}


# ==========================================
# Firewall
# ==========================================

enable_firewall(){

apt install -y ufw
ufw allow ssh
ufw allow 3389
ufw --force enable

}


# ==========================================
# System Info
# ==========================================

system_info(){

INFO=$(cat <<EOF
Hostname: $(hostname)
OS: $(lsb_release -d | cut -f2)
Kernel: $(uname -r)
CPU: $(lscpu | grep "Model name" | cut -d: -f2)
Memory: $(free -h | awk '/Mem:/ {print $2}')
Disk: $(df -h / | awk 'NR==2 {print $2}')
Docker: $(docker --version 2>/dev/null || echo "Not Installed")
EOF
)

whiptail --msgbox "$INFO" 20 70

}


# ==========================================
# Main Menu
# ==========================================

while true
do

CHOICE=$(whiptail \
--title "WSL Setup Manager" \
--menu "Select Option" 20 60 10 \
"1" "Install GUI (KDE + XRDP)" \
"2" "Install Docker + Compose" \
"3" "Deploy Docker Containers" \
"4" "System Update & Upgrade" \
"5" "Enable Firewall (UFW)" \
"6" "System Information" \
"7" "Exit" \
3>&1 1>&2 2>&3)

case $CHOICE in

1) install_gui ;;
2) install_docker ;;
3) deploy_containers ;;
4) system_update ;;
5) enable_firewall ;;
6) system_info ;;
7) exit 0 ;;

esac

done
