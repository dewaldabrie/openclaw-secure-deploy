# OpenClaw Secure Deployment for Hetzner Cloud

Deploy [OpenClaw](https://github.com/openclaw/openclaw) to a Hetzner Cloud VPS with:
- 🔒 **mitmproxy traffic filtering** — domain whitelist, Gmail write protection
- 🛡️ **Multi-agent security** — `reader` agent isolates untrusted inputs (WhatsApp, Cron)
- 🔥 **nftables enforcement** — all container traffic forced through the proxy
- 📦 **One-click deployment** via GitHub Actions
- 🔄 **Workspace sync** — auto-commit runtime state to GitHub every 30 minutes

## Getting Started

1. **Click "Use this template"** (or fork) to create your own private repo
2. **Create a Hetzner VPS** — Ubuntu 24.04, attach a Block Storage volume
3. **Set up SSH access** to the VPS:
   - Ensure the VPS has your SSH **public** key in `/root/.ssh/authorized_keys`
   - You will paste the corresponding **private** key into the `HETZNER_SSH_KEY` secret below
4. **Add GitHub Environment Secrets** (Settings → Environments → `dewald-hetzner-prod` → Add secret):

   | Secret | Required | Value |
   |---|---|---|
   | `HETZNER_VPS_IP` | ✅ | Your VPS IP address |
   | `HETZNER_SSH_KEY` | ✅ | SSH **private** key whose corresponding **public** key is in the VM's `/root/.ssh/authorized_keys` (paste the full PEM block) |
   | `GCP_CREDENTIALS_JSON` | Optional | GCP service account JSON for email |
   | `DEPLOY_KEY` | Optional | SSH **private** key for workspace sync — generate on the VM (see [Workspace Sync](#workspace-sync)) |
   | `SYNC_REPO` | Optional | SSH repo URL for workspace sync, e.g. `git@github.com:you/your-repo.git` |

5. **Run the workflow**: Actions → **Deploy to Hetzner** → **Run workflow**
6. **Complete setup**:
   ```bash
   ssh root@<YOUR_VPS_IP>
   openclaw onboard
   ```

That's it! 🎉

---

## Architecture

```
┌──────────────┐        ┌───────────────────────────────────────────────┐
│  Your Device │──SSH──▶│  Hetzner VPS                                  │
│              │        │                                               │
│  Browser     │◀─tunnel│  ┌──────────────┐  ┌────────────┐             │
│  localhost:  │        │  │ Docker       │  │ mitmproxy  │             │
│    18789     │        │  │  openclaw-gw │──│  (systemd) │             │
│    8081      │        │  └──────────────┘  └────────────┘             │
└──────────────┘        │       │                  │                    │
                        │  /mnt/kb (Block Storage) │                    │
                        │  ┌───────────────────────┴─────┐              │
                        │  │ runtime/ agents/ skills/    │              │
                        │  │ secrets/ proxy/ workspace/  │              │
                        │  └─────────────────────────────┘              │
                        │             │                                 │
                        │  ┌──────────▼───────────┐                     │
                        │  │  sync-state.timer    │───────┐             │
                        │  │  (every 30 mins)     │       │             │
                        │  └──────────────────────┘       ▼             │
                        └─────────────────────────────────┼─────────────┘
                                                          │
                                                          ▼
                                                  ┌───────────────┐
                                                  │ GitHub Repo   │
                                                  │  (auto-sync)  │
                                                  └───────────────┘
```

### Security Layers

| Layer | Protection |
|---|---|
| **Explicit Proxy** | `HTTP_PROXY` enforces filtering for cooperative apps on port 8080. |
| **Transparent Proxy** | nftables DNAT loopback routing forces *all non-cooperative outbound TCP traffic* transparently through `mitmproxy` on port 8082, preventing any firewall bypass (e.g., Baileys WebSockets). |
| **Chromium Wrapper** | Bundled `chromium-wrapper.sh` automatically configures Puppeteer instances (e.g., WhatsApp pairing) to trust the proxy CA. |
| **Firewall (nftables)** | Outbound traffic from `uid 1000` is strictly limited to localhost loopback, DNS (udp/tcp 53), and proxy mitigation ports. Direct internet access is blocked. |
| **Multi-agent** | `reader` agent has no exec/write/browser tools. |
| **Container** | Non-root (uid 1000), capability restrictions, no-new-privileges. |
| **Network** | Gateway on loopback only, SSH tunnel for access. |

---

## Deployment Methods

### Method 1: GitHub Actions ⭐ (Recommended)

See [Getting Started](#getting-started) above. Zero local tools needed — just a browser.

### Method 2: Terminal

```bash
# From this repo root
scp -r deploy/hetzner root@<YOUR_VPS_IP>:~/openclaw-deploy
ssh root@<YOUR_VPS_IP> "cd ~/openclaw-deploy && bash setup.sh"
```

### Method 3: Makefile

For ongoing management (requires `make`, pre-installed on macOS/Linux):

```bash
cd deploy/hetzner
export VPS_IP=<YOUR_VPS_IP>
make help   # Show all available targets
```

---

## Managing Your Deployment

### From GitHub Codespaces

Open a Codespace on your repo for a zero-install management environment:

1. **Configure Codespace Secrets**: Go to repo Settings → Secrets and variables → Codespaces. Add a repository secret named `VPS_IP` with your Hetzner IP.
2. Click **Code** → **Codespaces** → **Create codespace on main**
3. In the terminal:
   ```bash
   cd deploy/hetzner
   
   # Set up SSH key (one-time if you don't use Codespace secrets for it)
   echo "$SSH_KEY" > ~/.ssh/id_rsa && chmod 600 ~/.ssh/id_rsa
   
   make help   # See all available commands
   ```

### Quick Reference

```bash
# ── Deployment ──
make deploy            # Full deploy (scp + setup.sh)
make push-config       # Push config changes only

# ── Services ──
make restart           # Restart everything
make restart-gateway   # Restart gateway only
make restart-proxy     # Restart proxy only
make stop              # Stop all services

# ── Monitoring ──
make status            # Service status overview
make logs              # Stream gateway logs
make logs-proxy        # Stream proxy logs

# ── Access ──
make tunnel            # SSH tunnel (gateway + mitmweb)
make ssh               # Interactive shell

# ── Device Pairing ──
make pair-whatsapp     # Pair WhatsApp (scan QR)
make pair-telegram     # Pair Telegram bot

# ── Security ──
make rotate-token      # Generate new gateway token
make push-gcp-creds FILE=creds.json  # Push GCP credentials

# ── CLI ──
make cli CMD="status"  # Run any openclaw CLI command

# ── Workspace Sync ──
make sync-status       # Check sync timer status
make sync-logs         # Stream sync logs
make sync-now          # Trigger sync immediately
```

### Google/Email Setup (gog)

```bash
make push-gcp-creds FILE=path/to/gcp-credentials.json

make ssh
docker exec -it openclaw-gateway bash
export SSL_CERT_FILE=/home/node/.openclaw/.mitmproxy/mitmproxy-ca-cert.pem
gog auth add your-email@gmail.com --services gmail,calendar,drive,contacts,docs,sheets --manual
```

---

## Workspace Sync

Automatically back up your OpenClaw runtime state to this repo every 30 minutes.

### Setup

1. **Generate the deploy key on your Hetzner VM**:
   ```bash
   ssh root@<YOUR_VPS_IP>
   ssh-keygen -t ed25519 -C "openclaw-sync" -f /root/.ssh/deploy_key -N ""
   cat /root/.ssh/deploy_key.pub   # Copy this for step 2
   cat /root/.ssh/deploy_key       # Copy this for step 3
   ```
2. **Add the public key** to your GitHub repo: Settings → Deploy keys → Add deploy key → paste the `.pub` output → ✅ **Enable "Allow write access"**
3. **Add the private key** as the `DEPLOY_KEY` secret in your GitHub environment (`dewald-hetzner-prod`)
4. **Add `SYNC_REPO`** secret with your SSH repo URL (e.g. `git@github.com:you/your-repo.git`)
5. **Re-run the deploy workflow** — `setup.sh` will configure the SSH config, clone the repo, and enable the systemd sync timer

### How it works

- A systemd timer runs `sync-state.sh` every 30 minutes
- State from `/mnt/kb/runtime/` is rsynced to `openclaw-state/` in the repo
- Changes are pushed to the `auto-sync` branch (rebased on `main`)
- Secrets, certs, caches, and logs are excluded
- Merge `auto-sync` → `main` via PR whenever you want

### Management

```bash
make sync-status       # Check timer status
make sync-logs         # Stream sync logs
make sync-now          # Run sync immediately
```

---

## Customization

| What | Where | How to apply |
|---|---|---|
| OpenClaw config | `config/openclaw.json` | Edit before deploy, then `make push-config && make restart` |
| Environment vars | `deploy/hetzner/.env` (on VPS) | `make restart` |
| Docker config | `deploy/hetzner/docker-compose.yml` | `make push-config && make restart` |
| Proxy filter | `deploy/hetzner/proxy/filter.py` | `make push-config && make restart-proxy` |
| Allowed domains | `deploy/hetzner/proxy/allowed_domains.csv` | `make push-config && make restart-proxy` |

---

## File Structure

```
.
├── .github/workflows/
│   └── deploy-hetzner.yml    # One-click deployment workflow
├── .devcontainer/
│   └── devcontainer.json     # Codespaces environment
├── openclaw-state/           # Auto-synced runtime state
├── config/
│   └── openclaw.json         # Bootstrapping config (edit before first deploy)
└── deploy/hetzner/
    ├── setup.sh              # Server provisioning script
    ├── docker-compose.yml    # Gateway container config
    ├── Makefile              # Management targets
    ├── .env.example          # Environment variable template
    ├── proxy/
    │   ├── filter.py         # mitmproxy domain filter
    │   ├── allowed_domains.csv  # Whitelisted domains
    │   └── mitmproxy.service # systemd service definition
    └── scripts/
        ├── sync-state.sh     # Workspace sync script
        ├── sync-state.service  # systemd unit
        └── sync-state.timer  # Runs every 30 minutes
```

## License

MIT
