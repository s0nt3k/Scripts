#!/bin/bash

# Stop if any command fails
set -e

echo "Updating system packages..."
apt update -y
apt upgrade -y

echo "Installing required dependencies..."
apt install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

echo "Creating keyrings directory..."
install -m 0755 -d /etc/apt/keyrings

echo "Adding Docker GPG key..."
curl -fsSL https://download.docker.com/linux/debian/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

chmod a+r /etc/apt/keyrings/docker.gpg

echo "Adding Docker repository..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "Updating package list with Docker repo..."
apt update -y

echo "Installing Docker Engine and Docker Compose plugin..."
apt install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

echo "Enabling and starting Docker service..."
systemctl enable docker
systemctl start docker

echo "Docker version:"
docker --version

echo "Docker Compose version:"
docker compose version

echo "Installation complete."
