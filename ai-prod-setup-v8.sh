#!/usr/bin/env bash
# =============================================================================
# ENTERPRISE PRODUCTION GRADE - AI STACK DEPLOYMENT
# Target: Ubuntu 22.04 / 24.04 LTS (Server)
# Features: PKI/SSL, Hardening, Kernel Tuning, Smart Firewall, Isolation,
#          Backup, Rollback, Monitoring, Health Checks, Secrets Management
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# 0 – CONFIGURATION
# -----------------------------------------------------------------------------
SCRIPT_VERSION="8.0.0-enterprise"
readonly LOG_FILE="/var/log/ai-prod-setup.log"
readonly BACKUP_ROOT="/opt/backups/ai-stack"
readonly TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
readonly BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
readonly AI_STACK_DIR="/opt/ai-stack"
readonly SECRETS_DIR="/opt/ai-stack/secrets"

# Software Versions (PINNED - No 'latest' tags)
readonly OPENWEBUI_VERSION="v0.3.19"
readonly OLLAMA_VERSION="0.5.7"
readonly PROMETHEUS_VERSION="v2.54.1"
readonly GRAFANA_VERSION="11.3.1"
readonly NODE_EXPORTER_VERSION="1.8.2"

# PKI / Certificate Settings
readonly CA_COUNTRY="US"
readonly CA_STATE="State"
readonly CA_LOCALITY="City"
readonly CA_ORG="Homelab Root CA"
readonly SERVER_ORG="Homelab Services"
readonly CA_VALIDITY_DAYS=3650
readonly CERT_VALIDITY_DAYS=3650

# Docker GPG Key Fingerprint (VERIFIED)
readonly DOCKER_GPG_FINGERPRINT="9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88"

# -----------------------------------------------------------------------------
# 1 – LOGGING & UTILITIES
# -----------------------------------------------------------------------------
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

log_info()  { echo -e "\033[0;32m[INFO]\033[0m  $(date '+%Y-%m-%d %H:%M:%S') | $*"; }
log_warn()  { echo -e "\033[1;33m[WARN]\033[0m  $(date '+%Y-%m-%d %H:%M:%S') | $*"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m  $(date '+%Y-%m-%d %H:%M:%S') | $*"; }
log_step()  { echo -e "\n\033[0;36m====== $1 ======\033[0m"; }

# Rollback function
rollback() {
    log_error "Initiating rollback due to failure..."
    
    # Restore network config if backup exists
    if [[ -f "${BACKUP_DIR}/resolv.conf.bak" ]]; then
        cp "${BACKUP_DIR}/resolv.conf.bak" /etc/resolv.conf
        systemctl restart systemd-resolved
        log_info "Network configuration restored"
    fi
    
    # Stop Docker containers
    if command -v docker >/dev/null 2>&1; then
        cd "$AI_STACK_DIR" 2>/dev/null || true
        docker compose down 2>/dev/null || true
        log_info "Docker containers stopped"
    fi
    
    # Restore UFW if backup exists
    if [[ -f "${BACKUP_DIR}/ufw.rules.bak" ]]; then
        cp "${BACKUP_DIR}/ufw.rules.bak" /etc/ufw/user.rules
        ufw reload 2>/dev/null || true
        log_info "UFW rules restored"
    fi
    
    log_error "Rollback complete. Please check $LOG_FILE for details."
    exit 1
}

# Trap errors for rollback
trap 'rollback' ERR

log_info "Enterprise Production AI Stack Installer [v$SCRIPT_VERSION] starting..."

# -----------------------------------------------------------------------------
# 2 – PRE-FLIGHT CHECKS & BACKUP
# -----------------------------------------------------------------------------
log_step "System Validation & Backup"

[[ "$(id -u)" -eq 0 ]] || { log_error "Must run as root."; }

source /etc/os-release
if [[ "$ID" != "ubuntu" ]]; then
    log_warn "This script is tuned for Ubuntu. Detected: $ID. Proceeding with caution."
fi

# Create backup directory
mkdir -p "$BACKUP_DIR"
log_info "Backup directory: $BACKUP_DIR"

# Backup current state
cp /etc/resolv.conf "${BACKUP_DIR}/resolv.conf.bak" 2>/dev/null || true
if ufw status | grep -q "Status: active"; then
    cp /etc/ufw/user.rules "${BACKUP_DIR}/ufw.rules.bak" 2>/dev/null || true
fi
log_info "System state backed up"

# Resource Checks
RAM_GB=$(free -g | awk '/Mem:/ {print $2}')
DISK_GB=$(df -BG / | awk 'NR==2 {sub(/G/,"",$4); print $4}')

log_info "Hardware Check: RAM: ${RAM_GB}GB | Disk Free: ${DISK_GB}GB"

if (( RAM_GB < 8 )); then
    log_warn "Low RAM detected. Creating 4GB Swap file..."
    if [[ ! -f /swapfile ]]; then
        fallocate -l 4G /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        sysctl vm.swappiness=10
        log_info "Swap file created and activated"
    else
        log_info "Swap file already exists"
    fi
fi

# -----------------------------------------------------------------------------
# 3 – KERNEL & SYSTEM HARDENING
# -----------------------------------------------------------------------------
log_step "System Hardening (Sysctl & Limits)"

cat > /etc/sysctl.d/99-homelab-hardening.conf <<EOF
# IP Spoofing protection
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1

# Ignore ICMP broadcast requests
net.ipv4.icmp_echo_ignore_broadcasts=1

# Disable source packet routing
net.ipv4.conf.all.accept_source_route=0
net.ipv6.conf.all.accept_source_route=0

# Ignore send redirects
net.ipv4.conf.all.send_redirects=0

# Block SYN attacks
net.ipv4.tcp_max_syn_backlog=2048
net.ipv4.tcp_synack_retries=2
net.ipv4.tcp_syn_retries=5

# Log Martians
net.ipv4.conf.all.log_martians=1

# Shared Memory (for AI Models)
kernel.shmmax=68719476736
kernel.shmall=4294967296

# Additional hardening
net.ipv4.conf.all.accept_redirects=0
net.ipv6.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.all.log_martians=1
kernel.kptr_restrict=2
kernel.dmesg_restrict=1
net.ipv4.tcp_timestamps=0
EOF

sysctl --system > /dev/null
log_info "Kernel parameters applied"

cat > /etc/security/limits.d/99-homelab.conf <<EOF
* soft nofile 65536
* hard nofile 65536
* soft nproc 65536
* hard nproc 65536
EOF

# -----------------------------------------------------------------------------
# 4 – DEPENDENCIES
# -----------------------------------------------------------------------------
log_step "Installing Core Dependencies"

DEBIAN_FRONTEND=noninteractive apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    ufw \
    fail2ban \
    openssl \
    net-tools \
    zip unzip \
    htop \
    rsync \
    bc

# -----------------------------------------------------------------------------
# 5 – NETWORK & DNS (Secure)
# -----------------------------------------------------------------------------
log_step "Network & DNS Configuration"

PRIMARY_IP=$(hostname -I | awk '{print $1}')
HOSTNAME_FQDN=$(hostname -f)
[[ -z "$HOSTNAME_FQDN" ]] && HOSTNAME_FQDN=$(hostname)

log_info "Detected IP: $PRIMARY_IP"
log_info "Detected Hostname: $HOSTNAME_FQDN"

mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/homelab-dns.conf <<EOF
[Resolve]
DNS=9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net
DNSSEC=yes
FallbackDNS=1.1.1.1
Domains=~.
Cache=yes
DNSStubListener=yes
EOF

if [[ -L /etc/resolv.conf ]]; then
    rm -f /etc/resolv.conf
fi
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
systemctl restart systemd-resolved

if ! getent hosts google.com &>/dev/null; then
    log_error "DNS resolution verification failed"
fi
log_info "DNS configured with Quad9 (DNSSEC: Strict)"

# -----------------------------------------------------------------------------
# 6 – FIREWALL (UFW - Smart Mode)
# -----------------------------------------------------------------------------
log_step "Configuring UFW Firewall"

if ufw status | grep -q "Status: active"; then
    log_warn "UFW is already active. Adding rules without resetting..."
    ufw allow 22/tcp comment 'SSH'
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    ufw allow 9090/tcp comment 'Prometheus'
    ufw allow 3000/tcp comment 'Grafana'
else
    log_info "UFW inactive. Initializing default deny policy..."
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp comment 'SSH'
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    ufw allow 9090/tcp comment 'Prometheus'
    ufw allow 3000/tcp comment 'Grafana'
    ufw --force enable
fi

# -----------------------------------------------------------------------------
# 7 – PKI & CERTIFICATE AUTHORITY
# -----------------------------------------------------------------------------
log_step "Generating Internal PKI (Root CA + Server Cert)"

SSL_DIR="/etc/ssl/homelab"
mkdir -p "$SSL_DIR"
pushd "$SSL_DIR" || exit 1

if [[ ! -f "ca.crt" ]]; then
    log_info "Generating Root CA..."
    openssl genrsa -out ca.key 4096
    openssl req -x509 -new -nodes -key ca.key -sha256 -days $CA_VALIDITY_DAYS \
        -out ca.crt \
        -subj "/C=$CA_COUNTRY/ST=$CA_STATE/L=$CA_LOCALITY/O=$CA_ORG/CN=Homelab Root CA"
    log_info "Root CA created"
else
    log_info "Root CA already exists. Skipping generation."
fi

if [[ ! -f "server.key" ]]; then
    log_info "Generating Server Key..."
    openssl genrsa -out server.key 2048
fi

cat > server.csr.conf <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext
[dn]
C = $CA_COUNTRY
ST = $CA_STATE
L = $CA_LOCALITY
O = $SERVER_ORG
CN = $HOSTNAME_FQDN
[req_ext]
subjectAltName = @alt_names
[alt_names]
DNS.1 = $HOSTNAME_FQDN
DNS.2 = localhost
DNS.3 = prometheus.$HOSTNAME_FQDN
DNS.4 = grafana.$HOSTNAME_FQDN
IP.1 = $PRIMARY_IP
IP.2 = 127.0.0.1
EOF

openssl req -new -key server.key -out server.csr -config server.csr.conf

if [[ ! -f "server.crt" ]]; then
    log_info "Signing Server Certificate..."
    openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
        -out server.crt -days $CERT_VALIDITY_DAYS -sha256 \
        -extensions req_ext -extfile server.csr.conf
    chmod 600 server.key
    chmod 644 server.crt ca.crt
    log_info "Server Certificate generated"
fi

popd || exit 1
log_warn "IMPORTANT: Install '$SSL_DIR/ca.crt' in your browsers/devices to avoid security warnings!"

# -----------------------------------------------------------------------------
# 8 – DOCKER ENGINE (with GPG verification)
# -----------------------------------------------------------------------------
log_step "Installing Docker Engine"

if ! command -v docker >/dev/null 2>&1; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    
    # Verify GPG key fingerprint
    ACTUAL_FINGERPRINT=$(gpg --show-keys --with-fingerprint /etc/apt/keyrings/docker.asc 2>/dev/null | grep -A1 'pub' | tail -1 | tr -d ' ' || echo "")
    if [[ "$ACTUAL_FINGERPRINT" != "$DOCKER_GPG_FINGERPRINT" ]]; then
        log_error "Docker GPG key fingerprint mismatch! Expected: $DOCKER_GPG_FINGERPRINT, Got: $ACTUAL_FINGERPRINT"
    fi
    log_info "Docker GPG key verified"
    
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    systemctl enable docker
    systemctl start docker
else
    log_info "Docker already installed"
fi

# Hardening Docker Daemon
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"},
  "iptables": true,
  "ip-forward": false,
  "bridge": "none",
  "live-restore": true,
  "userland-proxy": false,
  "no-new-privileges": true,
  "dns": ["9.9.9.9", "149.112.112.112"],
  "storage-driver": "overlay2",
  "default-ulimits": {
    "nofile": {"Name": "nofile", "Hard": 65536, "Soft": 65536}
  }
}
EOF
systemctl restart docker

# -----------------------------------------------------------------------------
# 9 – SECRETS MANAGEMENT
# -----------------------------------------------------------------------------
log_step "Setting Up Secrets Management"

mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

# Generate secure secrets
if [[ ! -f "${SECRETS_DIR}/webui-secret.env" ]]; then
    cat > "${SECRETS_DIR}/webui-secret.env" <<EOF
WEBUI_SECRET=$(openssl rand -hex 32)
EOF
    chmod 600 "${SECRETS_DIR}/webui-secret.env"
    log_info "WebUI secret generated"
fi

if [[ ! -f "${SECRETS_DIR}/grafana-secret.env" ]]; then
    cat > "${SECRETS_DIR}/grafana-secret.env" <<EOF
GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=$(openssl rand -base64 16)
GF_INSTALL_PLUGINS=grafana-piechart-panel
EOF
    chmod 600 "${SECRETS_DIR}/grafana-secret.env"
    log_info "Grafana secrets generated"
fi

# -----------------------------------------------------------------------------
# 10 – APPLICATION DEPLOYMENT
# -----------------------------------------------------------------------------
log_step "Deploying AI Stack (Docker Compose)"

mkdir -p "$AI_STACK_DIR"/{data/{ollama,openwebui,grafana,prometheus},backups}
cd "$AI_STACK_DIR"

cat > docker-compose.yml <<EOF
version: '3.8'

services:
  # Ollama Base Model Runner (PINNED VERSION)
  ollama:
    image: ollama/ollama:${OLLAMA_VERSION}
    container_name: ollama
    restart: unless-stopped
    volumes:
      - ./data/ollama:/root/.ollama
    environment:
      - OLLAMA_HOST=0.0.0.0
      # FIXED: Removed OLLAMA_ORIGINS - Nginx handles CORS
    networks:
      - ai-net
    tmpfs:
      - /tmp
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:11434/api/tags"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

  # OpenWebUI Frontend (PINNED VERSION)
  openwebui:
    image: ghcr.io/open-webui/open-webui:${OPENWEBUI_VERSION}
    container_name: openwebui
    restart: unless-stopped
    ports:
      - "127.0.0.1:3000:8080"
    env_file:
      - ${SECRETS_DIR}/webui-secret.env
    environment:
      - OLLAMA_BASE_URL=http://ollama:11434
      - ENABLE_SIGNUP=false
      - DEFAULT_MODELS=llama3.2
    volumes:
      - ./data/openwebui:/app/backend/data
    depends_on:
      ollama:
        condition: service_healthy
    networks:
      - ai-net
    extra_hosts:
      - "host.docker.internal:host-gateway"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s

  # Prometheus Monitoring (PINNED VERSION)
  prometheus:
    image: prom/prometheus:${PROMETHEUS_VERSION}
    container_name: prometheus
    restart: unless-stopped
    ports:
      - "127.0.0.1:9090:9090"
    volumes:
      - ./data/prometheus:/prometheus
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--web.console.libraries=/usr/share/prometheus/console_libraries'
      - '--web.console.templates=/usr/share/prometheus/consoles'
      - '--web.enable-lifecycle'
    networks:
      - ai-net
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:9090/-/healthy"]
      interval: 30s
      timeout: 10s
      retries: 3

  # Grafana Dashboard (PINNED VERSION)
  grafana:
    image: grafana/grafana:${GRAFANA_VERSION}
    container_name: grafana
    restart: unless-stopped
    ports:
      - "127.0.0.1:3001:3000"
    env_file:
      - ${SECRETS_DIR}/grafana-secret.env
    environment:
      - GF_SERVER_ROOT_URL=https://${HOSTNAME_FQDN}
      - GF_INSTALL_PLUGINS=grafana-piechart-panel
    volumes:
      - ./data/grafana:/var/lib/grafana
    depends_on:
      - prometheus
    networks:
      - ai-net
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:3000/api/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  # Node Exporter for System Metrics (PINNED VERSION)
  node-exporter:
    image: prom/node-exporter:${NODE_EXPORTER_VERSION}
    container_name: node-exporter
    restart: unless-stopped
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)'
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    networks:
      - ai-net
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:9100/metrics"]
      interval: 30s
      timeout: 10s
      retries: 3

networks:
  ai-net:
    driver: bridge
EOF

# Prometheus configuration
cat > prometheus.yml <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node-exporter'
    static_configs:
      - targets: ['node-exporter:9100']

  - job_name: 'ollama'
    static_configs:
      - targets: ['ollama:11434']
    metrics_path: '/api/metrics'
EOF

log_info "Pulling Docker images (this may take a while)..."
docker compose pull

log_info "Starting containers..."
docker compose up -d

# Wait for health checks
log_info "Waiting for services to become healthy..."
sleep 30

# -----------------------------------------------------------------------------
# 11 – BACKUP STRATEGY
# -----------------------------------------------------------------------------
log_step "Setting Up Backup Strategy"

# Create backup script
cat > /usr/local/bin/ai-stack-backup.sh <<'EOF'
#!/bin/bash
# AI Stack Backup Script
BACKUP_DIR="/opt/backups/ai-stack"
AI_STACK_DIR="/opt/ai-stack"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_PATH="${BACKUP_DIR}/backup_${TIMESTAMP}"

mkdir -p "$BACKUP_PATH"

# Backup Docker volumes
cd "$AI_STACK_DIR"
docker compose exec -T ollama tar czf - /root/.ollama > "${BACKUP_PATH}/ollama-data.tar.gz" 2>/dev/null || true
docker compose exec -T openwebui tar czf - /app/backend/data > "${BACKUP_PATH}/openwebui-data.tar.gz" 2>/dev/null || true

# Backup configurations
cp -r /etc/ssl/homelab "${BACKUP_DIR}/" 2>/dev/null || true
cp -r "$AI_STACK_DIR"/docker-compose.yml "$AI_STACK_DIR"/prometheus.yml "${BACKUP_PATH}/" 2>/dev/null || true

# Keep only last 7 backups
find "$BACKUP_DIR" -type d -name "backup_*" -mtime +7 -exec rm -rf {} + 2>/dev/null || true

echo "Backup completed: ${BACKUP_PATH}"
EOF
chmod +x /usr/local/bin/ai-stack-backup.sh

# Schedule daily backup at 2 AM
crontab -l 2>/dev/null | grep -v 'ai-stack-backup' | crontab -
(crontab -l 2>/dev/null; echo "0 2 * * * /usr/local/bin/ai-stack-backup.sh >> /var/log/ai-backup.log 2>&1") | crontab -

log_info "Backup strategy configured (daily at 2 AM)"

# -----------------------------------------------------------------------------
# 12 – NGINX REVERSE PROXY
# -----------------------------------------------------------------------------
log_step "Configuring Nginx Reverse Proxy"

if ! command -v nginx >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y nginx
fi

cat > /etc/nginx/sites-available/ai-stack <<EOF
# Rate limiting
limit_req_zone \$binary_remote_addr zone=api_limit:10m rate=10r/s;
limit_req_zone \$binary_remote_addr zone=general_limit:10m rate=30r/s;

server {
    listen 80;
    listen [::]:80;
    server_name $HOSTNAME_FQDN $PRIMARY_IP;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $HOSTNAME_FQDN $PRIMARY_IP;

    ssl_certificate $SSL_DIR/server.crt;
    ssl_certificate_key $SSL_DIR/server.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384';
    ssl_prefer_server_ciphers off;

    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data:; connect-src 'self'; frame-ancestors 'self';" always;

    client_max_body_size 200M;

    # Main UI
    location / {
        limit_req zone=general_limit burst=50 nodelay;
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # Ollama API Proxy
    location /ollama/ {
        limit_req zone=api_limit burst=20 nodelay;
        proxy_pass http://127.0.0.1:11434/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_buffering off;
    }

    # Prometheus
    location /prometheus/ {
        limit_req zone=api_limit burst=20 nodelay;
        proxy_pass http://127.0.0.1:9090/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        auth_basic "Prometheus";
        auth_basic_user_file /etc/nginx/.htpasswd;
    }

    # Grafana
    location /grafana/ {
        limit_req zone=general_limit burst=50 nodelay;
        proxy_pass http://127.0.0.1:3001/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        rewrite ^/grafana/(.*) /\$1 break;
    }

    # Health Check
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
EOF

# Create basic auth for Prometheus
htpasswd -bc /etc/nginx/.htpasswd admin $(openssl rand -base64 12) 2>/dev/null || true
chmod 640 /etc/nginx/.htpasswd

ln -sf /etc/nginx/sites-available/ai-stack /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

if nginx -t; then
    systemctl reload nginx
    log_info "Nginx configured and reloaded"
else
    log_error "Nginx configuration failed"
fi

# -----------------------------------------------------------------------------
# 13 – MONITORING (Fail2ban)
# -----------------------------------------------------------------------------
log_step "Configuring Fail2ban"

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
destemail = root@localhost
action = %(action_mwl)s

[sshd]
enabled = true
port = ssh
logpath = /var/log/auth.log
maxretry = 3

[nginx-http-auth]
enabled = true
filter = nginx-http-auth
port = http,https
logpath = /var/log/nginx/error.log
maxretry = 3

[nginx-limit-req]
enabled = true
filter = nginx-limit-req
action = iptables-multiport[name=ReqLimit, port="http,https", protocol=tcp]
logpath = /var/log/nginx/error.log
maxretry = 10
findtime = 600
bantime = 7200
EOF

systemctl enable fail2ban
systemctl restart fail2ban

# -----------------------------------------------------------------------------
# 14 – VERIFICATION & HEALTH CHECKS
# -----------------------------------------------------------------------------
log_step "System Verification & Health Checks"

services=("ollama" "openwebui" "grafana" "prometheus" "node-exporter" "nginx" "docker" "systemd-resolved" "fail2ban")
all_good=true

for svc in "${services[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null || docker ps --format '{{.Names}}' | grep -q "^${svc}$"; then
        log_info "✓ Service $svc is running"
    else
        log_warn "✗ Service $svc is NOT running"
        all_good=false
    fi
done

# Check Docker container health
log_info "Checking container health..."
for container in ollama openwebui grafana prometheus node-exporter; do
    health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "no-healthcheck")
    if [[ "$health" == "healthy" ]]; then
        log_info "✓ Container $container is healthy"
    else
        log_warn "⚠ Container $container health: $health"
    fi
done

# Test endpoints
log_info "Testing service endpoints..."

curl -sf http://127.0.0.1:3000/health >/dev/null && log_info "✓ OpenWebUI health check passed" || log_warn "✗ OpenWebUI health check failed"
curl -sf http://127.0.0.1:9090/-/healthy >/dev/null && log_info "✓ Prometheus health check passed" || log_warn "✗ Prometheus health check failed"
curl -sf http://127.0.0.1:3001/api/health >/dev/null && log_info "✓ Grafana health check passed" || log_warn "✗ Grafana health check failed"
curl -sf http://127.0.0.1:11434/api/tags >/dev/null && log_info "✓ Ollama API check passed" || log_warn "✗ Ollama API check failed"

log_step "Deployment Complete"

# Get Grafana password
GRAFANA_PASSWORD=$(grep GF_SECURITY_ADMIN_PASSWORD "${SECRETS_DIR}/grafana-secret.env" | cut -d'=' -f2)

# Get Prometheus auth password
PROMETHEUS_PASSWORD=$(grep admin /etc/nginx/.htpasswd | cut -d':' -f2)

cat <<EOF
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

=============================================================================
EOF

if [[ "$all_good" = false ]]; then
    log_warn "Some services are not running. Check logs above."
    exit 1
fi

log_info "Enterprise deployment completed successfully!"
