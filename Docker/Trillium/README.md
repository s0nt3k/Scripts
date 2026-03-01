# Trilium Notes – Docker Deployment Guide

## What Is Trilium?

Trilium Notes is a self-hosted, hierarchical note-taking application designed for building structured knowledge bases.

It is especially useful for:

* Internal documentation
* Standard operating procedures (SOPs)
* Client notes
* Research repositories
* Secure knowledge management
* IT documentation
* Real estate transaction tracking notes

Unlike simple note apps, Trilium supports:

* Nested notes (tree structure)
* Rich text and Markdown
* Code blocks and syntax highlighting
* Attachments
* Note encryption
* Cross-note linking
* Advanced search
* Scripting and automation

Because it is self-hosted, **you retain full control of your data**.

---

# Why Use Docker?

Using Docker provides:

* Easy deployment
* Portability between servers
* Simplified updates
* Clean separation from the host OS
* Easy backup of a single data directory

For small businesses and professional environments, Docker simplifies ongoing maintenance.

---

# Docker Compose Deployment

Below is the recommended `docker-compose.yml` file.

```yaml
version: "3.8"

services:
  trilium:
    image: triliumnext/notes:latest
    container_name: trilium
    restart: unless-stopped

    ports:
      - "8080:8080"

    volumes:
      - ./trilium-data:/home/node/trilium-data

    environment:
      - TRILIUM_DATA_DIR=/home/node/trilium-data
      - NODE_ENV=production

    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:8080"]
      interval: 30s
      timeout: 5s
      retries: 3
```

---

# Directory Structure

Create a dedicated folder for deployment:

```
/opt/trilium/
├── docker-compose.yml
└── trilium-data/
```

The `trilium-data` folder stores:

* All notes
* Attachments
* Configuration
* Database files

If this folder is deleted, your notes are permanently lost.

---

# How to Deploy

### 1. Install Docker & Docker Compose

Ensure Docker is installed:

```
docker --version
docker compose version
```

### 2. Start the Container

From inside the folder containing `docker-compose.yml`:

```
docker compose up -d
```

### 3. Access Trilium

Open your browser:

```
http://SERVER-IP:8080
```

On first launch, you will:

* Create an administrator password
* Initialize your note tree

---

# How Updates Work

To update to the latest version:

```
docker compose pull
docker compose up -d
```

Your data remains safe because it lives in the mounted volume (`trilium-data`).

---

# Backup Recommendations

For professional environments:

1. Stop the container:

   ```
   docker compose down
   ```

2. Backup the `trilium-data` directory.

3. Restart:

   ```
   docker compose up -d
   ```

You should:

* Perform daily backups
* Store backups offsite
* Test restoration procedures quarterly

Failure to maintain documentation backups can disrupt business continuity and may violate industry retention requirements depending on your regulatory environment.

---

# Security Recommendations

If exposing publicly:

* Place behind a reverse proxy (Nginx or Traefik)
* Use HTTPS (Let's Encrypt)
* Restrict access by IP when possible
* Use strong administrator passwords
* Consider network-level firewall controls

Avoid exposing port 8080 directly to the internet in production.

---

# Stopping the Service

```
docker compose down
```

---

# Common Commands

| Action    | Command                                       |
| --------- | --------------------------------------------- |
| Start     | `docker compose up -d`                        |
| Stop      | `docker compose down`                         |
| View Logs | `docker compose logs -f`                      |
| Update    | `docker compose pull && docker compose up -d` |

---

# Who Is This For?

This setup works well for:

* Small businesses
* IT consultants
* Managed service providers
* Real estate brokers
* Legal offices
* Research teams
* Home labs

---

# License

Trilium Notes is open-source software.
Refer to the official project repository for licensing details.

---

If you would like, I can also generate:

* A hardened enterprise README version
* A reverse-proxy + SSL deployment guide
* A backup automation guide
* A Windows Server version
* A compliance-oriented documentation template for regulated industries
