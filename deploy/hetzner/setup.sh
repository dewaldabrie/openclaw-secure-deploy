#!/bin/bash
set -e

# Configuration
MOUNT_POINT="/mnt/kb"
APP_DIR="/root/openclaw-deploy"
DOCKER_COMPOSE_URL="https://raw.githubusercontent.com/openclaw/openclaw/main/deploy/hetzner/docker-compose.yml" # Placeholder, we might cp it if local

echo "🚀 Starting OpenClaw Hetzner Deployment..."

# 1. Block Storage Setup
echo "💾 Checking for Block Storage..."

# Hetzner Volumes usually appear at /dev/disk/by-id/scsi-0HC_Volume_<VOLUME_ID>
# We look for any scsi-0HC_Volume_* device
VOLUME_DEVICE=$(ls /dev/disk/by-id/scsi-0HC_Volume_* 2>/dev/null | head -n 1)

if [ -z "$VOLUME_DEVICE" ]; then
    echo "⚠️  No Hetzner Block Volume found (scsi-0HC_Volume_*)."
    echo "   Using local disk for persistence (warning: data lost on rebuild if not backed up)."
    # Fallback to a local directory if no volume? 
    # The plan mandated block storage support. We should warn loudly or exit?
    # Let's fallback but warn.
    mkdir -p "$MOUNT_POINT"
else
    echo "✅ Found Block Volume: $VOLUME_DEVICE"
    
    # Check if formatted
    if ! blkid "$VOLUME_DEVICE" | grep -q "ext4"; then
        echo "⚙️  Formatting volume $VOLUME_DEVICE to ext4..."
        mkfs.ext4 -F "$VOLUME_DEVICE"
    fi

    # Mount
    mkdir -p "$MOUNT_POINT"
    if ! mountpoint -q "$MOUNT_POINT"; then
        echo "🔗 Mounting $VOLUME_DEVICE to $MOUNT_POINT..."
        mount -o discard,defaults "$VOLUME_DEVICE" "$MOUNT_POINT"
        
        # Add to fstab for persistence
        if ! grep -q "$VOLUME_DEVICE" /etc/fstab; then
            echo "$VOLUME_DEVICE $MOUNT_POINT ext4 discard,defaults 0 0" >> /etc/fstab
        fi
    fi
    echo "✅ Volume mounted."
fi

# Ensure permissions on mount point (for uid 1000 in container)
chown 1000:1000 "$MOUNT_POINT"

# 2. Install Dependencies
echo "📦 Installing Dependencies..."
apt-get update
apt-get install -y git curl ca-certificates pipx python3-pip

# Install Docker
if ! command -v docker &>/dev/null; then
    echo "🐳 Installing Docker..."
    curl -fsSL https://get.docker.com | sh
else
    echo "✅ Docker already installed."
fi

# Install Tailscale
if ! command -v tailscale &>/dev/null; then
    echo "📶 Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
else
    echo "✅ Tailscale already installed."
fi

# 2.5 Install mitmproxy on HOST (not in Docker)
echo "🛡️  Setting up mitmproxy on host..."
if ! command -v mitmweb &>/dev/null; then
    echo "📦 Installing mitmproxy via pipx..."
    PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install mitmproxy
else
    echo "✅ mitmproxy already installed: $(mitmweb --version 2>/dev/null | head -1)"
fi


# 3. Setup Directories & Config
echo "📂 Setting up workspace..."
mkdir -p "$APP_DIR"

# Clone if empty
if [ -z "$(ls -A "$APP_DIR")" ]; then
    echo "⬇️  Cloning OpenClaw repository..."
    git clone https://github.com/openclaw/openclaw.git "$APP_DIR"
fi

cd "$APP_DIR"

# Ensure subdirectories exist on the persistent store
mkdir -p "$MOUNT_POINT/workspace"
mkdir -p "$MOUNT_POINT/seeds" 
mkdir -p "$MOUNT_POINT/secrets"
mkdir -p "$MOUNT_POINT/mitmproxy"
mkdir -p "$MOUNT_POINT/proxy"
mkdir -p "$MOUNT_POINT/cron"
mkdir -p "$MOUNT_POINT/runtime"
mkdir -p "$MOUNT_POINT/runtime/proxy/.mitmproxy"
mkdir -p "$MOUNT_POINT/user_knowledge_base"
mkdir -p "$MOUNT_POINT/agents"
mkdir -p "$MOUNT_POINT/skills"
chown -R 1000:1000 "$MOUNT_POINT"

# If the user has a custom filter.py, they should put it in $MOUNT_POINT/runtime/proxy/filter.py

# 3.3 Set up proxy filter and domains
echo "📝 Setting up proxy configuration..."
if [ -d "proxy" ]; then
    cp proxy/filter.py "$MOUNT_POINT/runtime/proxy/filter.py"
    cp proxy/allowed_domains.csv "$MOUNT_POINT/runtime/proxy/allowed_domains.csv"
    echo "✅ Proxy configuration copied from bundled files."
else
    echo "⚠️  Bundled 'proxy' directory not found. Skipping proxy setup."
fi
chown 1000:1000 "$MOUNT_POINT/runtime/proxy/filter.py" "$MOUNT_POINT/runtime/proxy/allowed_domains.csv"

# Note: allowed_domains.csv is now copied in step 3.3

# Ensure traffic.log exists
touch "$MOUNT_POINT/runtime/proxy/traffic.log"
chown 1000:1000 "$MOUNT_POINT/runtime/proxy/traffic.log"

# 3.5. Gog (Email Support) - Download to host if missing (for mounting into container)
if [ ! -f "/usr/local/bin/gog" ]; then
    echo "📧 Downloading gogcli for email support..."
    ARCH=$(dpkg --print-architecture)
    curl -L "https://github.com/steipete/gogcli/releases/download/v0.9.0/gogcli_0.9.0_linux_${ARCH}.tar.gz" | tar -xz -C /usr/local/bin gog
    chmod +x /usr/local/bin/gog
fi

# 3.6 Setup mitmproxy systemd service
echo "🛡️  Configuring mitmproxy systemd service from bundle..."
if [ -f "proxy/mitmproxy.service" ]; then
    cp proxy/mitmproxy.service /etc/systemd/system/mitmproxy.service
    echo "✅ mitmproxy.service installed."
else
    echo "❌ mitmproxy.service not found in bundle! Proxy service may fail."
fi

systemctl daemon-reload
systemctl enable mitmproxy

# 3.7 Setup Chromium Wrapper for Puppeteer to accept mitmproxy cert
echo "🌐 Setting up Chromium wrapper for Puppeteer..."
cat > "$MOUNT_POINT/runtime/proxy/chromium-wrapper.sh" <<'WRAPPER'
#!/bin/bash
exec /usr/bin/chromium --proxy-server="http://127.0.0.1:8080" --ignore-certificate-errors "$@"
WRAPPER
chown 1000:1000 "$MOUNT_POINT/runtime/proxy/chromium-wrapper.sh"
chmod +x "$MOUNT_POINT/runtime/proxy/chromium-wrapper.sh"

# Start mitmproxy to generate CA certs if they don't exist yet
CERT_PATH="$MOUNT_POINT/runtime/proxy/.mitmproxy/mitmproxy-ca-cert.pem"
if [ ! -f "$CERT_PATH" ]; then
    echo "🔐 Generating mitmproxy CA certificates..."
    systemctl start mitmproxy
    echo "⏳ Waiting for CA certificate generation..."
    for i in {1..30}; do
        if [ -f "$CERT_PATH" ]; then
            echo "✅ CA certificate generated."
            break
        fi
        sleep 1
        echo -n "."
    done
    if [ ! -f "$CERT_PATH" ]; then
        echo ""
        echo "❌ Timeout waiting for mitmproxy CA cert. Check: journalctl -u mitmproxy"
        exit 1
    fi
else
    echo "✅ mitmproxy CA certificate already exists."
    systemctl start mitmproxy
fi

# Ensure certs are readable by container user (uid 1000)
chmod 644 "$CERT_PATH" 2>/dev/null || true


# 4. Environment Variables
ENV_FILE=".env"
if [ ! -f "$ENV_FILE" ]; then
    echo "📝 Configuring Environment..."
    if [ -z "$OPENCLAW_GATEWAY_TOKEN" ]; then
        if [ -t 0 ]; then
            read -p "Enter Gateway Token (auto-generate? [y/N]): " GEN_TOKEN
            if [[ "$GEN_TOKEN" =~ [yY](es)* ]]; then
                OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32)
                echo "🔑 Generated Token: $OPENCLAW_GATEWAY_TOKEN"
            else
                read -p "Enter Gateway Token: " OPENCLAW_GATEWAY_TOKEN
            fi
        else
            echo "⚠️  Non-interactive mode. Auto-generating Gateway Token."
            OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32)
            echo "🔑 Generated Token: $OPENCLAW_GATEWAY_TOKEN"
        fi
    fi

    cat > "$ENV_FILE" <<EOF
OPENCLAW_IMAGE=ghcr.io/openclaw/openclaw@sha256:ce9347548afa0b6bdd1d262060535ba04baf0b19cde0fc211c8039492647d1b1
OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}
OPENCLAW_GATEWAY_BIND=127.0.0.1
OPENCLAW_GATEWAY_PORT=18789
TAILSCALE_AUTH_KEY=
GOG_KEYRING_PASSWORD=$(openssl rand -hex 16)
XDG_CONFIG_HOME=/home/node/.openclaw
EOF
    echo "✅ .env created."
else
    echo "✅ .env exists, skipping."
fi

# Load environment for scripts
set -a
source "$ENV_FILE"
set +a

# 5. Docker Compose
# The source of truth is now deploy/hetzner/docker-compose.yml
# We use the version already in the repo directory.
COMPOSE_FILE="docker-compose.yml"

if [ ! -f "$COMPOSE_FILE" ]; then
    echo "⚠️  $COMPOSE_FILE not found in current directory. Attempting to download..."
    curl -fsSL "$DOCKER_COMPOSE_URL" -o "$COMPOSE_FILE"
fi

echo "✅ Using $COMPOSE_FILE as source of truth."

# 6. Tailscale Connect
# We do this before launch so interfaces are ready
echo "📶 Checking Tailscale..."
if ! tailscale status &>/dev/null; then
    # Prioritize environment variable, then .env file
    if [ -n "$TAILSCALE_AUTH_KEY" ]; then
        TS_KEY="$TAILSCALE_AUTH_KEY"
    else
        TS_KEY=$(grep "TAILSCALE_AUTH_KEY" "$ENV_FILE" | cut -d= -f2-)
    fi
    
    if [ -z "$TS_KEY" ]; then
        # Check if we assume interactive? If stdin is a TTY?
        if [ -t 0 ]; then
             read -p "Enter Tailscale Auth Key (leave blank to skip auto-connect): " TS_KEY_INPUT
             TS_KEY="$TS_KEY_INPUT"
        else
             echo "⚠️  Non-interactive mode and no TAILSCALE_AUTH_KEY found. Skipping Tailscale."
        fi
    fi

    if [ -n "$TS_KEY" ]; then
         tailscale up --authkey="$TS_KEY"
    else
         echo "⚠️  Skipping Tailscale connection (manual 'tailscale up' required)."
    fi
else
    echo "✅ Tailscale connected."
fi

# Configure Tailscale Serve if connected
if tailscale status &>/dev/null; then
    PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
    echo "🌐 Configuring Tailscale Serve on port $PORT..."
    tailscale serve --bg "http://127.0.0.1:${PORT}"
    echo "✅ Tailscale Serve enabled."
fi

# 7. Create CLI Wrapper
echo "⌨️  Creating OpenClaw CLI wrapper..."
cat > /usr/local/bin/openclaw <<'WRAPPER'
#!/bin/bash
docker exec -it openclaw-gateway npm exec -- openclaw "$@"
WRAPPER
chmod +x /usr/local/bin/openclaw

# 7.5 Firewall: Force all gateway (uid 1000) traffic through the proxy
# With network_mode: host, the gateway shares the host's network stack.
# Without these rules, the agent could bypass HTTP_PROXY by making direct TCP connections.
# We use nftables (not iptables) because xt_owner can't match UIDs on non-loopback interfaces
# on modern kernels, but nftables' `meta skuid` works correctly.
echo "🔒 Configuring firewall to enforce proxy usage..."

# Enable IPv4 localnet routing so DNAT to 127.0.0.1 works for transparent proxying
sysctl -w net.ipv4.conf.all.route_localnet=1
sysctl -w net.ipv4.conf.eth0.route_localnet=1
echo "net.ipv4.conf.all.route_localnet=1" >> /etc/sysctl.conf
echo "net.ipv4.conf.eth0.route_localnet=1" >> /etc/sysctl.conf
sysctl -p

# Create/flush nftables table (idempotent)
nft add table inet openclaw 2>/dev/null || true
nft flush table inet openclaw

# Allow uid 1000 only on loopback (proxy on 127.0.0.1:8080, gateway on 127.0.0.1:18789)
# Reject all other outbound from uid 1000 — no direct internet access
nft add chain inet openclaw output '{ type filter hook output priority 0 ; policy accept ; }'
nft add rule inet openclaw output meta skuid 1000 oifname lo accept
nft add rule inet openclaw output meta skuid 1000 udp dport 53 accept
nft add rule inet openclaw output meta skuid 1000 tcp dport 53 accept
nft add rule inet openclaw output meta skuid 1000 tcp dport 8082 accept
nft add rule inet openclaw output meta skuid 1000 counter reject

# Transparent proxy redirect for direct TCP connections (e.g. Baileys WebSockets, or rogue agents)
nft add chain inet openclaw nat_output '{ type nat hook output priority dstnat ; policy accept ; }'
# We must use dnat instead of redirect for locally generated packets across namespaces/host net to trigger routing properly
nft add rule inet openclaw nat_output meta skuid 1000 oifname != "lo" meta nfproto ipv4 tcp dport \{ 80, 443, 5222 \} counter dnat ip to 127.0.0.1:8082
nft add rule inet openclaw nat_output meta skuid 1000 oifname != "lo" meta nfproto ipv6 tcp dport \{ 80, 443, 5222 \} counter redirect to :8082

echo "✅ Firewall rules active: uid 1000 restricted to loopback only (nftables)."

# Persist nftables rules across reboots
mkdir -p /etc/nftables.d
nft list table inet openclaw > /etc/nftables.d/openclaw.conf 2>/dev/null || true
# Ensure the include is in the main nftables config
if [ -f /etc/nftables.conf ] && ! grep -q "openclaw" /etc/nftables.conf; then
    echo 'include "/etc/nftables.d/openclaw.conf"' >> /etc/nftables.conf
fi

# 7.6 Workspace Git Sync (optional — requires DEPLOY_KEY and GITHUB_REPO)
DEPLOY_KEY_PATH="/root/.ssh/deploy_key"
STATE_REPO_DIR="/root/openclaw-state-repo"

if [ -f "$DEPLOY_KEY_PATH" ] && [ -n "${GITHUB_REPO:-}" ]; then
    echo "🔄 Setting up workspace git sync..."

    # Configure SSH for GitHub
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    chmod 600 "$DEPLOY_KEY_PATH"
    cat > /root/.ssh/config <<'SSHCONF'
Host github.com
    IdentityFile /root/.ssh/deploy_key
    StrictHostKeyChecking accept-new
SSHCONF
    chmod 600 /root/.ssh/config

    # Clone repo if not already present
    if [ ! -d "$STATE_REPO_DIR/.git" ]; then
        echo "📥 Cloning state repo..."
        git clone "$GITHUB_REPO" "$STATE_REPO_DIR"
    fi

    # Configure git identity
    cd "$STATE_REPO_DIR"
    git config user.email "openclaw-sync@$(hostname)"
    git config user.name "OpenClaw Sync"
    cd "$APP_DIR"

    # Install sync timer
    if [ -d "scripts" ]; then
        cp scripts/sync-state.service /etc/systemd/system/sync-state.service
        cp scripts/sync-state.timer /etc/systemd/system/sync-state.timer
        systemctl daemon-reload
        systemctl enable --now sync-state.timer
        echo "✅ Workspace sync enabled (every 30 minutes)."
        echo "   View status: systemctl status sync-state.timer"
        echo "   View logs:   journalctl -u sync-state -f"
    else
        echo "⚠️  scripts/ directory not found. Skipping sync timer install."
    fi
else
    echo "ℹ️  Workspace sync not configured (set DEPLOY_KEY + GITHUB_REPO to enable)."
fi

# 8. Launch
echo "🚀 Launching OpenClaw..."
docker compose -f "$COMPOSE_FILE" pull

# Ensure mitmproxy is running before starting gateway
echo "🛡️  Ensuring mitmproxy is running..."
systemctl start mitmproxy
sleep 2
if systemctl is-active --quiet mitmproxy; then
    echo "✅ mitmproxy is running."
else
    echo "❌ mitmproxy failed to start. Check: journalctl -u mitmproxy -n 50"
    exit 1
fi

# Start gateway
echo "🚀 Starting Gateway..."
docker compose -f "$COMPOSE_FILE" up -d

echo ""
echo "✅ Deployment Complete!"
echo "   Gateway:     http://127.0.0.1:${OPENCLAW_GATEWAY_PORT:-18789}"
echo "   mitmweb UI:  http://127.0.0.1:8081"
echo "   SSH Tunnel:  ssh -N -L 18789:127.0.0.1:18789 -L 8081:127.0.0.1:8081 root@<YOUR_IP>"
echo "   Token:       ${OPENCLAW_GATEWAY_TOKEN}"
echo ""
echo "   Proxy management:"
echo "     systemctl status mitmproxy    # check proxy status"
echo "     systemctl restart mitmproxy   # restart proxy"
echo "     journalctl -u mitmproxy -f    # proxy logs"
nft delete table ip openclaw_nat 2>/dev/null || true
nft delete table inet openclaw_fw 2>/dev/null || true
