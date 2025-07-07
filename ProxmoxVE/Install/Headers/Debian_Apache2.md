### Apache 2.0 Web Server (Debian LXC)

Debian Bookworm, the current stable release of the Debian operating system (version 12), is a highly reliable and secure Linux distribution known for its stability, long-term support, and extensive package repository. When deployed in a containerized environment, such as an LXC (Linux Container) on a Proxmox VE host, Debian Bookworm provides a lightweight and efficient platform ideal for hosting services with minimal overhead. Running the Apache2 web server inside this container offers a robust and widely-used solution for serving web content. Apache2 is a mature, open-source HTTP server that supports dynamic modules, secure connections (HTTPS), virtual hosting, and comprehensive logging. This combination—Debian Bookworm with Apache2 in a container—provides small businesses, IT consultants, and real estate professionals with a scalable, maintainable, and secure web hosting environment suitable for internal applications, client portals, or informational websites, all while isolating workloads for improved performance and security.

```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/s0nt3k/Scripts/refs/heads/main/ProxmoxVE/Install/debian12-apache.sh)"
```
