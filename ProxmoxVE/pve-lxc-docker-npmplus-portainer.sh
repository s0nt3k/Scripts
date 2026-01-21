#!/usr/bin/env bash
set -euo pipefail

# Proxmox LXC + Docker + NPMplus + Portainer helper
# Run on the Proxmox host as root.

############################
# User-configurable defaults
############################
CT_HOSTNAME_DEFAULT="docker"
CT_CORES_DEFAULT="2"
CT_MEM_MB_DEFAULT="2048"
CT_SWAP_MB_DEFAULT="2048"
CT_DISK_GB_DEFAULT="16"
CT_STORAGE_DEFAULT="local-lvm"  # Change if you store CT disks elsewhere (e.g. "local-zfs", "ceph", etc.)
CT_BRIDGE_DEFAULT="vmbr0"
CT_FEATURES="nesting=1,keyctl=1"
CT_UNPRIVILEGED="1"

TZ_DEFAULT="America/Los_Angeles"
STACK_BASE="/opt/stacks"

NPMPLUS_DIR="${STACK_BASE}/npmplus"
PORTAINER_DIR="${STACK_BASE}/portainer"

# NPMplus compose upstream (GitHub raw)
NPMPLUS_COMPOSE_URL="https://raw.githubusercontent.com/ZoeyVid/NPMplus/develop/compose.yaml"

#################################
# Helpers / sanity checks
#################################
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: Missing required command: $1"; exit 1; }
}

require_cmd pct
require_cmd pveam
require_cmd awk
require_cmd sed
require_cmd grep

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: Run this script as root on the Proxmox host."
  exit 1
fi

echo "=== Proxmox LXC Docker Builder ==="
echo

#################################
# Prompt: VMID
#################################
read -rp "Enter VMID for the new LXC (e.g. 120): " CTID
if ! [[ "$CTID" =~ ^[0-9]+$ ]]; then
  echo "ERROR: VMID must be numeric."
  exit 1
fi

if pct status "$CTID" >/dev/null 2>&1; then
  echo "ERROR: VMID $CTID already exists."
  exit 1
fi

#################################
# Prompt: password
#################################
echo
echo "Set the LXC root password now."
read -rsp "Password: " CT_PASS
echo
read -rsp "Confirm: " CT_PASS2
echo
if [[ "$CT_PASS" != "$CT_PASS2" ]]; then
  echo "ERROR: Passwords do not match."
  exit 1
fi

#################################
# Prompt: IPv4 config
#################################
echo
echo "IPv4 configuration:"
echo "  1) DHCP"
echo "  2) Static"
read -rp "Choose [1-2]: " IP_CHOICE

IP_CONFIG=""
GW_CONFIG=""
DNS_CONFIG=""

case "$IP_CHOICE" in
  1)
    IP_CONFIG="dhcp"
    ;;
  2)
    read -rp "Enter static IPv4 CIDR (example: 192.168.1.50/24): " IP_CONFIG
    read -rp "Enter IPv4 gateway (example: 192.168.1.1): " GW_CONFIG
    read -rp "Enter DNS server IPv4 (example: 1.1.1.1): " DNS_CONFIG
    ;;
  *)
    echo "ERROR: Invalid choice."
    exit 1
    ;;
esac

#################################
# Prompt: Hostname (optional)
#################################
echo
read -rp "Hostname [default: ${CT_HOSTNAME_DEFAULT}]: " CT_HOSTNAME
CT_HOSTNAME="${CT_HOSTNAME:-$CT_HOSTNAME_DEFAULT}"

#################################
# Prompt: TZ + ACME Email for NPMplus
#################################
echo
read -rp "Timezone for containers (TZ) [default: ${TZ_DEFAULT}]: " TZ_VAL
TZ_VAL="${TZ_VAL:-$TZ_DEFAULT}"

read -rp "ACME email for Let's Encrypt (ACME_EMAIL) [required for NPMplus]: " ACME_EMAIL
if [[ -z "$ACME_EMAIL" ]]; then
  echo "ERROR: ACME_EMAIL cannot be empty."
  exit 1
fi

#################################
# Find / download Debian 13 template
#################################
echo
echo "=== Ensuring Debian 13 LXC template is available ==="
pveam update >/dev/null

# Try to find latest Debian 13 standard template name from 'pveam available'
TPL="$(pveam available --section system | awk '{print $2}' | grep -E '^debian-13-standard_.*\.tar\.zst$' | tail -n 1 || true)"

if [[ -z "$TPL" ]]; then
  echo "ERROR: Could not find a Debian 13 standard template in pveam catalog."
  echo "       Check your Proxmox version/storage or run: pveam available --section system | grep debian"
  exit 1
fi

echo "Template found: $TPL"
echo "Downloading to 'local' storage if needed..."
pveam download local "$TPL" >/dev/null

#################################
# Build net0 string
#################################
NET0="name=eth0,bridge=${CT_BRIDGE_DEFAULT},ip=${IP_CONFIG},ip6=auto"
if [[ "$IP_CHOICE" == "2" ]]; then
  NET0="name=eth0,bridge=${CT_BRIDGE_DEFAULT},ip=${IP_CONFIG},gw=${GW_CONFIG},ip6=auto"
fi

#################################
# Create LXC
#################################
echo
echo "=== Creating unprivileged LXC $CTID ==="
pct create "$CTID" "local:vztmpl/${TPL}" \
  --hostname "$CT_HOSTNAME" \
  --unprivileged "$CT_UNPRIVILEGED" \
  --cores "$CT_CORES_DEFAULT" \
  --memory "$CT_MEM_MB_DEFAULT" \
  --swap "$CT_SWAP_MB_DEFAULT" \
  --rootfs "${CT_STORAGE_DEFAULT}:${CT_DISK_GB_DEFAULT}" \
  --net0 "$NET0" \
  --features "$CT_FEATURES" \
  --onboot 1 \
  --password "${CT_PASS}" \
  --start 1 \
  --verbose

echo
echo "=== Waiting briefly for container to boot ==="
sleep 3

#################################
# If static DNS was provided, set resolv.conf inside CT
#################################
if [[ "$IP_CHOICE" == "2" && -n "$DNS_CONFIG" ]]; then
  echo "Setting DNS inside container..."
  pct exec "$CTID" -- bash -lc "printf 'nameserver %s\n' '$DNS_CONFIG' > /etc/resolv.conf"
fi

#################################
# Basic packages + Docker install
#################################
echo
echo "=== Installing Docker + Compose inside LXC ==="
pct exec "$CTID" -- bash -lc "
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release iptables uidmap

# Official Docker convenience script (installs docker engine + CLI)
curl -fsSL https://get.docker.com | sh

# Compose plugin + helpful tools
apt-get install -y docker-compose-plugin
systemctl enable --now docker

# Add root to docker group (optional but convenient)
usermod -aG docker root || true

docker --version
docker compose version
"

#################################
# Deploy NPMplus + Portainer stacks
#################################
echo
echo "=== Deploying NPMplus + Portainer via docker compose ==="
pct exec "$CTID" -- bash -lc "
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

mkdir -p '${NPMPLUS_DIR}' '${PORTAINER_DIR}'

# --- NPMplus ---
cd '${NPMPLUS_DIR}'
curl -fsSL '${NPMPLUS_COMPOSE_URL}' -o compose.yaml

# Ensure TZ + ACME_EMAIL are set in compose.yaml (simple replace/insert)
# Replace existing TZ / ACME_EMAIL lines if present; otherwise, append under environment.
if grep -qE '^[[:space:]]*- TZ=' compose.yaml; then
  sed -i -E 's|^[[:space:]]*- TZ=.*$|      - TZ=${TZ_VAL}|' compose.yaml
else
  # best-effort insert after 'environment:' under npmplus service
  sed -i -E '/npmplus:[[:space:]]*$/,/environment:[[:space:]]*$/ { /environment:/ a\\
      - TZ=${TZ_VAL}
  }' compose.yaml || true
fi

if grep -qE '^[[:space:]]*- ACME_EMAIL=' compose.yaml; then
  sed -i -E 's|^[[:space:]]*- ACME_EMAIL=.*$|      - ACME_EMAIL=${ACME_EMAIL}|' compose.yaml
else
  sed -i -E '/npmplus:[[:space:]]*$/,/environment:[[:space:]]*$/ { /environment:/ a\\
      - ACME_EMAIL=${ACME_EMAIL}
  }' compose.yaml || true
fi

# Bring up NPMplus
docker compose -f compose.yaml up -d

# --- Portainer ---
cd '${PORTAINER_DIR}'
cat > docker-compose.yml <<'YAML'
services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - portainer_data:/data
    ports:
      - \"9000:9000\"   # optional legacy UI
      - \"9443:9443\"   # HTTPS UI
YAML

docker compose up -d

echo
echo '--- Running containers ---'
docker ps
"

#################################
# Final notes
#################################
echo
echo "=== Done ==="
echo "LXC VMID:          $CTID"
echo "Hostname:          $CT_HOSTNAME"
echo "IPv4:              $([[ "$IP_CHOICE" == "1" ]] && echo DHCP || echo "$IP_CONFIG (gw: $GW_CONFIG, dns: $DNS_CONFIG)")"
echo "IPv6:              auto"
echo
echo "NPMplus:"
echo "  - Admin UI: http(s)://<LXC-IP>:81"
echo "  - NPMplus image/compose are from ZoeyVid/NPMplus (compose.yaml)."
echo "  - Initial admin password: run inside CT:"
echo "        docker logs npmplus"
echo
echo "Portainer:"
echo "  - UI: https://<LXC-IP>:9443"
echo
echo "Tip: To exec into the CT from Proxmox host:"
echo "  pct exec $CTID -- bash"
