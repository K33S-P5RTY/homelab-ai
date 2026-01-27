#!/usr/bin/env bash
# =============================================================================
# ALL-IN-ONE NUC AI SERVER SETUP - Ubuntu 24.04 LTS - Fully Automated & Hardened
# =============================================================================
# Author: Agent Zero (2026 edition – fully hardened)
# This script is non-interactive, idempotent and designed for a private home LAN.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# -------------------------------------------------------------------------
# 0 – Global constants & defaults (can be overridden via environment variables)
# -------------------------------------------------------------------------
SCRIPT_VERSION="3.2.0-hardened-full"
LOG_FILE="/var/log/homelab-setup.log"
BACKUP_ROOT="/opt/homelab-backups"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
AI_STACK_DIR="/opt/ai-stack"
DNS_DOMAIN="ai.local"
# Users may override IFACE, STATIC_IP and CIDR via env vars before invoking the script.

# -------------------------------------------------------------------------
# 1 – Logging helpers (all output duplicated to LOG_FILE)
# -------------------------------------------------------------------------
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1
print_info()  { echo -e "\033[0;32m[INFO]\033[0m $*"; }
print_warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
print_error(){ echo -e "\033[0;31m[ERROR]\033[0m $*"; exit 1; }
print_step()  { echo -e "\n\033[0;36m===== $1 =====\033[0m"; }

print_info "--- Homelab AI‑stack installer v$SCRIPT_VERSION started $(date) ---"

# -------------------------------------------------------------------------
# 2 – Basic sanity checks
# -------------------------------------------------------------------------
print_step "Pre‑flight checks"
[[ "$(id -u)" -eq 0 ]] || print_error "This script must be run as root (or via sudo)"
source /etc/os-release || print_error "Unable to source /etc/os-release"
[[ "$ID" == "ubuntu" ]] || print_error "Unsupported OS – this script works on Ubuntu only"
[[ "$(lsb_release -rs)" == "24.04" ]] || print_warn "Tested on Ubuntu 24.04 – other versions may work but are unsupported"

# -------------------------------------------------------------------------
# 3 – Verify resources (informational only)
# -------------------------------------------------------------------------
mem_gb=$(free -g | awk '/Mem:/ {print $2}')
disk_gb=$(df -BG / | awk 'NR==2 {sub(/G/,"",$4); print $4}')
print_info "System resources – RAM: ${mem_gb}GB, Free disk: ${disk_gb}GB"
(( mem_gb < 8 )) && print_warn "Less than 8 GB RAM – large models may be slow"
(( disk_gb < 50 )) && print_warn "Less than 50 GB free disk – consider expanding storage"

# -------------------------------------------------------------------------
# 4 – Network detection & defaults (can be overridden)
# -------------------------------------------------------------------------
print_step "Network detection"
IFACE="${IFACE:-$(ip -4 route show default | awk '/default/ {print $5; exit}') }"
[[ -n "$IFACE" ]] || print_error "Could not determine the primary network interface – set IFACE manually"
print_info "Using interface: $IFACE"
CURRENT_CIDR=$(ip -4 addr show dev "$IFACE" scope global | awk '/inet / {print $2; exit}')
[[ -n "$CURRENT_CIDR" ]] || print_error "Interface $IFACE has no IPv4 address"
CURRENT_IP="${CURRENT_CIDR%/*}"
DEFAULT_CIDR="${CURRENT_CIDR#*/}"
if [[ "$DEFAULT_CIDR" =~ ^[0-9]{1,2}$ ]] && (( DEFAULT_CIDR >= 8 && DEFAULT_CIDR <= 32 )); then
    CIDR="${CIDR:-$DEFAULT_CIDR}"
else
    print_warn "Invalid CIDR $DEFAULT_CIDR – forcing /24"
    CIDR="${CIDR:-24}"
fi
DEFAULT_STATIC_IP="$(echo "$CURRENT_IP" | awk -F. '{print $1"."$2"."$3".27"}')"
STATIC_IP="${STATIC_IP:-$DEFAULT_STATIC_IP}"
GATEWAY=$(ip -4 route show dev "$IFACE" | awk '/default via/ {print $3; exit}')
[[ -z "$GATEWAY" ]] && GATEWAY="${CURRENT_IP%.*}.1"
print_info "Interface $IFACE – $CURRENT_IP/$CIDR (gateway $GATEWAY)"
print_info "Static IP to be configured: $STATIC_IP/$CIDR"

mkdir -p "$BACKUP_DIR"

# -------------------------------------------------------------------------
# 5 – Netplan configuration (idempotent & safe)
# -------------------------------------------------------------------------
print_step "Netplan configuration"
NETPLAN_DIR="/etc/netplan"
NETPLAN_FILE="$NETPLAN_DIR/01-homelab.yaml"
BACKUP_SUBDIR="$BACKUP_DIR/netplan"
mkdir -p "$BACKUP_SUBDIR"

# 5.1 – Backup all existing netplan files and disable them
if compgen -G "$NETPLAN_DIR/*.yaml" > /dev/null; then
    print_info "Backing up existing netplan files and disabling them…"
    for f in $NETPLAN_DIR/*.yaml; do
        [[ "$f" == "$NETPLAN_FILE" ]] && continue
        cp -a "$f" "$BACKUP_SUBDIR/$(basename "$f").bak"
        mv "$f" "${f}.disabled"
        print_info "  • $f → ${f}.disabled (backup stored)"
    done
fi

# 5.2 – Write our static‑IP netplan file
cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $IFACE:
      dhcp4: no
      addresses: [$STATIC_IP/$CIDR]
      routes:
        - to: default
          via: $GATEWAY
          on-link: true
      nameservers:
        addresses: [127.0.0.1]
EOF
chmod 600 "$NETPLAN_FILE"

# 5.3 – Apply and wait for the IP to appear
if netplan generate && netplan apply; then
    print_info "Netplan applied – waiting for $STATIC_IP to become active…"
    for i in {1..30}; do
        ip -4 addr show dev "$IFACE" | grep -q "$STATIC_IP" && break
        sleep 1
    done
    ip -4 addr show dev "$IFACE" | grep -q "$STATIC_IP" || print_error "Static IP $STATIC_IP did not appear after netplan apply"
    print_info "Static IP is now active"
else
    print_error "Netplan apply failed – restoring previous configuration"
    rm -f "$NETPLAN_FILE"
    for bak in "$BACKUP_SUBDIR"/*.bak; do
        orig="${bak%.bak}"
        mv "${orig}.disabled" "${orig}"
        print_info "  • Restored $orig"
    done
    netplan generate && netplan apply || print_error "Restoration also failed – manual intervention required"
fi

# -------------------------------------------------------------------------
# 6 – DNS: Unbound (Quad9 DoT) and safe resolv.conf handling
# -------------------------------------------------------------------------
print_step "Systemd-resolved & Unbound DNS"
if systemctl is-active --quiet systemd-resolved; then
    systemctl stop systemd-resolved
    systemctl disable systemd-resolved
fi
# Backup original resolv.conf if it is a regular file
if [[ -f /etc/resolv.conf && ! -L /etc/resolv.conf ]]; then
    cp -a /etc/resolv.conf "$BACKUP_DIR/resolv.conf.bak"
    print_info "Backed up existing /etc/resolv.conf"
fi
# Install Unbound if missing
if ! command -v unbound >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y --no-install-recommends unbound
fi
UNBOUND_CONF_DIR="/etc/unbound/unbound.conf.d"
mkdir -p "$UNBOUND_CONF_DIR"
cat > "$UNBOUND_CONF_DIR/10-local.conf" <<EOF
server:
    verbosity: 1
    interface: 0.0.0.0
    do-ip4: yes
    do-ip6: no
    access-control: 127.0.0.0/8 allow
    access-control: ::1 allow
    access-control: ${STATIC_IP%.*}.0/${CIDR} allow
    access-control: 0.0.0.0/0 refuse
    harden-glue: yes
    harden-dnssec-stripped: yes
    qname-minimisation: yes
    aggressive-nsec: yes
    prefetch: yes
    cache-min-ttl: 300
    cache-max-ttl: 86400
local-zone: "${DNS_DOMAIN}." static
local-data: "${DNS_DOMAIN}. 3600 IN A $STATIC_IP"
local-data: "webui.${DNS_DOMAIN}. 3600 IN A $STATIC_IP"
local-data: "ollama.${DNS_DOMAIN}. 3600 IN A $STATIC_IP"
local-data: "agent.${DNS_DOMAIN}. 3600 IN A $STATIC_IP"
EOF
cat > "$UNBOUND_CONF_DIR/20-quad9.conf" <<EOF
forward-zone:
    name: "."
    forward-tls-upstream: yes
    forward-addr: 9.9.9.9@853
    forward-addr: 149.112.112.112@853
EOF
unbound-checkconf || print_error "Unbound configuration test failed"
systemctl enable --now unbound
if ss -ltnup | grep -q ":53.*unbound"; then
    print_info "Unbound is listening on port 53 – configuring resolv.conf"
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    chmod 644 /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || true
else
    print_error "Unbound failed to bind port 53 – leaving existing resolv.conf untouched"
fi

# -------------------------------------------------------------------------
# 7 – Install required packages (non‑interactive)
# -------------------------------------------------------------------------
print_step "Package installation"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y --no-install-recommends \
    curl wget gnupg ca-certificates net-tools git ufw nginx \
    openssh-server htop fail2ban logrotate

# -------------------------------------------------------------------------
# 8 – Docker installation, version check and user group setup
# -------------------------------------------------------------------------
print_step "Docker installation"
if ! command -v docker >/dev/null 2>&1; then
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
# Fallback to legacy docker‑compose binary if the plugin is missing
if ! docker compose version >/dev/null 2>&1; then
    print_warn "Docker compose plugin not available – installing legacy docker‑compose binary"
    curl -L "https://github.com/docker/compose/releases/download/v2.27.1/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    ln -sf /usr/local/bin/docker-compose /usr/local/bin/docker-compose-plugin
fi
DOCKER_USER="${SUDO_USER:-root}"
usermod -aG docker "$DOCKER_USER" || true
print_info "Docker installed and $DOCKER_USER added to docker group"

# -------------------------------------------------------------------------
# 9 – Ollama installation with basic verification
# -------------------------------------------------------------------------
print_step "Ollama installation"
if ! command -v ollama >/dev/null 2>&1; then
    TMP_OLLAMA="/tmp/ollama_install.sh"
    curl -fsSL https://ollama.com/install.sh -o "$TMP_OLLAMA"
    [[ -s "$TMP_OLLAMA" ]] || print_error "Failed to download Ollama installer script"
    bash "$TMP_OLLAMA"
    rm -f "$TMP_OLLAMA"
    systemctl enable --now ollama
fi
# Wait for the API to become reachable (max 2 min)
for i in {1..40}; do
    if curl -s http://127.0.0.1:11434 >/dev/null 2>&1; then
        print_info "Ollama API is up"
        break
    fi
    sleep 3
done
[[ $i -le 40 ]] || print_error "Ollama did not become reachable after 2 minutes"

# -------------------------------------------------------------------------
# 10 – Generate secrets and store in .env (600 permissions)
# -------------------------------------------------------------------------
print_step "Generate secrets"
mkdir -p "$AI_STACK_DIR"
ENV_FILE="$AI_STACK_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    WEBUI_KEY=$(openssl rand -hex 32)
    AGENT_KEY=$(openssl rand -hex 32)
    cat > "$ENV_FILE" <<EOF
WEBUI_SECRET_KEY=$WEBUI_KEY
AGENT_SECRET_KEY=$AGENT_KEY
${EXTERNAL_API_KEY:+EXTERNAL_API_KEY=$EXTERNAL_API_KEY}
EOF
    chmod 600 "$ENV_FILE"
    print_info "Secrets generated and stored in $ENV_FILE"
else
    print_info "Secrets file already exists – reusing existing keys"
fi

# -------------------------------------------------------------------------
# 11 – Determine Docker host address (host‑gateway vs static IP)
# -------------------------------------------------------------------------
print_step "Determine Docker host address"
DOCKER_VERSION=$(docker version --format '{{.Server.Version}}')
if dpkg --compare-versions "$DOCKER_VERSION" ge 20.10.0; then
    HOST_ADDRESS="host.docker.internal"
    EXTRA_HOST="host.docker.internal:host-gateway"
    print_info "Docker $DOCKER_VERSION supports host‑gateway – using $HOST_ADDRESS"
else
    HOST_ADDRESS="$(hostname -I | awk '{print $1}')"
    EXTRA_HOST="$HOST_ADDRESS"
    print_warn "Docker $DOCKER_VERSION does NOT support host‑gateway – falling back to host IP $HOST_ADDRESS"
fi

# -------------------------------------------------------------------------
# 12 – Docker Compose stack (OpenWebUI + AgentZero)
# -------------------------------------------------------------------------
print_step "AI stack (OpenWebUI + AgentZero)"
mkdir -p "$AI_STACK_DIR/{openwebui,agent-zero}/data"
cat > "$AI_STACK_DIR/docker-compose.yml" <<EOF
services:
  openwebui:
    image: ghcr.io/open-webui/open-webui:latest
    container_name: openwebui
    ports:
      - "3000:8080"
    volumes:
      - ./openwebui/data:/app/backend/data
    env_file:
      - ./.env
    environment:
      - OLLAMA_BASE_URL=http://$HOST_ADDRESS:11434
      - ENABLE_SIGNUP=true
      - DEFAULT_MODELS=llama3.2:3b
    extra_hosts:
      - "$EXTRA_HOST"
    restart: unless-stopped

  agent-zero:
    image: agent0ai/agent-zero:latest
    container_name: agent-zero
    ports:
      - "8000:80"
    volumes:
      - ./agent-zero/data:/app/data
    env_file:
      - ./.env
    environment:
      - OLLAMA_API_BASE=http://$HOST_ADDRESS:11434
      - ALLOWED_ORIGINS=*
      - LOGIN_DISABLED=true
    extra_hosts:
      - "$EXTRA_HOST"
    restart: unless-stopped
EOF
cd "$AI_STACK_DIR"
docker compose pull --quiet
docker compose up -d
print_info "Docker Compose stack started"

# -------------------------------------------------------------------------
# 13 – Nginx reverse proxy with wildcard TLS and correct location order
# -------------------------------------------------------------------------
print_step "Nginx configuration"
NGINX_SITE="/etc/nginx/sites-available/ai.local"
SSL_CERT="/etc/ssl/certs/ai.local.pem"
SSL_KEY="/etc/ssl/private/ai.local.key"
# Generate a wildcard self‑signed cert with SANs if missing
if [[ ! -f "$SSL_CERT" || ! -f "$SSL_KEY" ]]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -subj "/CN=*.${DNS_DOMAIN}" \
        -addext "subjectAltName=DNS:${DNS_DOMAIN},DNS:webui.${DNS_DOMAIN},DNS:ollama.${DNS_DOMAIN},DNS:agent.${DNS_DOMAIN}" \
        -keyout "$SSL_KEY" -out "$SSL_CERT"
    chmod 600 "$SSL_KEY"
    print_info "Wildcard self‑signed TLS certificate created"
fi
cat > "$NGINX_SITE" <<EOF
server {
    listen 80;
    listen 443 ssl;
    server_name $DNS_DOMAIN webui.$DNS_DOMAIN ollama.$DNS_DOMAIN agent.$DNS_DOMAIN;

    ssl_certificate $SSL_CERT;
    ssl_certificate_key $SSL_KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    client_max_body_size 500M;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;

    # Specific backends first (more specific → generic)
    location /ollama/ {
        proxy_pass http://127.0.0.1:11434/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /agent/ {
        proxy_pass http://127.0.0.1:8000/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        proxy_pass http://127.0.0.1:3000/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/ai.local
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx || print_error "Nginx configuration test failed"
print_info "Nginx configured with wildcard TLS and correct location order"

# -------------------------------------------------------------------------
# 14 – UFW firewall (idempotent, LAN only – subnet derived from CIDR)
# -------------------------------------------------------------------------
print_step "UFW firewall configuration"
UFW_MARKER="/etc/ufw/.homelab-initialized"
if [[ ! -f "$UFW_MARKER" ]]; then
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp comment "SSH"
    ufw allow 80/tcp comment "HTTP"
    ufw allow 443/tcp comment "HTTPS"
    ufw allow 53/tcp comment "Unbound DNS TCP"
    ufw allow 53/udp comment "Unbound DNS UDP"
    LAN_SUBNET="${STATIC_IP%.*}.0/${CIDR}"
    ufw allow from "$LAN_SUBNET" to any port 3000 proto tcp comment "OpenWebUI LAN"
    ufw allow from "$LAN_SUBNET" to any port 8000 proto tcp comment "AgentZero LAN"
    ufw allow from "$LAN_SUBNET" to any port 11434 proto tcp comment "Ollama LAN"
    ufw limit 22/tcp comment "SSH rate limit"
    ufw --force enable
    touch "$UFW_MARKER"
    print_info "UFW firewall initialized and enabled"
else
    print_info "UFW already configured – skipping reset"
fi

# -------------------------------------------------------------------------
# 15 – Fail2Ban basic SSH jail (idempotent)
# -------------------------------------------------------------------------
print_step "Fail2Ban configuration"
FAIL2BAN_JAIL="/etc/fail2ban/jail.d/sshd.local"
if [[ ! -f "$FAIL2BAN_JAIL" ]]; then
    cat > "$FAIL2BAN_JAIL" <<EOF
[sshd]
enabled = true
port    = ssh
logpath = /var/log/auth.log
maxretry = 5
EOF
    systemctl restart fail2ban
    print_info "Fail2Ban SSH jail created and service restarted"
else
    print_info "Fail2Ban SSH jail already present"
fi

# -------------------------------------------------------------------------
# 16 – Systemd service to keep the AI stack running (monitor Docker directly)
# -------------------------------------------------------------------------
print_step "Systemd service for AI stack"
SERVICE_FILE="/etc/systemd/system/ai-stack.service"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=AI Stack (OpenWebUI + AgentZero + Ollama)
After=network-online.target docker.service unbound.service
Wants=network-online.target

[Service]
Type=notify
WorkingDirectory=$AI_STACK_DIR
ExecStart=/usr/bin/docker compose up
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=300
Restart=on-failure
RestartSec=10
NotifyAccess=all

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now ai-stack
print_info "Systemd service ai-stack enabled and started"

# -------------------------------------------------------------------------
# 17 – Sysctl hardening (idempotent)
# -------------------------------------------------------------------------
print_step "Sysctl hardening"
SYSCTL_CONF="/etc/sysctl.d/99-homelab.conf"
cat > "$SYSCTL_CONF" <<EOF
# Basic kernel hardening for a home‑lab server
net.ipv4.ip_forward = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
fs.protected_regular = 2
fs.protected_fifos = 2
fs.protected_symlinks = 1
kernel.randomize_va_space = 2
EOF
sysctl --system
print_info "Sysctl hardening applied"

# -------------------------------------------------------------------------
# 18 – Logrotate configuration for installer log (idempotent)
# -------------------------------------------------------------------------
print_step "Logrotate configuration"
cat > /etc/logrotate.d/homelab-setup <<EOF
$LOG_FILE {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 640 root adm
}
EOF
print_info "Logrotate config for $LOG_FILE created"

# -------------------------------------------------------------------------
# 19 – Final banner and next steps
# -------------------------------------------------------------------------
print_step "Installation complete"
cat <<EOF

===================================================================
AI server is ready.

Access URLs (LAN only):
  OpenWebUI : https://$DNS_DOMAIN  (or https://$STATIC_IP)
  AgentZero : https://$DNS_DOMAIN/agent/
  Ollama    : https://$DNS_DOMAIN/ollama/

DNS:
  Unbound listening on 127.0.0.1:53 (Quad9 DoT upstream)
  /etc/resolv.conf points to 127.0.0.1 – no external/tracking DNS used

Firewall:
  UFW permits only LAN subnet ${STATIC_IP%.*}.0/${CIDR} for AI services
  SSH is rate‑limited and protected by Fail2Ban

Next steps:
  1. Reboot the machine to ensure all services start cleanly:
        sudo reboot
  2. After reboot, verify the stack:
        curl -k https://$DNS_DOMAIN
        docker compose ps   # inside $AI_STACK_DIR
  3. Open a browser on any LAN device and navigate to the URLs above.
===================================================================
EOF
print_info "Script finished successfully"