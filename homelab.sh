#!/usr/bin/env bash
# =============================================================================
# ALL-IN-ONE NUC AI SERVER SETUP - Ubuntu 24.04 LTS - Fully Automated & Hardened
# =============================================================================
# Author: Agent Zero (2026 edition – fully hardened, systemd-resolved only)
# Non-interactive, idempotent, private home LAN focused
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# -------------------------------------------------------------------------
# 0 – Global constants & defaults (override via env vars if needed)
# -------------------------------------------------------------------------
SCRIPT_VERSION="3.5.1-hardened-resolved"
LOG_FILE="/var/log/homelab-setup.log"
BACKUP_ROOT="/opt/homelab-backups"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
AI_STACK_DIR="/opt/ai-stack"
DNS_DOMAIN="ai.local"
RESOLVER_STUB="127.0.0.53"

# -------------------------------------------------------------------------
# 1 – Logging
# -------------------------------------------------------------------------
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

print_info()  { echo -e "\033[0;32m[INFO]\033[0m $*"; }
print_warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
print_error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; exit 1; }
print_step()  { echo -e "\n\033[0;36m===== $1 =====\033[0m"; }

print_info "--- Homelab AI-stack installer v$SCRIPT_VERSION started $(date) ---"

# -------------------------------------------------------------------------
# 2 – Pre-flight checks
# -------------------------------------------------------------------------
print_step "Pre-flight checks"

[[ "$(id -u)" -eq 0 ]] || print_error "Must run as root (or sudo)"

source /etc/os-release || print_error "Cannot source /etc/os-release"
[[ "$ID" == "ubuntu" ]] || print_error "Only Ubuntu is supported"
[[ "$(lsb_release -rs)" == "24.04" ]] && print_info "Ubuntu 24.04 detected" || print_warn "Tested on 24.04 – may work on others"

# Disable cloud-init network config
if [[ -d /etc/cloud/cloud.cfg.d ]]; then
    echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
    print_info "Disabled cloud-init network management"
fi

# -------------------------------------------------------------------------
# 3 – Resource check (informational)
# -------------------------------------------------------------------------
mem_gb=$(free -g | awk '/Mem:/ {print $2}')
disk_gb=$(df -BG / | awk 'NR==2 {sub(/G/,"",$4); print $4}')
print_info "Resources – RAM: ${mem_gb}GB, Free disk: ${disk_gb}GB"
((mem_gb < 8))  && print_warn "Less than 8GB RAM – large models may be slow"
((disk_gb < 50)) && print_warn "Less than 50GB free – consider expanding storage"

# -------------------------------------------------------------------------
# 4 – Network detection
# -------------------------------------------------------------------------
print_step "Network detection"

IFACE="${IFACE:-$(ip -4 route show default | awk '/default/ {print $5; exit}')}"
[[ -n "$IFACE" ]] || print_error "Cannot detect primary interface – set IFACE= manually"

CURRENT_CIDR=$(ip -4 addr show dev "$IFACE" scope global | awk '/inet / {print $2; exit}')
[[ -n "$CURRENT_CIDR" ]] || print_error "No IPv4 address on $IFACE"

CURRENT_IP="${CURRENT_CIDR%/*}"
DEFAULT_CIDR="${CURRENT_CIDR#*/}"

if [[ "$DEFAULT_CIDR" =~ ^[0-9]{1,2}$ ]] && ((DEFAULT_CIDR >= 8 && DEFAULT_CIDR <= 32)); then
    CIDR="${CIDR:-$DEFAULT_CIDR}"
else
    print_warn "Invalid CIDR detected – forcing /24"
    CIDR="${CIDR:-24}"
fi

DEFAULT_STATIC_IP="$(echo "$CURRENT_IP" | awk -F. '{print $1"."$2"."$3".15"}')"
STATIC_IP="${STATIC_IP:-$DEFAULT_STATIC_IP}"

GATEWAY=$(ip -4 route show dev "$IFACE" | awk '/default via/ {print $3; exit}')
[[ -z "$GATEWAY" ]] && GATEWAY="${CURRENT_IP%.*}.1"

print_info "Interface $IFACE – $CURRENT_IP/$CIDR (gateway $GATEWAY)"
print_info "Static IP to set: $STATIC_IP/$CIDR"

mkdir -p "$BACKUP_DIR"

# -------------------------------------------------------------------------
# 5 – Install packages (before network change)
# -------------------------------------------------------------------------
print_step "Package installation"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y --no-install-recommends \
    curl wget gnupg ca-certificates net-tools git ufw nginx \
    openssh-server htop fail2ban logrotate iputils-arping

# -------------------------------------------------------------------------
# 6 – Docker
# -------------------------------------------------------------------------
print_step "Docker installation"

if ! command -v docker >/dev/null 2>&1; then
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" >/etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

if ! docker compose version >/dev/null 2>&1; then
    print_warn "Docker compose plugin missing – installing legacy binary"
    curl -L "https://github.com/docker/compose/releases/download/v2.27.1/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    ln -sf /usr/local/bin/docker-compose /usr/local/bin/docker-compose-plugin
fi

DOCKER_USER="${SUDO_USER:-root}"
usermod -aG docker "$DOCKER_USER" || true
print_info "Docker ready – $DOCKER_USER in docker group"

# -------------------------------------------------------------------------
# 7 – Systemd-resolved: Quad9 DoT + idempotent /etc/hosts
# -------------------------------------------------------------------------
print_step "DNS configuration (systemd-resolved + Quad9 DoT)"

mkdir -p /etc/systemd/resolved.conf.d

cat >/etc/systemd/resolved.conf.d/quad9-dot.conf <<EOF
[Resolve]
DNS=9.9.9.9#dns.quad9.net
DNS=149.112.112.112#dns.quad9.net
DNSOverTLS=yes
FallbackDNS=1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4
EOF

# Idempotent /etc/hosts update
HOSTS_MARKER="# AI stack local overrides (added by homelab setup)"
HOSTS_LINE="$STATIC_IP $DNS_DOMAIN webui.$DNS_DOMAIN ollama.$DNS_DOMAIN agent.$DNS_DOMAIN"

if ! grep -qF "$HOSTS_MARKER" /etc/hosts; then
    echo "" >> /etc/hosts
    echo "$HOSTS_MARKER" >> /etc/hosts
    echo "$HOSTS_LINE" >> /etc/hosts
    print_info "Added local domains to /etc/hosts"
else
    if ! grep -qF "$HOSTS_LINE" /etc/hosts; then
        echo "$HOSTS_LINE" >> /etc/hosts
        print_info "Added missing hosts line (marker was present)"
    else
        print_info "/etc/hosts already contains local overrides"
    fi
fi

systemctl restart systemd-resolved

timeout 5 dig @${RESOLVER_STUB} example.com >/dev/null 2>&1 || print_error "DNS resolution broken after systemd-resolved config"
print_info "systemd-resolved uses Quad9 DoT + local domains via /etc/hosts"

# -------------------------------------------------------------------------
# 8 – Ollama
# -------------------------------------------------------------------------
print_step "Ollama installation"

if ! command -v ollama >/dev/null 2>&1; then
    TMP_OLLAMA="/tmp/ollama_install.sh"
    curl -fsSL https://ollama.com/install.sh -o "$TMP_OLLAMA"
    [[ -s "$TMP_OLLAMA" ]] || print_error "Failed to download Ollama installer"
    bash "$TMP_OLLAMA"
    rm -f "$TMP_OLLAMA"
    systemctl enable --now ollama
fi

for i in {1..40}; do
    curl -s http://127.0.0.1:11434 >/dev/null 2>&1 && { print_info "Ollama API ready"; break; }
    sleep 3
done
[[ $i -le 40 ]] || print_error "Ollama not reachable after 2 minutes"

# -------------------------------------------------------------------------
# 9 – Secrets
# -------------------------------------------------------------------------
print_step "Generate secrets"

mkdir -p "$AI_STACK_DIR"
ENV_FILE="$AI_STACK_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    WEBUI_KEY=$(openssl rand -hex 32)
    AGENT_KEY=$(openssl rand -hex 32)
    cat >"$ENV_FILE" <<EOF
WEBUI_SECRET_KEY=$WEBUI_KEY
AGENT_SECRET_KEY=$AGENT_KEY
${EXTERNAL_API_KEY:+EXTERNAL_API_KEY=$EXTERNAL_API_KEY}
EOF
    chmod 600 "$ENV_FILE"
    print_info "Secrets created in $ENV_FILE"
else
    print_info "Reusing existing $ENV_FILE"
fi

# -------------------------------------------------------------------------
# 10 – Docker host address detection
# -------------------------------------------------------------------------
print_step "Docker host address"

DOCKER_VERSION=$(docker version --format '{{.Server.Version}}')
if dpkg --compare-versions "$DOCKER_VERSION" ge 20.10.0; then
    HOST_ADDRESS="host.docker.internal"
    EXTRA_HOST="host.docker.internal:host-gateway"
    print_info "Using host-gateway ($HOST_ADDRESS)"
else
    HOST_ADDRESS="$(hostname -I | awk '{print $1}')"
    EXTRA_HOST="$HOST_ADDRESS"
    print_warn "Old Docker – falling back to $HOST_ADDRESS"
fi

# -------------------------------------------------------------------------
# 11 – Docker Compose stack
# -------------------------------------------------------------------------
print_step "AI stack (OpenWebUI + AgentZero)"

mkdir -p "$AI_STACK_DIR"/{openwebui,agent-zero}/data

cat >"$AI_STACK_DIR/docker-compose.yml" <<EOF
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
print_info "Stack started"

# -------------------------------------------------------------------------
# 12 – Nginx + self-signed wildcard cert
# -------------------------------------------------------------------------
print_step "Nginx reverse proxy"

NGINX_SITE="/etc/nginx/sites-available/ai.local"
SSL_CERT="/etc/ssl/certs/ai.local.pem"
SSL_KEY="/etc/ssl/private/ai.local.key"

if [[ ! -f "$SSL_CERT" || ! -f "$SSL_KEY" ]]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -subj "/CN=*.${DNS_DOMAIN}" \
        -addext "subjectAltName=DNS:${DNS_DOMAIN},DNS:webui.${DNS_DOMAIN},DNS:ollama.${DNS_DOMAIN},DNS:agent.${DNS_DOMAIN}" \
        -keyout "$SSL_KEY" -out "$SSL_CERT"
    chmod 600 "$SSL_KEY"
    print_info "Wildcard self-signed cert created"
fi

cat >"$NGINX_SITE" <<EOF
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

nginx -t && systemctl reload nginx || print_error "Nginx config failed"
print_info "Nginx ready with wildcard TLS"

# -------------------------------------------------------------------------
# 13 – Netplan static IP (with rollback)
# -------------------------------------------------------------------------
print_step "Netplan configuration"

NETPLAN_DIR="/etc/netplan"
NETPLAN_FILE="$NETPLAN_DIR/01-homelab.yaml"
BACKUP_SUBDIR="$BACKUP_DIR/netplan"
mkdir -p "$BACKUP_SUBDIR"

# 1. Backup existing files (DO NOT DISABLE YET)
if compgen -G "$NETPLAN_DIR"/*.yaml >/dev/null; then
    print_info "Backing up existing netplan files…"
    for f in "$NETPLAN_DIR"/*.yaml; do
        [[ "$f" == "$NETPLAN_FILE" ]] && continue
        cp -a "$f" "$BACKUP_SUBDIR/$(basename "$f").bak"
        print_info "  • Backed up $f"
    done
fi

# 2. Write new config
cat >"$NETPLAN_FILE" <<EOF
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
        addresses: [${RESOLVER_STUB}]
EOF

chmod 600 "$NETPLAN_FILE"

print_step "Applying network changes"

print_info "Checking if $STATIC_IP is free…"
if arping -c 3 -w 2 -I "$IFACE" "$STATIC_IP" >/dev/null 2>&1; then
    print_error "IP $STATIC_IP is already in use – choose another"
fi

# 3. Generate (Dry run check)
netplan generate || print_error "netplan generate failed - check syntax"

# 4. Apply
if ! netplan apply; then
    journalctl -u systemd-networkd --since "5 minutes ago" | tail -30
    print_error "netplan apply failed"
fi

print_info "Waiting for $STATIC_IP…"
for i in {1..60}; do
    ip -4 addr show dev "$IFACE" | grep -q "$STATIC_IP" && break
    sleep 1
done

ip -4 addr show dev "$IFACE" | grep -q "$STATIC_IP" || print_error "Static IP never appeared"

print_step "Verifying connectivity"

if ! timeout 10 dig @${RESOLVER_STUB} google.com >/dev/null 2>&1; then
    print_error "No DNS after netplan – rolling back"
    rm -f "$NETPLAN_FILE"
    for bak in "$BACKUP_SUBDIR"/*.bak; do
        orig="${bak%.bak}"
        mv "$bak" "$orig" 2>/dev/null || true
        print_info "  • Restored $orig"
    done
    netplan apply
    print_error "Network rollback complete – check logs"
fi

# 5. Success! Now it is safe to disable old configs
if compgen -G "$BACKUP_SUBDIR"/*.bak >/dev/null; then
    print_info "Disabling old netplan configurations…"
    for bak in "$BACKUP_SUBDIR"/*.bak; do
        orig="${bak%.bak}"
        if [[ -f "$orig" ]]; then
            mv "$orig" "${orig}.disabled"
            print_info "  • Disabled $orig"
        fi
    done
fi

print_info "Static IP active + DNS working"

# -------------------------------------------------------------------------
# 14 – UFW firewall
# -------------------------------------------------------------------------
print_step "UFW firewall"

UFW_MARKER="/etc/ufw/.homelab-initialized"
if [[ ! -f "$UFW_MARKER" ]]; then
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp comment "SSH"
    ufw allow 80/tcp comment "HTTP"
    ufw allow 443/tcp comment "HTTPS"
    LAN_SUBNET="${STATIC_IP%.*}.0/${CIDR}"
    ufw allow from "$LAN_SUBNET" to any port 3000 proto tcp comment "OpenWebUI"
    ufw allow from "$LAN_SUBNET" to any port 8000 proto tcp comment "AgentZero"
    ufw allow from "$LAN_SUBNET" to any port 11434 proto tcp comment "Ollama"
    ufw limit 22/tcp comment "SSH rate limit"
    ufw --force enable
    touch "$UFW_MARKER"
    print_info "UFW enabled"
else
    print_info "UFW already configured"
fi

# -------------------------------------------------------------------------
# 15 – Fail2Ban SSH jail
# -------------------------------------------------------------------------
print_step "Fail2Ban"

FAIL2BAN_JAIL="/etc/fail2ban/jail.d/sshd.local"
if [[ ! -f "$FAIL2BAN_JAIL" ]]; then
    cat >"$FAIL2BAN_JAIL" <<EOF
[sshd]
enabled = true
port    = ssh
logpath = /var/log/auth.log
maxretry = 5
EOF
    systemctl restart fail2ban
    print_info "Fail2Ban SSH jail active"
fi

# -------------------------------------------------------------------------
# 16 – Systemd service for stack
# -------------------------------------------------------------------------
print_step "AI stack systemd service"

SERVICE_FILE="/etc/systemd/system/ai-stack.service"
cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=AI Stack (OpenWebUI + AgentZero + Ollama)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$AI_STACK_DIR
ExecStart=/usr/bin/docker compose up
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=300
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now ai-stack
print_info "ai-stack service enabled"

# -------------------------------------------------------------------------
# 17 – Sysctl hardening
# -------------------------------------------------------------------------
print_step "Sysctl hardening"

SYSCTL_CONF="/etc/sysctl.d/99-homelab.conf"
cat >"$SYSCTL_CONF" <<EOF
# Basic kernel hardening suitable for Docker host
# ip_forward must be 1 for Docker bridge NAT to work
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
fs.protected_regular = 2
fs.protected_fifos = 2
fs.protected_symlinks = 1
kernel.randomize_va_space = 2
EOF

sysctl --system
print_info "Sysctl applied"

# -------------------------------------------------------------------------
# 18 – Logrotate for installer log
# -------------------------------------------------------------------------
print_step "Logrotate"

cat >/etc/logrotate.d/homelab-setup <<EOF
$LOG_FILE {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 640 root adm
}
EOF

print_info "Logrotate configured"

# -------------------------------------------------------------------------
# 19 – Final summary
# -------------------------------------------------------------------------
print_step "Installation complete"

cat <<EOF
===================================================================
AI server ready.

Access (LAN only):
  OpenWebUI : https://$DNS_DOMAIN       (or https://$STATIC_IP)
  AgentZero : https://$DNS_DOMAIN/agent/
  Ollama    : https://$DNS_DOMAIN/ollama/

DNS: systemd-resolved stub @ $RESOLVER_STUB + Quad9 DoT
Local domains resolved via /etc/hosts

Firewall: UFW allows only LAN subnet ${STATIC_IP%.*}.0/${CIDR} for services
SSH protected by Fail2Ban

Next steps:
  1. Reboot:                sudo reboot
  2. Verify:                curl -k https://$DNS_DOMAIN
                            cd $AI_STACK_DIR && docker compose ps
                            docker run --rm alpine ping -c 3 8.8.8.8   # test container internet
  3. Browse from LAN device
===================================================================
EOF

print_info "Script finished successfully"
