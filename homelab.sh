#!/usr/bin/env bash
# =============================================================================
# ALL-IN-ONE - AI SERVER SETUP - Ubuntu 24.04 LTS - Production Ready
# Version: 7.0.0-Production
# Features: Network Resilience, Privacy-First, Zero-Error Design
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# 0 – Global Constants & Configuration
# -----------------------------------------------------------------------------
SCRIPT_VERSION="7.0.0-production"
LOG_FILE="/var/log/homelab-setup.log"
BACKUP_ROOT="/opt/homelab-backups"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
AI_STACK_DIR="/opt/ai-stack"
PROGRESS_FILE="/tmp/install_progress"

# Privacy-First DNS Configuration
PRIMARY_DNS="9.9.9.9 149.112.112.112"
FALLBACK_DNS="1.1.1.1 1.0.0.1"

# Network Resilience Settings
MAX_RETRIES=5
INITIAL_DELAY=3

# -----------------------------------------------------------------------------
# 1 – Logging System
# -----------------------------------------------------------------------------
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

print_info()  { echo -e "\033[0;32m[INFO]\033[0m $*"; }
print_warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
print_error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; exit 1; }
print_step()  { echo -e "\n\033[0;36m===== $1 =====\033[0m"; }

print_info " ##########################"
print_info " AI Server Installer [v$SCRIPT_VERSION]"
print_info " Privacy Mode: Strict (No Google Services)"
print_info " Started: $(date)"
print_info " ##########################"

# -----------------------------------------------------------------------------
# 2 – Network Resilience Functions
# -----------------------------------------------------------------------------
network_retry() {
    local retries=0
    local delay=$INITIAL_DELAY
    local cmd="$*"
    
    while [[ $retries -lt $MAX_RETRIES ]]; do
        if eval "$cmd"; then
            return 0
        fi
        
        ((retries++))
        print_warn "Command failed (attempt $retries/$MAX_RETRIES). Retrying in ${delay}s..."
        sleep $delay
        delay=$((delay * 2))
    done
    
    print_error "Command failed after $MAX_RETRIES attempts: $cmd"
}

validate_connection() {
    print_info "Validating network stability..."
    network_retry "ping -c 1 9.9.9.9"
    network_retry "curl -m 5 -sI https://ghcr.io >/dev/null"
    print_info "Network connection validated"
}

# -----------------------------------------------------------------------------
# 3 – Progress Tracking
# -----------------------------------------------------------------------------
update_progress() {
    echo "STAGE=$1" > "$PROGRESS_FILE"
    echo "TIMESTAMP=$(date)" >> "$PROGRESS_FILE"
}

# -----------------------------------------------------------------------------
# 4 – Pre-flight Checks & Backup
# -----------------------------------------------------------------------------
print_step "Pre-flight checks & backup"
update_progress "preflight"

[[ "$(id -u)" -eq 0 ]] || print_error "Must run as root (or sudo)"
source /etc/os-release || print_error "Cannot source /etc/os-release"
[[ "$ID" == "ubuntu" ]] || print_error "Only Ubuntu 24.04 is supported"

# Create backup directory
mkdir -p "$BACKUP_DIR"

backup_network_configs() {
    print_info "Backing up existing critical configurations..."
    
    cp -a /etc/hosts "$BACKUP_DIR/hosts.bak" 2>/dev/null || true
    cp -a /etc/resolv.conf "$BACKUP_DIR/resolv.conf.bak" 2>/dev/null || true
    cp -a /etc/systemd/resolved.conf "$BACKUP_DIR/resolved.conf.bak" 2>/dev/null || true
    
    if [[ -d /etc/netplan ]]; then
        mkdir -p "$BACKUP_DIR/netplan"
        cp -a /etc/netplan/*.yaml "$BACKUP_DIR/netplan/" 2>/dev/null || true
    fi

    if [[ -d /etc/cloud ]]; then
        mkdir -p "$BACKUP_DIR/cloud-init"
        cp -a /etc/cloud/cloud.cfg.d/* "$BACKUP_DIR/cloud-init/" 2>/dev/null || true
    fi
    
    print_info "Backups saved to $BACKUP_DIR"
}

restore_network_configs() {
    print_error "!!! NETWORK FAILURE DETECTED !!!"
    print_error "Attempting to restore original configuration..."
    
    [[ -f "$BACKUP_DIR/hosts.bak" ]] && cp -f "$BACKUP_DIR/hosts.bak" /etc/hosts
    [[ -f "$BACKUP_DIR/resolv.conf.bak" ]] && cp -f "$BACKUP_DIR/resolv.conf.bak" /etc/resolv.conf
    [[ -f "$BACKUP_DIR/resolved.conf.bak" ]] && cp -f "$BACKUP_DIR/resolved.conf.bak" /etc/systemd/resolved.conf
    
    systemctl restart systemd-resolved 2>/dev/null || true
    
    sleep 3
    if ping -c 1 9.9.9.9 >/dev/null 2>&1; then
        print_info "Network RESTORED successfully via backup."
        exit 1
    else
        print_error "Network NOT RESTORED. Manual intervention required."
        exit 1
    fi
}

backup_network_configs

# Disable cloud-init network config
if [[ -d /etc/cloud/cloud.cfg.d ]]; then
    echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
    print_info "Disabled cloud-init network management"
fi

# -----------------------------------------------------------------------------
# 5 – Install Essential Tools
# -----------------------------------------------------------------------------
print_step "Installing essential tools"
update_progress "tools"

export DEBIAN_FRONTEND=noninteractive
validate_connection
network_retry "apt-get update -qq"
apt-get install -y -qq net-tools iproute2 curl wget iputils-ping gnupg lsb-release ca-certificates openssl ufw nginx dnsutils

# -----------------------------------------------------------------------------
# 6 – Resource Check
# -----------------------------------------------------------------------------
print_step "Resource validation"
mem_gb=$(free -g | awk '/Mem:/ {print $2}')
disk_gb=$(df -BG / | awk 'NR==2 {sub(/G/,"",$4); print $4}')
print_info "Resources – RAM: ${mem_gb}GB, Free disk: ${disk_gb}GB"
((mem_gb < 8)) && print_warn "Low RAM (<8GB) detected. Large models may be slow."
((disk_gb < 50)) && print_warn "Low disk space (<50GB). Consider expanding storage."

# -----------------------------------------------------------------------------
# 7 – Network Detection
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
STATIC_IP="$CURRENT_IP"
HOST_ADDRESS="$STATIC_IP"

GATEWAY=$(ip -4 route show dev "$IFACE" | awk '/default via/ {print $3; exit}')
[[ -z "$GATEWAY" ]] && GATEWAY="${CURRENT_IP%.*}.1"

print_info "Detected IP: $STATIC_IP on $IFACE (Gateway: $GATEWAY)"

# -----------------------------------------------------------------------------
# 8 – Hostname Configuration
# -----------------------------------------------------------------------------
print_step "Hostname configuration"
CURRENT_HOSTNAME=$(hostname)
SHORT_HOSTNAME="${CURRENT_HOSTNAME%%.*}"
if [[ "$CURRENT_HOSTNAME" == "localhost" ]] || [[ -z "$SHORT_HOSTNAME" ]]; then
    SHORT_HOSTNAME="ai-server"
    hostnamectl set-hostname "$SHORT_HOSTNAME"
    print_info "Set hostname to $SHORT_HOSTNAME"
fi

cat > /etc/hosts <<EOF
127.0.0.1       localhost
$STATIC_IP      $SHORT_HOSTNAME
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

# -----------------------------------------------------------------------------
# 9 – DNS Configuration (Privacy-First)
# -----------------------------------------------------------------------------
print_step "Configuring Systemd-Resolved (Quad9 & Cloudflare)"
update_progress "dns"

cat > /etc/systemd/resolved.conf <<EOF
[Resolve]
DNS=$PRIMARY_DNS
FallbackDNS=$FALLBACK_DNS
DNSOverTLS=opportunistic
Cache=yes
DNSStubListener=yes
LLMNR=no
MulticastDNS=no
DNSSEC=no
ReadEtcHosts=yes
EOF

rm -f /etc/resolv.conf
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
systemctl restart systemd-resolved

# Privacy-compliant DNS test
print_info "Testing connectivity with new DNS settings..."
sleep 3
if ! timeout 10 dig +short @127.0.0.53 quad9.net >/dev/null 2>&1; then
    print_error "DNS Resolution FAILED. Triggering Network Restore..."
    restore_network_configs
fi
print_info "DNS configuration successful. No Google servers used."

# -----------------------------------------------------------------------------
# 10 – Docker Installation
# -----------------------------------------------------------------------------
print_step "Docker installation"
update_progress "docker"

if ! command -v docker >/dev/null 2>&1; then
    print_info "Installing Docker..."
    
    # Remove old versions
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
        apt-get remove -y "$pkg" 2>/dev/null || true
    done
    
    # Add Docker Repository
    install -m 0755 -d /etc/apt/keyrings
    network_retry "curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc"
    chmod a+r /etc/apt/keyrings/docker.asc
    
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    network_retry "apt-get update -qq"
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    print_info "Docker installed"
else
    print_info "Docker already installed"
fi

# Configure Docker Daemon
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
  "dns": ["9.9.9.9", "1.1.1.1"]
}
EOF

systemctl restart docker
systemctl enable docker

if docker run --rm hello-world >/dev/null 2>&1; then
    print_info "Docker validated successfully"
else
    print_error "Docker test failed"
fi

# -----------------------------------------------------------------------------
# 11 – Ollama Installation
# -----------------------------------------------------------------------------
print_step "Ollama installation"
update_progress "ollama"

if ! command -v ollama >/dev/null 2>&1; then
    print_info "Installing Ollama..."
    network_retry "curl -fsSL https://ollama.com/install.sh -o /tmp/ollama-install.sh"
    bash /tmp/ollama-install.sh
    
    # Create User
    id -u ollama &>/dev/null || useradd -r -s /bin/false -m ollama
    
    # Create Service
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
    print_info "Ollama installed"
else
    print_info "Ollama already installed"
    systemctl restart ollama 2>/dev/null || true
fi

# Wait for Ollama to be ready
print_info "Waiting for Ollama service to be ready..."
for i in {1..20}; do
    if curl -s http://localhost:11434 >/dev/null 2>&1; then
        print_info "Ollama is ready after $i attempts"
        break
    fi
    sleep 2
done

if ! curl -s http://localhost:11434 >/dev/null 2>&1; then
    print_warn "Ollama service not responding - check with: systemctl status ollama"
fi

# -----------------------------------------------------------------------------
# 12 – AI Stack Setup
# -----------------------------------------------------------------------------
print_step "AI Stack Setup"
update_progress "stack"

mkdir -p "$AI_STACK_DIR"/{openwebui,agent-zero}/data

# Docker Compose Configuration
cat > "$AI_STACK_DIR/docker-compose.yml" <<EOF
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
    extra_hosts:
      - "host.docker.internal:host-gateway"

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
print_info "Pulling Docker images..."
network_retry "docker compose pull --quiet"

print_info "Starting AI stack..."
docker compose up -d

# Verify services
sleep 10
if docker compose ps | grep -q "Up"; then
    print_info "AI stack started successfully"
else
    print_error "AI stack failed to start"
fi

# -----------------------------------------------------------------------------
# 13 – Nginx Reverse Proxy & SSL
# -----------------------------------------------------------------------------
print_step "Nginx Reverse Proxy & Hardening"
update_progress "nginx"

SSL_DIR="/etc/ssl/localhost"
mkdir -p "$SSL_DIR"
SSL_CERT="$SSL_DIR/fullchain.pem"
SSL_KEY="$SSL_DIR/privkey.pem"

if [[ ! -f "$SSL_CERT" ]]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -subj "/C=US/ST=State/L=City/O=Homelab/CN=$SHORT_HOSTNAME" \
        -addext "subjectAltName=IP:$STATIC_IP,DNS:$SHORT_HOSTNAME" \
        -keyout "$SSL_KEY" -out "$SSL_CERT"
    chmod 600 "$SSL_KEY"
    print_info "SSL certificates generated"
fi

NGINX_SITE="/etc/nginx/sites-available/ai-server"
cat >"$NGINX_SITE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $SHORT_HOSTNAME $STATIC_IP;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $SHORT_HOSTNAME $STATIC_IP;
    
    ssl_certificate $SSL_CERT;
    ssl_certificate_key $SSL_KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    client_max_body_size 500M;
    
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    
    location /ollama/ {
        proxy_pass http://127.0.0.1:11434/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
    
    location /agent/ {
        proxy_pass http://127.0.0.1:8000/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
    
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
EOF

ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

if nginx -t; then
    systemctl reload nginx
    print_info "Nginx configured successfully"
else
    print_error "Nginx configuration failed"
fi

# -----------------------------------------------------------------------------
# 14 – Firewall Configuration
# -----------------------------------------------------------------------------
print_step "Firewall configuration"
update_progress "firewall"

UFW_MARKER="/etc/ufw/.homelab-initialized"
if [[ ! -f "$UFW_MARKER" ]]; then
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp comment "SSH"
    ufw allow 80/tcp comment "HTTP"
    ufw allow 443/tcp comment "HTTPS"
    ufw --force enable
    touch "$UFW_MARKER"
    print_info "UFW configured and enabled"
else
    print_info "UFW already configured"
fi

# -----------------------------------------------------------------------------
# 15 – Final Verification & Summary
# -----------------------------------------------------------------------------
print_step "Installation Complete"
update_progress "complete"

# Service Status Check
print_info "Verifying service status..."
systemctl is-active --quiet docker && print_info "✓ Docker running" || print_warn "✗ Docker not running"
systemctl is-active --quiet ollama && print_info "✓ Ollama running" || print_warn "✗ Ollama not running"
systemctl is-active --quiet nginx && print_info "✓ Nginx running" || print_warn "✗ Nginx not running"

docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "openwebui|agent-zero" || print_warn "Containers not running"

cat <<EOF

===================================================================
✅ AI SERVER SETUP COMPLETE
===================================================================

SERVER INFORMATION:
  • Hostname:          $SHORT_HOSTNAME
  • Static IP:         $STATIC_IP
  • Gateway:           $GATEWAY
  • Interface:         $IFACE

ACCESS POINTS (HTTPS):
  • Main Dashboard:    https://$STATIC_IP
  • Agent API:         https://$STATIC_IP/agent/
  • Ollama API:        http://$STATIC_IP:11434

MANAGEMENT COMMANDS:
  • Check logs:        journalctl -u ollama -u docker -u nginx
  • Restart stack:     cd $AI_STACK_DIR && docker compose restart
  • View containers:   docker ps
  • Test health:       curl -k https://$STATIC_IP/health

BACKUP LOCATION: $BACKUP_DIR
LOG FILE: $LOG_FILE
PROGRESS FILE: $PROGRESS_FILE

===================================================================

Installation completed successfully at $(date)
For support, check: $LOG_FILE

EOF

print_info "Script completed successfully at $(date)"
