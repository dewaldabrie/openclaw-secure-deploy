# OpenClaw Secure Deployment

One-click deployment of [OpenClaw](https://github.com/openclaw/openclaw) to Hetzner Cloud with traffic filtering, multi-agent security, and firewall enforcement.

## Quick Start

1. **Use this template** → create your own private repo
2. **Add secrets** → `HETZNER_VPS_IP` + `HETZNER_SSH_KEY`
3. **Run workflow** → Actions → Deploy to Hetzner → Run
4. *(Optional)* Add `DEPLOY_KEY` + `GITHUB_REPO` for automatic workspace sync

📖 **Full documentation**: [deploy/hetzner/README.md](deploy/hetzner/README.md)

## Repository Structure

```
.
├── .github/workflows/
│   └── deploy-hetzner.yml        # One-click GitHub Actions deployment
├── .devcontainer/
│   └── devcontainer.json         # Codespaces management environment
├── .gitignore                    # Keeps secrets out of git
├── README.md                     # This file
├── config/
│   └── openclaw.json             # Bootstrapping config (multi-agent, security, gateway)
├── openclaw-state/               # Auto-synced runtime state (via auto-sync branch)
│   └── .gitkeep
└── deploy/hetzner/
    ├── setup.sh                  # Server provisioning (block storage, Docker, firewall)
    ├── docker-compose.yml        # Gateway container configuration
    ├── Makefile                  # 15+ management targets (deploy, logs, tunnel, etc.)
    ├── .env.example              # Environment variable template — copy to .env
    ├── .gitignore                # Prevents committing local secrets
    ├── README.md                 # Full deployment & management documentation
    ├── proxy/
    │   ├── filter.py             # mitmproxy domain filter + Gmail write protection
    │   ├── allowed_domains.csv   # Whitelisted domains (edit to add your services)
    │   └── mitmproxy.service     # systemd unit for host-level proxy
    └── scripts/
        ├── sync-state.sh         # Workspace sync script (rsync + git push)
        ├── sync-state.service    # systemd unit for sync
        └── sync-state.timer      # Runs sync every 30 minutes
```

## What's Included

- 🔒 **mitmproxy** — domain whitelist filtering + Gmail write protection
- 🛡️ **Multi-agent** — `reader` agent isolates untrusted inputs (WhatsApp, Cron)
- 🔥 **nftables** — forces all container traffic through proxy
- 🚀 **GitHub Actions** — one-click deployment
- 💻 **Codespaces** — manage your deployment from the browser
- 📋 **Makefile** — `make deploy`, `make logs`, `make tunnel`, `make pair-whatsapp`
- 🔄 **Workspace sync** — auto-commit runtime state to GitHub every 30 minutes

## License

MIT
