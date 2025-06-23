## FreePBX LXC
FreePBX is a free, open-source web-based graphical user interface that simplifies the deployment and management of Asterisk® the leading open-source telephony engine. By providing an intuitive dashboard for configuring trunks, extensions, inbound and outbound routes, IVR menus, call queues, voicemail, and conference bridges, FreePBX enables organizations of any size to build a fully featured private branch exchange (PBX) without deep Linux or telephony expertise. Its modular architecture and commercial add-on ecosystem allow easy expansion into advanced features such as SMS integration, call center reporting, and high-availability clustering, while a vibrant global community ensures regular updates, security patches, and peer support. FreePBX thus offers a cost-effective, scalable, and enterprise-grade telephony solution for businesses seeking flexible, software-driven voice communications.

---

```
bash -c "$(curl -fsSL )"
```

## FIREWALL SETTINGS

#### PORT FORWARDING SETTINGS TABLE

| APPLICATION | ORGINAL PORT | PROTOCOL | FWD TO PORT |
| :---------: | :----------: | :------: | :---------: |
| SIP         | 5060         | Both     | 5060        |
| RTP         | 10000-20000  | UDP      | 10000-20000 |
| WebRTC      | 8001-8003    | TCP      | 8001-8003   |
| IAX2        | 4569         | UDP      | 4569        |
| AMI         | 5038         | TCP      | 5038        |
| MySQL       | 6033         | TCP      | 3306        |
| Alt1-SIP    | 5080         | Both     | 5080        |
| Alt2-SIP    | 42872        | UDP      | 42872       |

| ABBREV | ACCRONYM | DISCRIPTION |
| :-----: | -------- | ----------- |
| **UDP** | User Datagram Protocol | Used for fast, connectionless communication where speed is more important than reliability like video streaming, voice calls, or online gaming. |
| **TCP** | Transmission Control Protocol | Used for reliable, connection-based communication that ensures all data arrives in order like loading websites, sending emails, or downloading files. |
