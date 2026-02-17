# 🚀 CybtekSTK – NodeBB Deployment Platform

Automated provisioning and deployment system for installing **NodeBB** using Docker and Docker Compose on Linux servers.

Powered by **CybtekSTK Infrastructure Toolkit**.

---

## 📌 About NodeBB

**NodeBB** is a modern, open-source discussion forum platform built with Node.js.

It provides:

* Real-time messaging
* Responsive mobile-friendly design
* Social media integration
* Moderation and access controls
* Enterprise scalability
* Plugin ecosystem

NodeBB is suitable for businesses, professional communities, and organizations that require reliable and secure communication platforms.

---

## 🛠️ About CybtekSTK Provisioning Script

The **CybtekSTK Bash Script** is an automated Linux provisioning system that provides a graphical menu interface for:

* System updates
* Docker installation
* NodeBB deployment
* Container management
* Optional infrastructure services

It reduces configuration errors and helps standardize deployments.

---

## ▶️ Run the Installer Script

Copy and run the following command to download and execute the provisioning script:

```bash
curl -fsSL https://yourdomain.com/cybtekstk-nodebb.sh -o setup.sh && chmod +x setup.sh && sudo ./setup.sh
```

> Replace `yourdomain.com` with your actual hosting domain.

---

## 📋 Script Menu Options

### 1️⃣ Update, Upgrade & Cleanup Packages

Runs:

```bash
sudo apt update && sudo apt -y full-upgrade && sudo apt -y auto-clean
```

Keeps the system secure and up to date.

---

### 2️⃣ Install Docker-CE & Docker Plugins

This option will:

* Update system packages
* Install prerequisites:

  * ca-certificates
  * curl
  * gnupg
  * lsb-release
* Add Docker GPG key and repository
* Install:

  * docker-ce
  * docker-ce-cli
  * containerd.io
  * docker-buildx-plugin
  * docker-compose-plugin
* Enable Docker service
* Verify installation using `hello-world`

After installation, the script will prompt to install:

* Portainer
* Nginx Proxy Manager
* Pi-hole with Unbound (Quad9 DNS)

---

### 3️⃣ Deploy NodeBB Docker Container

This option will:

* Create directory:

```bash
/opt/nodebb
```

* Generate:

  * `docker-compose.yml`
  * `.env`

* Prompt for:

  * Custom domain
  * Port (default: 4567)
  * HTTP or HTTPS
  * Database password (custom or auto-generated)
  * Timezone (default: America/Los_Angeles)

* Deploy containers:

```bash
docker compose up -d
```

---

### 4️⃣ Execute Docker Control Commands

Provides a graphical interface to manage containers.

Available operations:

* List running containers
* List all containers
* Start containers
* Stop containers
* Restart containers
* Kill containers
* View logs
* View resource usage
* Remove containers
* Remove images
* Pause/Unpause containers
* Rename containers
* View container processes
* Load images from archive
* Display port mappings

After selecting a command, the script displays all containers with checkboxes for multi-selection.

---

## ⚙️ Optional Infrastructure Components

During setup, you may install:

### 📊 Portainer

Container management UI.

Installed at:

```bash
/opt/portainer
```

---

### 🌐 Nginx Proxy Manager

Reverse proxy with SSL management.

Installed at:

```bash
/opt/nginx
```

---

### 🛡️ Pi-hole with Unbound (Quad9 DNS)

DNS filtering and secure resolution.

Configured with:

* Malware blocking
* DNSSEC validation
* ECS enabled
* Quad9 Secure DNS

---

## 📁 Manual NodeBB Deployment (Alternative Method)

If you prefer manual deployment:

---

### 1️⃣ Create Directory

```bash
mkdir -p /opt/nodebb
cd /opt/nodebb
```

---

### 2️⃣ Download Files

```bash
wget https://yourdomain.com/docker-compose.yml
wget https://yourdomain.com/.env
```

---

### 3️⃣ Edit Configuration

```bash
nano docker-compose.yml
nano .env
```

---

### 4️⃣ Deploy Containers

```bash
docker compose up -d
```

---

### 5️⃣ Verify Status

```bash
docker ps
```

---

## 🔐 Security & Compliance Notice

If this platform is used for business or client environments, minimum security requirements include:

* HTTPS encryption
* Strong credentials
* Secure backups
* Access controls
* Regular patching

Failure to secure deployments may violate:

| Regulation           | Risk                       |
| -------------------- | -------------------------- |
| State Privacy Laws   | $2,500–$7,500 per incident |
| FTC Safeguards Rule  | Civil penalties            |
| Client Contracts     | Legal liability            |
| GDPR (if applicable) | Up to 4% revenue           |

Credential exposure or system compromise may be legally reportable.

---

## 📂 Recommended Directory Layout

```
/opt
 ├── nodebb
 ├── portainer
 ├── nginx
 └── pihole
```

---

## 🔄 Maintenance Commands

### Update Containers

```bash
docker compose pull
docker compose up -d
```

---

### View Logs

```bash
docker compose logs -f
```

---

### Stop Services

```bash
docker compose down
```

---

### Restart Services

```bash
docker compose restart
```

---

## ✅ Best Practices

For production environments:

✔ Enable SSL
✔ Use `.env` files
✔ Rotate credentials regularly
✔ Enable automated backups
✔ Monitor resource usage
✔ Use firewall rules

---

## 📞 Support & Customization

For custom deployments, security hardening, and managed services:

Contact: **CybtekSTK / Sonny Gibson**

---

© 2026 CybtekSTK – Secure Infrastructure Deployment Platform

---

If you’d like, I can next generate:

👉 A complete `cybtekstk-nodebb.sh` script
👉 A secure default `docker-compose.yml`
👉 Automated backup scripts
👉 CI/CD deployment workflows
