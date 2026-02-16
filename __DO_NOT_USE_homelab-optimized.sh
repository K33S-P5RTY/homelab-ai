#!/usr/bin/env bash
# =============================================================================
# ALL-IN-ONE - AI SERVER SETUP - Ubuntu 24.04 LTS - Fully Automated & Hardened
# =============================================================================

# ASCII Art Header
cat << 'EOF'

EOF

set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# 0 – Global constants & defaults
# -----------------------------------------------------------------------------
SCRIPT_VERSION="5.0.0-simplified"
LOG_FILE="/var/log/homelab-setup.log"
BACKUP_ROOT="/opt/homelab-backups"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
AI_STACK_DIR="/opt/ai-stack"
RESOLVER_STUB="127.0.0.53"

# -----------------------------------------------------------------------------
# 1 – Logging
# -----------------------------------------------------------------------------
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

print_info()  { echo -e "\033[0;32m[INFO]\033[0m $*"; }
print_warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
print_error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; exit 1; }
print_step()  { echo -e "\n\033[0;36m===== $1 =====\033[0m"; }

print_info " ##########################"
print_info " Homelab AI-stack installer [v$SCRIPT_VERSION] started [$(date)]"
print_info " ##########################"
# -----------------------------------------------------------------------------
# 2 – Pre-flight checks & backup existing network config
# -----------------------------------------------------------------------------
print_step "Pre-flight checks & backup"

[[ "$(id -u)" -eq 0 ]] || print_error "Must run as root (or sudo)"
source /etc/os-release || print_error "Cannot source /etc/os-release"
[[ "$ID" == "ubuntu" ]] || print_error "Only Ubuntu is supported"

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Backup critical network files
backup_network_configs() {
    print_info "Backing up existing network configurations..."
    
    # Backup hosts and resolv.conf
    cp -a /etc/hosts "$BACKUP_DIR/hosts.bak" 2>/dev/null || true
    cp -a /etc/resolv.conf "$BACKUP_DIR/resolv.conf.bak" 2>/dev/null || true
    
    # Backup cloud-init if present
    if [[ -d /etc/cloud ]]; then
        mkdir -p "$BACKUP_DIR/cloud-init"
        cp -a /etc/cloud/cloud.cfg.d/* "$BACKUP_DIR/cloud-init/" 2>/dev/null || true
    fi
    
    print_info "Network backups saved to $BACKUP_DIR"
}

backup_network_configs

# Disable cloud-init network config if present
if [[ -d /etc/cloud/cloud.cfg.d ]]; then
    echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
    print_info "Disabled cloud-init network management"
fi

# -----------------------------------------------------------------------------
# 3 – Install essential tools
# -----------------------------------------------------------------------------
print_step "Installing essential tools"

apt-get update -qq
apt-get install -y net-tools iproute2 curl wget iputils-ping iputils-arping

# -----------------------------------------------------------------------------
# 4 – Resource check (informational)
# -----------------------------------------------------------------------------
mem_gb=$(free -g | awk '/Mem:/ {print $2}')
disk_gb=$(df -BG / | awk 'NR==2 {sub(/G/,"",$4); print $4}')
print_info "Resources – RAM: ${mem_gb}GB, Free disk: ${disk_gb}GB"
((mem_gb < 8))  && print_warn "Less than 8GB RAM – large models may be slow"
((disk_gb < 50)) && print_warn "Less than 50GB free – consider expanding storage"

# -----------------------------------------------------------------------------
# 5 – Network detection (current IP only – no changes)
# -----------------------------------------------------------------------------
print_step "Network detection"

IFACE=$(ip -4 route show default | awk '/default/ {print $5; exit}')
if [[ -z "$IFACE" ]]; then
    IFACE=$(ip link show | grep -oP '(eno|enp|ens|eth|wlan|wlp)\S+' | head -1)
fi
[[ -n "$IFACE" ]] || print_error "Cannot detect primary interface"

CURRENT_CIDR=$(ip -4 addr show dev "$IFACE" scope global | awk '/inet / {print $2; exit}')
[[ -n "$CURRENT_CIDR" ]] || print_error "No IPv4 address on $IFACE"

CURRENT_IP="${CURRENT_CIDR%/*}"
CIDR="${CURRENT_CIDR#*/}"
[[ "$CIDR" =~ ^[0-9]{1,2}$ ]] && ((CIDR >= 8 && CIDR <= 32)) || CIDR=24

GATEWAY=$(ip -4 route show dev "$IFACE" | awk '/default via/ {print $3; exit}')
[[ -z "$GATEWAY" ]] && GATEWAY="${CURRENT_IP%.*}.1"

STATIC_IP="$CURRENT_IP"
HOST_ADDRESS="$STATIC_IP"

print_info "Using current IP as static: $STATIC_IP/$CIDR on $IFACE (gateway $GATEWAY)"

# -----------------------------------------------------------------------------
# 6 – System hostname configuration
# -----------------------------------------------------------------------------
print_step "Hostname configuration"

CURRENT_HOSTNAME=$(hostname)
SHORT_HOSTNAME="${CURRENT_HOSTNAME%%.*}"

if [[ "$CURRENT_HOSTNAME" == "localhost" ]] || [[ -z "$SHORT_HOSTNAME" ]]; then
    SHORT_HOSTNAME="ai-server"
    hostnamectl set-hostname "$SHORT_HOSTNAME"
    print_info "Set hostname to $SHORT_HOSTNAME"
fi

# Simplified hosts file without domain mappings
cat > /etc/hosts <<EOF
127.0.0.1       localhost
$STATIC_IP      $SHORT_HOSTNAME

::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

print_info "Configured /etc/hosts with $STATIC_IP"

# -----------------------------------------------------------------------------
# 7 – Configure systemd-resolved (Quad9 DoT)
# -----------------------------------------------------------------------------
print_step "Configuring systemd-resolved"

cat > /etc/systemd/resolved.conf <<EOF
[Resolve]
DNS=9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net
DNSOverTLS=opportunistic
Cache=yes
DNSStubListener=yes
LLMNR=yes
MulticastDNS=yes
DNSSEC=allow-downgrade
ReadEtcHosts=yes
EOF

rm -f /etc/resolv.conf
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

systemctl restart systemd-resolved
systemctl enable systemd-resolved

timeout 5 dig @127.0.0.53 google.com >/dev/null 2>&1 || print_error "DNS resolution broken after resolved config"

print_info "systemd-resolved uses Quad9 DoT"

# -----------------------------------------------------------------------------
# 8 – Install Docker (single installation)
# -----------------------------------------------------------------------------
print_step "Docker installation"

if ! command -v docker >/dev/null 2>&1; then
    # Remove old versions
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
        apt-get remove -y "$pkg" 2>/dev/null || true
    done

    # Install prerequisites
    apt-get update
    apt-get install -y ca-certificates curl gnupg lsb-release

    # Add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # Add repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Install Docker
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    print_info "Docker installed"
else
    print_info "Docker already installed"
fi

# Configure Docker daemon
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "iptables": true,
  "ip-forward": true,
  "ip-masq": true,
  "dns": ["127.0.0.53"]
}
EOF

systemctl restart docker
systemctl enable docker

# Test Docker
if docker run --rm hello-world >/dev/null 2>&1; then
    print_info "Docker is working correctly"
else
    print_error "Docker test failed"
fi

# -----------------------------------------------------------------------------
# 9 – Install Ollama (single installation)
# -----------------------------------------------------------------------------
print_step "Ollama installation"

if ! command -v ollama >/dev/null 2>&1; then
    print_info "Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
    
    # Create Ollama systemd service
    cat > /etc/systemd/system/ollama.service <<EOF
[Unit]
Description=Ollama Service
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=ollama
Group=ollama
ExecStart=/usr/local/bin/ollama serve
Environment="OLLAMA_HOST=0.0.0.0"
Environment="OLLAMA_ORIGINS=*"
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable ollama
    systemctl start ollama
    
    print_info "Ollama installed and started"
else
    print_info "Ollama already installed"
    systemctl restart ollama 2>/dev/null || true
fi

# Wait for Ollama to start
print_info "Waiting for Ollama to start..."
sleep 10
if systemctl is-active --quiet ollama; then
    print_info "Ollama is running on http://$HOST_ADDRESS:11434"
else
    print_warn "Ollama service not active - check with: systemctl status ollama"
fi

# -----------------------------------------------------------------------------
# 10 – AI Stack Directory Setup
# -----------------------------------------------------------------------------
print_step "AI Stack Setup"

mkdir -p "$AI_STACK_DIR"/{openwebui,agent-zero}/data

# Create environment file
cat > "$AI_STACK_DIR/.env" <<EOF
# AI Stack Environment Variables
OLLAMA_BASE_URL=http://$HOST_ADDRESS:11434
HOSTNAME=$SHORT_HOSTNAME
TZ=$(cat /etc/timezone)
EOF

# -----------------------------------------------------------------------------
# 11 – Docker Compose stack
# -----------------------------------------------------------------------------
print_step "Deploying AI Stack"

# Simplified Docker Compose configuration
cat >"$AI_STACK_DIR/docker-compose.yml" <<EOF
version: '3.8'

services:
  openwebui:
    image: ghcr.io/open-webui/open-webui:latest
    container_name: openwebui
    ports:
      - "3000:8080"
    volumes:
      - ./openwebui/data:/app/backend/data
    environment:
      - OLLAMA_BASE_URL=http://$HOST_ADDRESS:11434
      - ENABLE_SIGNUP=true
      - DEFAULT_MODELS=llama3.2:3b
    restart: unless-stopped

  agent-zero:
    image: agent0ai/agent-zero:latest
    container_name: agent-zero
    ports:
      - "8000:80"
    volumes:
      - ./agent-zero/data:/app/data
    environment:
      - OLLAMA_API_BASE=http://$HOST_ADDRESS:11434
      - ALLOWED_ORIGINS=*
      - LOGIN_DISABLED=true
    restart: unless-stopped
EOF

cd "$AI_STACK_DIR"

# Pull images
print_info "Pulling Docker images..."
docker compose pull --quiet

# Start services
print_info "Starting AI stack..."
docker compose up -d

# Verify services
if docker compose ps | grep -q "Up"; then
    print_info "AI stack started successfully"
else
    print_error "AI stack failed to start"
fi

# -----------------------------------------------------------------------------
# 12 – Install and configure Nginx
# -----------------------------------------------------------------------------
print_step "Nginx reverse proxy"

# Install Nginx if not present
if ! command -v nginx >/dev/null 2>&1; then
    apt-get install -y nginx
fi

# Create SSL certificates
SSL_DIR="/etc/ssl/localhost"
mkdir -p "$SSL_DIR"
SSL_CERT="$SSL_DIR/fullchain.pem"
SSL_KEY="$SSL_DIR/privkey.pem"

if [[ ! -f "$SSL_CERT" ]]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -subj "/C=US/ST=State/L=City/O=Homelab/CN=localhost" \
        -addext "subjectAltName=IP:$STATIC_IP,DNS:localhost" \
        -keyout "$SSL_KEY" -out "$SSL_CERT"
    chmod 600 "$SSL_KEY"
    print_info "SSL certificates created"
fi

# Create simplified Nginx configuration
NGINX_SITE="/etc/nginx/sites-available/ai-server"
cat >"$NGINX_SITE" <<EOF
# AI Server Reverse Proxy
# Generated $(date)

# HTTP redirect to HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name $STATIC_IP $SHORT_HOSTNAME;
    return 301 https://\host\request_uri;
}

# HTTPS server
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $STATIC_IP $SHORT_HOSTNAME;
    
    ssl_certificate $SSL_CERT;
    ssl_certificate_key $SSL_KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    client_max_body_size 500M;
    
    # OpenWebUI
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \host;
        proxy_set_header X-Real-IP \remote_addr;
        proxy_set_header X-Forwarded-For \proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    
    # Ollama API
    location /ollama/ {
        proxy_pass http://127.0.0.1:11434/;
        proxy_set_header Host \host;
        proxy_set_header X-Real-IP \remote_addr;
        proxy_set_header X-Forwarded-For \proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \scheme;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
    
    # Agent Zero
    location /agent/ {
        proxy_pass http://127.0.0.1:8000/;
        proxy_set_header Host \host;
        proxy_set_header X-Real-IP \remote_addr;
        proxy_set_header X-Forwarded-For \proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \scheme;
    }
    
    # Health check endpoint
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
EOF

# Enable site
ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Test and reload Nginx
if nginx -t; then
    systemctl reload nginx
    print_info "Nginx configured successfully"
else
    print_error "Nginx configuration test failed"
fi

# -----------------------------------------------------------------------------
# 13 – UFW firewall
# -----------------------------------------------------------------------------
print_step "Firewall configuration"

# Install UFW if not present
if ! command -v ufw >/dev/null 2>&1; then
    apt-get install -y ufw
fi

# Configure UFW
UFW_MARKER="/etc/ufw/.homelab-initialized"
if [[ ! -f "$UFW_MARKER" ]]; then
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    
    # Allow essential services
    ufw allow 22/tcp comment "SSH"
    ufw allow 80/tcp comment "HTTP"
    ufw allow 443/tcp comment "HTTPS"
    ufw allow 11434/tcp comment "Ollama API"
    
    # Rate limit SSH
    ufw limit 22/tcp comment "SSH rate limit"
    
    # Enable UFW
    ufw --force enable
    
    touch "$UFW_MARKER"
    print_info "UFW configured and enabled"
else
    print_info "UFW already configured"
fi

# -----------------------------------------------------------------------------
# 14 – Final summary
# -----------------------------------------------------------------------------
print_step "Installation complete"

# ASCII Art Footer
cat << 'EOF'
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
EOF

cat <<EOF
===================================================================
✅ AI SERVER SETUP COMPLETE
===================================================================

SERVER INFORMATION:
  • Hostname:          $SHORT_HOSTNAME
  • Static IP:         $STATIC_IP/$CIDR
  • Gateway:           $GATEWAY
  • Interface:         $IFACE

ACCESS POINTS:
  • OpenWebUI:         https://$STATIC_IP
  • Agent Zero:        https://$STATIC_IP/agent/
  • Ollama API:        http://$STATIC_IP:11434

MANAGEMENT:
  • Check status:      systemctl status ollama ai-stack nginx
  • View logs:         journalctl -u ollama -u nginx -u docker
  • Test connectivity: curl -k https://$STATIC_IP/health

BACKUP LOCATION: $BACKUP_DIR
LOG FILE: $LOG_FILE
===================================================================
EOF

print_info "Script completed successfully at $(date)"
