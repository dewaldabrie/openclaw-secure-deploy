# OpenClaw Hetzner Secure Deployment Management
# Usage: make <target> VPS_IP=<your-vps-ip>
#
# Set VPS_IP via environment or .env file:
#   export VPS_IP=<YOUR_VPS_IP>
#   make deploy

-include .env

VPS_IP ?= $(error Set VPS_IP via env or .env file. Example: export VPS_IP=203.0.113.50)
SSH_USER ?= root
SSH_OPTS ?= -o StrictHostKeyChecking=accept-new
REMOTE_DIR ?= ~/openclaw-deploy
GATEWAY_PORT ?= 18789
MITMWEB_PORT ?= 8081

# ── Deployment ──────────────────────────────────────────

.PHONY: deploy
deploy: ## Bundle and deploy to VPS
	scp $(SSH_OPTS) -r . $(SSH_USER)@$(VPS_IP):$(REMOTE_DIR)
	ssh $(SSH_OPTS) $(SSH_USER)@$(VPS_IP) "cd $(REMOTE_DIR) && bash setup.sh"

.PHONY: push-config
push-config: ## Push config files only (no full setup)
	scp $(SSH_OPTS) -r proxy/ $(SSH_USER)@$(VPS_IP):$(REMOTE_DIR)/proxy/
	scp $(SSH_OPTS) docker-compose.yml $(SSH_USER)@$(VPS_IP):$(REMOTE_DIR)/docker-compose.yml
	ssh $(SSH_OPTS) $(SSH_USER)@$(VPS_IP) \
		"cp $(REMOTE_DIR)/proxy/filter.py /mnt/kb/runtime/proxy/filter.py && \
		 cp $(REMOTE_DIR)/proxy/allowed_domains.csv /mnt/kb/runtime/proxy/allowed_domains.csv && \
		 chown 1000:1000 /mnt/kb/runtime/proxy/filter.py /mnt/kb/runtime/proxy/allowed_domains.csv"

# ── Service Management ──────────────────────────────────

.PHONY: restart
restart: ## Restart gateway + proxy
	ssh $(SSH_OPTS) $(SSH_USER)@$(VPS_IP) \
		"systemctl restart mitmproxy && cd $(REMOTE_DIR) && docker compose restart openclaw-gateway"

.PHONY: restart-gateway
restart-gateway: ## Restart gateway only
	ssh $(SSH_OPTS) $(SSH_USER)@$(VPS_IP) "cd $(REMOTE_DIR) && docker compose restart openclaw-gateway"

.PHONY: restart-proxy
restart-proxy: ## Restart mitmproxy only
	ssh $(SSH_OPTS) $(SSH_USER)@$(VPS_IP) "systemctl restart mitmproxy"

.PHONY: stop
stop: ## Stop all services
	ssh $(SSH_OPTS) $(SSH_USER)@$(VPS_IP) \
		"cd $(REMOTE_DIR) && docker compose down && systemctl stop mitmproxy"

# ── Monitoring ──────────────────────────────────────────

.PHONY: status
status: ## Check status of all services
	@ssh $(SSH_OPTS) $(SSH_USER)@$(VPS_IP) \
		"echo '── Gateway ──' && cd $(REMOTE_DIR) && docker compose ps && \
		 echo '' && echo '── Proxy ──' && systemctl status mitmproxy --no-pager -l"

.PHONY: logs
logs: ## Stream gateway logs
	ssh $(SSH_OPTS) $(SSH_USER)@$(VPS_IP) "cd $(REMOTE_DIR) && docker compose logs -f --tail=100"

.PHONY: logs-proxy
logs-proxy: ## Stream proxy logs
	ssh $(SSH_OPTS) $(SSH_USER)@$(VPS_IP) "journalctl -u mitmproxy -f"

# ── Access ──────────────────────────────────────────────

.PHONY: tunnel
tunnel: ## Open SSH tunnel (gateway + mitmweb)
	@echo "🔗 Tunneling gateway (localhost:$(GATEWAY_PORT)) and mitmweb (localhost:$(MITMWEB_PORT))..."
	@echo "   Open http://localhost:$(GATEWAY_PORT) in your browser."
	ssh $(SSH_OPTS) -N \
		-L $(GATEWAY_PORT):127.0.0.1:$(GATEWAY_PORT) \
		-L $(MITMWEB_PORT):127.0.0.1:$(MITMWEB_PORT) \
		$(SSH_USER)@$(VPS_IP)

.PHONY: ssh
ssh: ## Open interactive SSH session
	ssh $(SSH_OPTS) $(SSH_USER)@$(VPS_IP)

# ── Device Pairing ──────────────────────────────────────

.PHONY: pair-whatsapp
pair-whatsapp: ## Pair WhatsApp (interactive — scan QR code)
	ssh $(SSH_OPTS) -t $(SSH_USER)@$(VPS_IP) \
		"docker exec -it -w /app openclaw-gateway node /app/openclaw.mjs channels login --channel whatsapp --verbose"

.PHONY: logout-whatsapp
logout-whatsapp: ## Logout of WhatsApp and clear session
	ssh $(SSH_OPTS) -t $(SSH_USER)@$(VPS_IP) \
		"docker exec -it -w /app openclaw-gateway node /app/openclaw.mjs channels logout --channel whatsapp"

.PHONY: pair-telegram
pair-telegram: ## Pair Telegram bot
	ssh $(SSH_OPTS) -t $(SSH_USER)@$(VPS_IP) \
		"docker exec -it -w /app openclaw-gateway node /app/openclaw.mjs channels login --channel telegram --verbose"

.PHONY: onboard-openrouter
onboard-openrouter: ## Set up OpenRouter API Key
	ssh $(SSH_OPTS) -t $(SSH_USER)@$(VPS_IP) \
		"docker exec -it -w /app openclaw-gateway npm exec openclaw onboard --auth-choice apiKey --token-provider openrouter --token \"\$$OPENROUTER_API_KEY\""

# ── Security ────────────────────────────────────────────

.PHONY: rotate-token
rotate-token: ## Generate and set a new gateway token
	$(eval NEW_TOKEN := $(shell openssl rand -hex 32))
	@echo "🔑 New token: $(NEW_TOKEN)"
	ssh $(SSH_OPTS) $(SSH_USER)@$(VPS_IP) \
		"cd $(REMOTE_DIR) && sed -i 's/^OPENCLAW_GATEWAY_TOKEN=.*/OPENCLAW_GATEWAY_TOKEN=$(NEW_TOKEN)/' .env && docker compose restart openclaw-gateway"
	@echo "✅ Token rotated. Update your client settings with the new token above."

.PHONY: push-gcp-creds
push-gcp-creds: ## Push GCP credentials JSON to VPS (usage: make push-gcp-creds FILE=path/to/creds.json)
	@test -n "$(FILE)" || (echo "❌ Usage: make push-gcp-creds FILE=path/to/credentials.json" && exit 1)
	ssh $(SSH_OPTS) $(SSH_USER)@$(VPS_IP) "mkdir -p /mnt/kb/runtime/secrets && chown 1000:1000 /mnt/kb/runtime/secrets"
	scp $(SSH_OPTS) $(FILE) $(SSH_USER)@$(VPS_IP):/mnt/kb/runtime/secrets/gcp-credentials.json
	ssh $(SSH_OPTS) $(SSH_USER)@$(VPS_IP) \
		"chmod 600 /mnt/kb/runtime/secrets/gcp-credentials.json && chown 1000:1000 /mnt/kb/runtime/secrets/gcp-credentials.json"
	@echo "✅ GCP credentials pushed. Run 'make ssh' then 'gog auth add ...' to complete setup."

# ── CLI ─────────────────────────────────────────────────

.PHONY: cli
cli: ## Run openclaw CLI command (usage: make cli CMD="status")
	ssh $(SSH_OPTS) -t $(SSH_USER)@$(VPS_IP) \
		"docker exec -it -w /app openclaw-gateway node /app/openclaw.mjs $(CMD)"

# ── Workspace Sync ─────────────────────────────────────

.PHONY: sync-status
sync-status: ## Check workspace sync timer status
	@ssh $(SSH_OPTS) $(SSH_USER)@$(VPS_IP) "systemctl status sync-state.timer --no-pager -l 2>/dev/null || echo 'Sync timer not installed'"

.PHONY: sync-logs
sync-logs: ## Stream workspace sync logs
	ssh $(SSH_OPTS) $(SSH_USER)@$(VPS_IP) "journalctl -u sync-state -f"

.PHONY: sync-now
sync-now: ## Trigger workspace sync immediately
	ssh $(SSH_OPTS) $(SSH_USER)@$(VPS_IP) "systemctl start sync-state"
	@echo "✅ Sync triggered. Check logs: make sync-logs"

# ── Help ────────────────────────────────────────────────

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
