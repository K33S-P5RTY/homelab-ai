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
wget https://raw.githubusercontent.com/K33S-P5RTY/homelab-ai/refs/heads/main/ai-prod-setup-v8.sh

wget https://raw.githubusercontent.com/K33S-P5RTY/homelab-ai/refs/heads/main/homelab.sh

```

2. **Make executable**
```bash
chmod +x ai-prod-setup-v8.sh
```

3. **Run as root**
```bash
sudo ./ai-prod-setup-v8.sh
```

The script automatically detects and uses your current network configuration. For custom settings, edit these variables before running:


### Management Commands

```bash
=============================================================================
🎉 ENTERPRISE PRODUCTION DEPLOYMENT SUCCESSFUL
=============================================================================

ACCESS URLS:
  • AI Dashboard:  https://$PRIMARY_IP (or https://$HOSTNAME_FQDN)
  • Grafana:       https://$PRIMARY_IP/grafana/
  • Prometheus:    https://$PRIMARY_IP/prometheus/
  • Health Check:  https://$PRIMARY_IP/health

CREDENTIALS:
  • Grafana User:     admin
  • Grafana Password: $GRAFANA_PASSWORD
  • Prometheus Auth:  admin / $PROMETHEUS_PASSWORD

INTERNAL SERVICES:
  • OpenWebUI:    http://127.0.0.1:3000
  • Ollama API:   http://127.0.0.1:11434
  • Prometheus:   http://127.0.0.1:9090
  • Grafana:      http://127.0.0.1:3001

SECURITY FEATURES:
  ✅ Firewall:      UFW with rate limiting
  ✅ SSL:           Internal PKI with 10-year validity
  ✅ DNS:           Quad9 with DNSSEC validation
  ✅ Hardening:     Kernel, Docker, Nginx hardened
  ✅ Fail2ban:      Intrusion prevention enabled
  ✅ Secrets:       Secure secrets management
  ✅ Health Checks: All services monitored
  ✅ Backup:        Daily automated backups at 2 AM
  ✅ Rollback:      Automatic rollback on failure
  ✅ Monitoring:    Prometheus + Grafana + Node Exporter

⚠️  CRITICAL: INSTALL ROOT CA
  Your browser will show a "Not Secure" warning until you trust the CA.
  File Location: $SSL_DIR/ca.crt
  
  • Mac/Phone:   Install in Settings > General > VPN & Device Management
  • Linux:       Copy to /usr/local/share/ca-certificates/ and run update-ca-certificates
  • Windows:     Install to "Trusted Root Certification Authorities"

MAINTENANCE:
  • View Logs:      tail -f $LOG_FILE
  • Restart AI:     cd $AI_STACK_DIR && docker compose restart
  • Update AI:      cd $AI_STACK_DIR && docker compose pull && docker compose up -d
  • Manual Backup:  /usr/local/bin/ai-stack-backup.sh
  • View Backups:   ls -la $BACKUP_DIR

MONITORING:
  • Grafana Dashboard: https://$PRIMARY_IP/grafana/
  • Prometheus Metrics: https://$PRIMARY_IP/prometheus/
  • Node Exporter: http://127.0.0.1:9100/metrics

```



#### Disclaimer
This script is provided as-is. Always test in a non-production environment first. The maintainers are not responsible for any system instability or security issues resulting from its use.

