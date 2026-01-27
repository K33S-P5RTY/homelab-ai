[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Ubuntu 24.04](https://img.shields.io/badge/Ubuntu-24.04-orange?logo=ubuntu&logoColor=white)](https://ubuntu.com)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
![GitHub stars](https://img.shields.io/github/stars/K33S-P5RTY/homelab-ai?style=social)
![GitHub forks](https://img.shields.io/github/forks/K33S-P5RTY/homelab-ai?style=social)
![Last Updated](https://img.shields.io/badge/Last%20Updated-January%202026-blue)

# Homelab AI Stack Setup

Fully automated Bash script that turns a fresh Ubuntu 24.04 LTS machine into a hardened private AI server for your home LAN.

Installs:
- Ollama
- OpenWebUI
- AgentZero
- Docker
- Nginx reverse proxy with wildcard self-signed cert
- UFW (LAN-only access to AI services)
- Fail2Ban (SSH protection)
- systemd-resolved with Quad9 DoT upstream

Local domain overrides via `/etc/hosts` → `ai.local`, `webui.ai.local`, `ollama.ai.local`, `agent.ai.local` all point to the static IP.

## Features
- Idempotent → safe to re-run
- Non-interactive → override via env vars (`IFACE`, `STATIC_IP`, `CIDR`, `DNS_DOMAIN`)
- Automatic netplan rollback if connectivity breaks after static IP apply
- Static IP collision check via arping
- Kernel hardening (Docker compatible)
- Minimal dependencies, clear logging

## Requirements
- Ubuntu 24.04 LTS (clean install recommended)
- Root/sudo access
- ≥8 GB RAM, ≥50 GB free disk (script warns if lower)
- Internet connection during first run

## Installation
```bash
# Download
curl -O https://raw.githubusercontent.com/K33S-P5RTY/homelab-ai/main/setup.sh

# Make executable
chmod +x setup.sh

# Run
sudo ./setup.sh

# After finish → reboot
sudo reboot
