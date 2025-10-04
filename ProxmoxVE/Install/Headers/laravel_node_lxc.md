
This Proxmox helper script automates the creation of a fully configured Debian 12 LXC container that hosts a complete web development environment including Nginx, PHP 8.2, Laravel, Node.js (Express), and Bootstrap 5.0.2. When executed from a Proxmox VE host, the script provisions a new lightweight Linux container, installs and configures the necessary software packages, and deploys both a Laravel web application and a sample Express API service. It also integrates Bootstrap by downloading the official release from the Bootstrap GitHub repository and extracting its contents into the /var/www directory for immediate use in the Laravel front-end.

During setup, the script automatically retrieves the latest Debian 12 LXC template from Proxmox’s repository (if not already available), creates the container with defined parameters such as ID, hostname, storage, CPU cores, memory, and network configuration, and enables key features like nesting for Node.js compatibility. Once the container is running, it installs Nginx, PHP 8.2, and Composer, generates a Laravel project in /var/www/laravel, and sets appropriate ownership for the www-data user. It also installs Node.js 20 LTS and PM2 for process management, sets up an Express application under /opt/express-app, and configures Nginx as a reverse proxy so that Laravel is served on port 80 while API calls to /api are forwarded to the Express backend. The script enables both PHP-FPM and Nginx services to start automatically and configures a basic UFW firewall to allow HTTP traffic.


```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/s0nt3k/Scripts/refs/heads/main/ProxmoxVE/Install/laravel_node_lxc.sh)"
```
