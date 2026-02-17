
<img src="https://github.com/s0nt3k/Scripts/blob/370e5e5df4cd30e82166c0b7cdbe0355b1131a9d/Docker/Assets/Images/nodebb-logo.png" alt="NodeBB Logo" style="display:block; width:300px; margin:0 auto;">

---
**NodeBB** is a modern, open-source discussion forum platform designed to help organizations, businesses, and online communities 
communicate effectively in a secure and easy-to-manage environment. Built on Node.js, it delivers fast performance and real-time 
interactions, allowing users to see new posts, replies, and notifications instantly without refreshing the page. NodeBB supports 
single sign-on, social media logins, and integration with existing websites, making it convenient for members to access and 
participate. With its flexible plugin and theme system, administrators can customize the look, features, and functionality to match 
their brand and business needs. For small businesses, real estate offices, and professional service providers, NodeBB offers a
reliable way to host client forums, support communities, or internal discussion boards while maintaining strong security controls, 
data ownership, and compliance with privacy best practices.


## ✅ Install NodeBB using Docker Compose
The following assumes that you already have Docker and Docker Compose installed and Docker is already up and running.

You will have:

 - `docker-compose.yml` → Main configuration
 - `.env` → Stores passwords, domain, ports, settings (private)

Docker Compose automatically reads `.env` when it’s in the same folder.

## 📁 Step 1: Create a Folder for NodeBB 
The following Cmdlet creates a child directory named NodeBB inside the root directory `/opt`. \
The `/opt` root directory is designed to hold self-contained software packages.
```
mkdir -p /opt/nodebb
cd /opt/nodebb
```
