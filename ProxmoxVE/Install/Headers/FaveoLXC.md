# Faveo Helpdesk LXC

**Faveo Helpdesk** is an open-source, web-based support ticketing system designed to streamline customer service operations for businesses of all sizes. Built on PHP and using a MySQL database, Faveo provides a user-friendly interface for managing customer queries, support tickets, and service workflows. It supports features like email integration, SLA management, automation rules, canned responses, and custom roles, making it adaptable for use in IT support, real estate client servicing, and other customer-centric industries. With its modular design and REST API support, Faveo can be extended and integrated with third-party tools, offering both on-premise and cloud deployment options for greater control and flexibility.

---
 - Ubuntu 22.04 LXC
 - Apache Webserver
 - PHP Version 8.2
 - Extensions: Mcrypt, OpenSSL, Mbstring, Tokenizer
 - MySQL 8.0.x

## Faveo Installation Script v1.0
```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/s0nt3k/Scripts/refs/heads/main/ProxmoxVE/Install/Ubuntu2204_FaveoHelpdesk_v1.sh)"
```
Container & Database Credentials: `/usr/container.creds`

---

## Faveo Installation Script v2.0
```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/s0nt3k/Scripts/refs/heads/main/ProxmoxVE/Install/Ubuntu2204_FaveoHelpdesk_v2.sh)"
```

Container & Database Credentials: `/usr/container.creds`

---
