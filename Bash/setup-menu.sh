#!/bin/bash

# ==========================================
# Ubuntu / WSL Graphical Setup Menu
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
# Functions
# ------------------------------------------

install_gui() {

    whiptail --title "Desktop Install" \
    --msgbox "Installing KDE Desktop + XRDP" 10 50


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
    --msgbox "GUI + XRDP Installed" 10 40
}


install_docker() {

    whiptail --title "Docker Install" \
    --msgbox "Installing Docker CE + Compose" 10 50


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
    --msgbox "Docker Installed\nLog out to activate permissions" 12 50
}


system_update() {

    whiptail --title "System Update" \
    --msgbox "Running system updates..." 10 40


    apt update
    apt upgrade -y
    apt autoremove -y


    whiptail --title "Done" \
    --msgbox "System Updated" 8 30
}


enable_firewall() {

    whiptail --title "Firewall" \
    --yesno "Enable UFW Firewall?\n\nAllow SSH and RDP" 12 50


    if [ $? -eq 0 ]; then

        apt install -y ufw

        ufw allow ssh
        ufw allow 3389

        ufw --force enable

        whiptail --title "Firewall" \
        --msgbox "Firewall Enabled" 8 30
    fi
}


system_info() {

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

    whiptail --title "System Information" \
    --msgbox "$INFO" 20 70
}

about_app() {

INFO=$(cat <<'EOF'
WSL Setup Manager
----------------------------

Developed By: s0nt3k
Version: 1.0

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

whiptail --title "About WSL Setup Manager" \
--scrolltext \
--msgbox "$INFO" 25 80
}



# ------------------------------------------
# Main Menu Loop
# ------------------------------------------

while true; do

    CHOICE=$(whiptail \
    --title "Ubuntu-24.04 / WSL Setup Manager" \
    --menu "Select an option" 20 70 10 \
    "1" "Install GUI (KDE + XRDP)" \
    "2" "Install Docker + Compose" \
    "3" "System Update & Upgrade" \
    "4" "Enable Firewall (UFW)" \
    "5" "System Information" \
    "6" "About WSL Setup Manager" \
    "7" "Exit" \
    3>&1 1>&2 2>&3)


    if [ $? -ne 0 ]; then
        exit 0
    fi


    case $CHOICE in

        1) install_gui ;;
        2) install_docker ;;
        3) system_update ;;
        4) enable_firewall ;;
        5) system_info ;;
        6) about_app ;;
        7) exit 0 ;;

    esac

done
