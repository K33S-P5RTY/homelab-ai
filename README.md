<p align="center">
    <img src="https://raw.githubusercontent.com/K33S-P5RTY/homelab-ai/refs/heads/main/banner.webp"
        width="50%">
</p>

![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04-E95420?logo=ubuntu&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-✓-2496ED?logo=docker&logoColor=white)
![Ollama](https://img.shields.io/badge/Ollama-✓-3D5AFE?logo=ollama&logoColor=white)
![Automated](https://img.shields.io/badge/Script-Fully_Automated-4CAF50)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
![Last Updated](https://img.shields.io/badge/Last%20Updated-January%202026-blue)

#### A zero-frills AI stack for developers who’d rather automate than babysit infrastructure. This repository contains **one opinionated Bash script**.

It takes a **fresh Ubuntu 24.04 LTS system** and converts it into a **locked-down, LAN-only, private AI server** with zero interaction. 

No menus. No prompts. No “are you sure?”. The script assumes you’re an adult and acts accordingly.

You run it once.  
It configures everything.  
You disappear until it’s done.

## What the script actually sets up
| Component | Purpose | Why you didn’t want to do this yourself |
|---------|--------|------------------------------------------|
| **Ollama** | Local LLM runtime | Compiling, tuning, and retrying would ruin your evening |
| **OpenWebUI** | Web UI for chatting with models | Writing a UI was never the plan |
| **AgentZero** | Autonomous agents | Because clicking buttons is inefficient |
| **Docker** | Container isolation | Dependency hell is not character-building |
| **Nginx** | Reverse proxy + TLS | Browsers complain, attackers don’t get in |
| **Self-signed TLS** | Encrypted traffic | Costs nothing, works everywhere |
| **UFW** | Firewall | The internet is denied by default |
| **Fail2Ban** | SSH protection | Bots get banned faster than you notice them |
| **systemd-resolved** | DNS over TLS (Quad9) | Your ISP doesn’t need to know |

No wikis. No post-install steps. No guessing.

- **Single-command deployment** - Complete AI stack installation
- **Hardened security** - UFW firewall, Fail2Ban, and SSL encryption
- **Automatic network configuration** - Uses current IP with router DHCP reservation
- **Containerized services** - Docker-based isolation for all AI components
- **Self-signed SSL certificates** - Automatic HTTPS configuration
- **Systemd services** - Managed auto-start for all components
- **Backup system** - Automatic backup of critical network files
- **Resource monitoring** - Pre-installation system resource checks
- **Beautiful terminal output** - Color-coded logs and ASCII art


You need:
- Ubuntu 24.04 LTS (fresh install recommended)
- Minimum 8GB RAM (16GB+ recommended for larger models)
- Minimum 50GB free disk space
- Stable internet connection
- Sudo/root access





## Installation

1. **Download the script**
```bash
wget https://raw.githubusercontent.com/yourusername/homelab-ai-setup/main/homelab-setup.sh
```

2. **Make executable**
```bash
chmod +x homelab-setup.sh
```

3. **Run as root**
```bash
sudo ./homelab-setup.sh
```


The script automatically detects and uses your current network configuration. For custom settings, edit these variables before running:

```bash
# Script Configuration (edit before running)
SCRIPT_VERSION="5.0.0"
AI_STACK_DIR="/opt/ai-stack"  # Change installation directory
RESOLVER_STUB="127.0.0.53"    # DNS resolver
```

##  Reference
```nginx
location / {
    proxy_pass http://127.0.0.1:3000;  # OpenWebUI
}

location /agent/ {
    proxy_pass http://127.0.0.1:8000/;  # Agent Zero
}

location /ollama/ {
    proxy_pass http://127.0.0.1:11434/;  # Ollama API
}

location /health {
    return 200 "healthy\n";  # Health check
}
```


### Management Commands

```bash
# Check service status
systemctl status ollama ai-stack nginx

# View logs
journalctl -u ollama -u nginx -u docker

# Test connectivity
curl -k https://localhost/health

# Full system check
/usr/local/bin/check-ai-status
```



#### Disclaimer
This script is provided as-is. Always test in a non-production environment first. The maintainers are not responsible for any system instability or security issues resulting from its use.

