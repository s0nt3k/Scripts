<div align="center">
  <p align="center">
    <a href="#">
      <img src="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/images/logo.png" height="100px" />
    </a>
  </p>
</div>

<div style="border: 2px solid #d1d5db; padding: 20px; border-radius: 8px; background-color: #f9fafb;">
  <h2 align="center">Proxmox VE Helper-Scripts</h2>
  <p align="center">A Community Legacy in Memory of @tteck</p>
  <p align="center">
    <a href="https://helper-scripts.com">
      <img src="https://img.shields.io/badge/Website-4c9b3f?style=for-the-badge&logo=github&logoColor=white" alt="Website" />
    </a>
    <a href="https://discord.gg/jsYVk5JBxq">
      <img src="https://img.shields.io/badge/Discord-7289da?style=for-the-badge&logo=discord&logoColor=white" alt="Discord" />
    </a> 
    <a href="https://ko-fi.com/community_scripts">
      <img src="https://img.shields.io/badge/Support-FF5F5F?style=for-the-badge&logo=ko-fi&logoColor=white" alt="Donate" />
    </a>
    <a href="https://github.com/community-scripts/ProxmoxVE/blob/main/.github/CONTRIBUTOR_AND_GUIDES/CONTRIBUTING.md">
      <img src="https://img.shields.io/badge/Contribute-ff4785?style=for-the-badge&logo=git&logoColor=white" alt="Contribute" />
    </a> 
    <a href="https://github.com/community-scripts/ProxmoxVE/blob/main/.github/CONTRIBUTOR_AND_GUIDES/USER_SUBMITTED_GUIDES.md">
      <img src="https://img.shields.io/badge/Guides-0077b5?style=for-the-badge&logo=read-the-docs&logoColor=white" alt="Guides" />
    </a> 
    <a href="https://github.com/community-scripts/ProxmoxVE/blob/main/CHANGELOG.md">
      <img src="https://img.shields.io/badge/Changelog-6c5ce7?style=for-the-badge&logo=git&logoColor=white" alt="Changelog" />
    </a>
  </p>
</div>

# Proxmox VE Helper Scripts

## FreePBX LXC
FreePBX is a free, open-source web-based graphical user interface that simplifies the deployment and management of Asterisk® the leading open-source telephony engine. By providing an intuitive dashboard for configuring trunks, extensions, inbound and outbound routes, IVR menus, call queues, voicemail, and conference bridges, FreePBX enables organizations of any size to build a fully featured private branch exchange (PBX) without deep Linux or telephony expertise. Its modular architecture and commercial add-on ecosystem allow easy expansion into advanced features such as SMS integration, call center reporting, and high-availability clustering, while a vibrant global community ensures regular updates, security patches, and peer support. FreePBX thus offers a cost-effective, scalable, and enterprise-grade telephony solution for businesses seeking flexible, software-driven voice communications.
```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/s0nt3k/scripts/refs/heads/main/proxmox-helper-scripts/deploy/freepbx_lxc.sh)"
```

## Nextcloud VM
Nextcloud is an open‑source, self‑hosted platform for file synchronization, sharing, and collaboration that gives individuals and organizations full control over their data. By installing Nextcloud on a private server or trusted hosting environment, users can store documents, photos, calendars, contacts, and more behind their own firewall rather than relying on third‑party cloud services. Its web interface and native desktop and mobile clients enable seamless access and automatic synchronization across devices, while built‑in collaboration tools—such as real‑time document editing, contacts and calendar sharing, chat, and video conferencing—foster teamwork without compromising security. With a robust ecosystem of plugins and integrations, Nextcloud can be extended to include features like end‑to‑end encryption, two‑factor authentication, workflow automation, and compliance reporting, making it a flexible, privacy‑centric alternative to proprietary cloud solutions.
```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/s0nt3k/scripts/refs/heads/main/proxmox-helper-scripts/deploy/nextcloud_vm.sh)"
```

## osTicket
osTicket is an open-source support ticket system that helps small businesses and organizations streamline customer service operations by managing, organizing, and archiving support requests. It allows users to create tickets via email, web forms, or API, and routes them to the appropriate department or staff member for resolution. With features like customizable ticket workflows, automated responses, internal notes, SLA enforcement, and a built-in knowledge base, osTicket enables teams to deliver efficient and professional customer support. Its web-based interface is user-friendly, and its modular design makes it easy to adapt and scale to meet a variety of business needs.
```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/s0nt3k/Scripts/refs/heads/main/Proxmox%20Helper%20Scripts/install-osticket-lxc.sh)"
```
