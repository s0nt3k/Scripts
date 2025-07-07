#!/bin/bash

# === Configuration Parameters ===
HOSTNAME=request-tracker
PASSWORD='ChangeThisPassword123!'
TEMPLATE='local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst'
STORAGE='local-lvm'
DISK_SIZE='16G'
MEMORY='4096'
SWAP='4096'
CPUS=2
IP_ADDRESS='172.16.1.24/24'
GATEWAY='172.16.1.1'
BRIDGE='vmbr0'

# === Download Debian 12 Template if Needed ===
if ! pveam list local | grep -q debian-12; then
  echo "[INFO] Downloading Debian 12 template..."
  pveam update
  pveam download local debian-12-standard_12.2-1_amd64.tar.zst
fi

# === Create the Container ===
echo "[INFO] Creating LXC container $CTID..."
pct create $CTID $TEMPLATE \
  -hostname $HOSTNAME \
  -password $PASSWORD \
  -storage $STORAGE \
  -rootfs ${STORAGE}:$DISK_SIZE \
  -memory $MEMORY \
  -swap $SWAP \
  -cores $CPUS \
  -net0 name=eth0,bridge=$BRIDGE,ip=$IP_ADDRESS,gw=$GATEWAY \
  -features nesting=1 \
  -onboot 1 \
  -ostype debian

# === Start the Container ===
echo "[INFO] Starting container $CTID..."
pct start $CTID
sleep 5

# === Install Apache2 in the Container ===
echo "[INFO] Installing Apache2 web server inside container $CTID..."
pct exec $CTID -- apt update
pct exec $CTID -- apt install -y apache2

# === Enable Apache2 and Show Status ===
pct exec $CTID -- systemctl enable apache2
pct exec $CTID -- systemctl status apache2

# === Output Access Info ===
echo "[INFO] Apache2 installation complete."
echo "You can access the container shell using: pct enter $CTID"
