# Zammad Docker Deployment

Self-hosted [Zammad](https://zammad.com/) help desk / support ticketing system deployed with Docker Compose.

This deployment includes:

- Zammad Rails application
- Zammad Nginx web frontend
- Zammad WebSocket service
- Zammad Scheduler
- Zammad automated backup service
- PostgreSQL 17
- Redis
- Memcached
- Elasticsearch
- Persistent Docker volumes

> **Repository location:**  
> `https://github.com/s0nt3k/Scripts/tree/main/Docker/Zammad`

---

## Table of Contents

- [Requirements](#requirements)
- [Clone the Repository](#clone-the-repository)
- [Configure the Environment File](#configure-the-environment-file)
- [Generate a Secure PostgreSQL Password](#generate-a-secure-postgresql-password)
- [Protect the Environment File](#protect-the-environment-file)
- [Configure Elasticsearch Host Requirement](#configure-elasticsearch-host-requirement)
- [Validate the Configuration](#validate-the-configuration)
- [Start Zammad](#start-zammad)
- [Verify the Deployment](#verify-the-deployment)
- [Open Zammad](#open-zammad)
- [Using a Cloudflare Tunnel](#using-a-cloudflare-tunnel)
- [Stopping and Restarting Zammad](#stopping-and-restarting-zammad)
- [Updating Zammad](#updating-zammad)
- [Backups](#backups)
- [Useful Commands](#useful-commands)
- [Security Notes](#security-notes)

---

## Requirements

The Docker host should have:

- Linux
- Docker Engine
- Docker Compose v2
- Git
- At least **4 GB RAM**
- Sufficient disk space for tickets, email attachments, PostgreSQL, and Elasticsearch

Verify Docker:

```bash
docker --version
docker compose version
```

---

## Clone the Repository

The Zammad files are stored inside the `Scripts` repository.

A convenient location for Docker applications is `/opt`.

```bash
cd /opt
sudo git clone https://github.com/s0nt3k/Scripts.git
cd /opt/Scripts/Docker/Zammad
```

If the repository has already been cloned:

```bash
cd /opt/Scripts
sudo git pull
cd Docker/Zammad
```

Verify the files:

```bash
ls -la
```

You should see:

```text
docker-compose.yaml
example-.env
.gitignore
README.md
```

---

## Configure the Environment File

Never put passwords directly in `docker-compose.yaml`.

Copy the example file:

```bash
cp example-.env .env
```

Edit it:

```bash
nano .env
```

At minimum, change:

```dotenv
POSTGRES_PASS=CHANGE_ME_TO_A_LONG_RANDOM_PASSWORD
```

If Zammad will use a DNS hostname, also change:

```dotenv
ZAMMAD_FQDN=support.example.com
```

If HTTPS is terminated by a reverse proxy or Cloudflare Tunnel, use:

```dotenv
ZAMMAD_HTTP_TYPE=https
```

### Save and Exit Nano

Press:

```text
Ctrl + O
```

Press `Enter` to save.

Then press:

```text
Ctrl + X
```

to exit.

---

## Generate a Secure PostgreSQL Password

Generate a strong random password:

```bash
openssl rand -base64 48
```

This produces approximately 64 printable characters.

Copy the generated value and place it after:

```dotenv
POSTGRES_PASS=
```

Example:

```dotenv
POSTGRES_PASS=YOUR_RANDOM_PASSWORD_HERE
```

Do **not** use the example password in production.

---

## Protect the Environment File

The `.env` file contains the PostgreSQL password and should only be readable and writable by its owner.

```bash
chmod 600 .env
```

Verify:

```bash
ls -l .env
```

Expected permissions:

```text
-rw-------
```

You can also verify numerically:

```bash
stat -c "%a %n" .env
```

Expected:

```text
600 .env
```

The included `.gitignore` prevents `.env` from being committed to Git.

Verify:

```bash
git check-ignore .env
```

Expected output:

```text
.env
```

---

## Configure Elasticsearch Host Requirement

Zammad strongly recommends Elasticsearch. Linux must allow Elasticsearch to create enough virtual memory mappings.

Apply the setting immediately:

```bash
sudo sysctl -w vm.max_map_count=262144
```

Make it persistent across reboots:

```bash
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-zammad-elasticsearch.conf
```

Load it:

```bash
sudo sysctl --system
```

Verify:

```bash
sysctl vm.max_map_count
```

Expected:

```text
vm.max_map_count = 262144
```

---

## Validate the Configuration

Before starting the containers:

```bash
docker compose config
```

This checks the YAML file and expands the variables from `.env`.

You can also view the service list:

```bash
docker compose config --services
```

---

## Start Zammad

Pull the container images:

```bash
docker compose pull
```

Start the stack:

```bash
docker compose up -d
```

The initial startup may take longer than later starts because Docker must download the images and Zammad must initialize its database.

---

## Verify the Deployment

Check container status:

```bash
docker compose ps
```

Most services should eventually show `Up` or `healthy`.

The `zammad-init` container is expected to finish its initialization work and then stop.

View the logs:

```bash
docker compose logs -f
```

Or view only the web frontend:

```bash
docker compose logs -f zammad-nginx
```

To inspect recent logs without continuously following them:

```bash
docker compose logs --tail=100
```

---

## Open Zammad

By default, Zammad is published on TCP port `8080`.

From the Docker host:

```text
http://localhost:8080
```

From another computer on the LAN:

```text
http://DOCKER-SERVER-IP:8080
```

The first visit should display the Zammad setup wizard.

Use the wizard to create the initial administrator account and configure your organization.

---

## Using a Cloudflare Tunnel

If you already run a separate `cloudflared` Docker container, it can publish Zammad without exposing TCP port 8080 directly to the Internet.

Create a public hostname such as:

```text
support.example.com
```

Point the Cloudflare Tunnel service to:

```text
http://DOCKER-SERVER-IP:8080
```

Or, if your Cloudflare container shares a Docker network with Zammad, point it to:

```text
http://zammad-nginx:8080
```

Then update `.env`:

```dotenv
ZAMMAD_FQDN=support.example.com
ZAMMAD_HTTP_TYPE=https
```

Restart Zammad:

```bash
docker compose up -d
```

> Do not expose Zammad directly to the public Internet over plain HTTP. Use HTTPS through Cloudflare Tunnel or another properly configured reverse proxy.

---

## Stopping and Restarting Zammad

Stop the containers without deleting data:

```bash
docker compose stop
```

Start them again:

```bash
docker compose start
```

Restart all services:

```bash
docker compose restart
```

Remove the running containers while retaining the named volumes:

```bash
docker compose down
```

Start them again:

```bash
docker compose up -d
```

### WARNING

Do not use the following command unless you intentionally want to delete the Docker volumes and Zammad data:

```bash
docker compose down -v
```

---

## Updating Zammad

Go to the repository:

```bash
cd /opt/Scripts
```

Download your latest repository changes:

```bash
sudo git pull
```

Return to Zammad:

```bash
cd Docker/Zammad
```

Pull updated Docker images:

```bash
docker compose pull
```

Recreate the containers:

```bash
docker compose up -d
```

Check the status:

```bash
docker compose ps
```

Before a major upgrade, make sure you have a verified backup.

Because this configuration pins the Zammad version in `example-.env`, update the `VERSION=` value in your actual `.env` when you intentionally upgrade Zammad.

---

## Backups

The stack includes the Zammad backup service and a persistent `zammad-backup` Docker volume.

Default settings:

```dotenv
BACKUP_TIME=03:00
BACKUP_ON_START=false
HOLD_DAYS=10
```

These values can be changed in `.env`.

List the volumes:

```bash
docker volume ls | grep zammad
```

For business use, Docker volumes should not be your only backup.

Maintain a second backup copy on separate storage or offsite storage and periodically test that the backup can actually be restored.

---

## Useful Commands

Show running containers:

```bash
docker compose ps
```

View all logs:

```bash
docker compose logs -f
```

Restart Zammad:

```bash
docker compose restart
```

Check resource consumption:

```bash
docker stats
```

Show Docker disk usage:

```bash
docker system df
```

Open a Rails console:

```bash
docker compose exec zammad-railsserver bundle exec rails c
```

Rebuild the Elasticsearch search index when required by a Zammad release:

```bash
docker compose run --rm zammad-railsserver bundle exec rake zammad:searchindex:rebuild
```

---

## Security Notes

1. **Never commit `.env` to GitHub.** It contains credentials.
2. Protect `.env` with `chmod 600`.
3. Use a long randomly generated PostgreSQL password.
4. Keep Docker, the Linux host, and Zammad updated.
5. Do not publish PostgreSQL, Redis, Memcached, or Elasticsearch ports to the Internet.
6. Use HTTPS when accessing Zammad remotely.
7. Restrict administrative access to trusted users.
8. Back up the application data and test restoration procedures.
9. Consider host firewall rules even when using a Cloudflare Tunnel.
10. Review Zammad release notes before major upgrades.

---

## Deployment Architecture

```text
                        ┌──────────────────────┐
Internet / LAN ───────► │    Zammad Nginx     │
                        │      TCP 8080        │
                        └──────────┬───────────┘
                                   │
                 ┌─────────────────┼──────────────────┐
                 │                 │                  │
                 ▼                 ▼                  ▼
        ┌────────────────┐ ┌──────────────┐ ┌────────────────┐
        │ Rails Server   │ │  WebSocket   │ │   Scheduler    │
        └───────┬────────┘ └──────────────┘ └────────────────┘
                │
       ┌────────┼───────────┬───────────────┐
       │        │           │               │
       ▼        ▼           ▼               ▼
 ┌──────────┐ ┌───────┐ ┌───────────┐ ┌───────────────┐
 │PostgreSQL│ │ Redis │ │ Memcached │ │ Elasticsearch │
 │    17    │ │       │ │           │ │               │
 └──────────┘ └───────┘ └───────────┘ └───────────────┘
```

---

## References

- Zammad Docker documentation: `https://docs.zammad.org/en/latest/install/docker-compose.html`
- Official Zammad Docker Compose repository: `https://github.com/zammad/zammad-docker-compose`
- Zammad documentation: `https://docs.zammad.org/`
