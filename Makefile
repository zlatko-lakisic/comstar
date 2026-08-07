.PHONY: doctor bridge-dev kiosk-dev audio-sync deploy logs test stt-dev verify-cpai ao-hello site-dev site-build admin console pi-session plymouth soak road-vpn ao-mtls-enroll channel-test channel-dev

ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
REMOTE ?= comstar
REMOTE_DIR ?= /opt/comstar/src
CONFIG ?= config/comstar.yaml

doctor:
	@bash scripts/doctor.sh

bridge-dev:
	cd terminal/bridge && dart run bin/comstar_bridge.dart --config ../../config/comstar.dev.yaml

kiosk-dev:
	cd terminal/kiosk && npm start

stt-dev:
	python3 scripts/stt_server_whisper.py --host 127.0.0.1 --port 8090 --model tiny --beam-size 5

audio-sync:
	rsync -az --delete \
	  --exclude '__pycache__/' \
	  --exclude '*.pyc' \
	  "$(ROOT)terminal/audio/" "$(REMOTE):$(REMOTE_DIR)/terminal/audio/"
	ssh "$(REMOTE)" 'systemctl --user restart comstar-audio.service && echo audio restarted'

deploy:
	@COMSTAR_DEPLOY_HOST="$(REMOTE)" bash deploy/deploy.sh

pi-session:
	@ssh "$(REMOTE)" "bash $(REMOTE_DIR)/scripts/install-pi-session.sh"

plymouth:
	@ssh "$(REMOTE)" "sudo bash $(REMOTE_DIR)/scripts/install-plymouth-comstar.sh"

road-vpn:
	@ssh "$(REMOTE)" "sudo bash $(REMOTE_DIR)/scripts/install-road-vpn.sh"

# Headless AO mTLS enroll (ADR 0013). Mint token on Ada first.
#   make ao-mtls-enroll TOKEN=… CONFIG=config/comstar.yaml
# Or on the Pi after deploy:
#   ssh comstar-lan 'cd /opt/comstar/src && TOKEN=… make ao-mtls-enroll'
ao-mtls-enroll:
	@test -n "$(TOKEN)" || (echo 'TOKEN=<ada-mint-token> required' >&2; exit 2)
	cd terminal/bridge && TOKEN="$(TOKEN)" dart run tool/ao_mtls_enroll.dart --config "../../$(CONFIG)" $(if $(CLIENT_NAME),--client-name "$(CLIENT_NAME)",)

logs:
	@ssh "$(REMOTE)" 'journalctl --user -u comstar-bridge -u comstar-audio -u comstar-kiosk -n 80 --no-pager'

admin console:
	@echo "COMSTAR admin: http://127.0.0.1:8781/admin/"
	@echo "Requires SSH LocalForward 8781 (or LAN + ?token=)."
	@echo "Probe: curl -sS http://127.0.0.1:8781/admin/health"
	@command -v open >/dev/null && open "http://127.0.0.1:8781/admin/" || true

test:
	cd terminal/bridge && dart test
	cd channel && dart test
	cd terminal/audio && python3 -m unittest test_capture test_stream test_wakeword test_vad test_devices

channel-test:
	cd channel && dart test

# Ada-side text channel (Telegram). Requires TELEGRAM_BOT_TOKEN + allowlist.
# Example:
#   TELEGRAM_BOT_TOKEN=… COMSTAR_CHANNEL_ALLOWLIST='{"123":"zlatko"}' \
#   AO_BASE_URL=https://127.0.0.1:8765 COMSTAR_AO_MTLS=1 make channel-dev
channel-dev:
	cd channel && dart run bin/comstar_channel.dart

verify-cpai:
	@CPAI_URL=$${CPAI_URL:-http://10.0.10.16:32168} ./scripts/verify_cpai.sh

ao-hello:
	@cd spike && dart run reach_hello.dart

# Detached 24h soak on the Pi (M9). Override hours: COMSTAR_SOAK_HOURS=1 make soak
soak:
	@ssh "$(REMOTE)" 'export XDG_RUNTIME_DIR=/run/user/$$(id -u); \
	  mkdir -p $$HOME/.local/share/comstar/soak; \
	  nohup $(REMOTE_DIR)/scripts/comstar_soak.sh \
	    > $$HOME/.local/share/comstar/soak-nohup.log 2>&1 & \
	  echo "soak pid $$!"; pgrep -af comstar_soak | head -3; \
	  echo "log: $$HOME/.local/share/comstar/soak-nohup.log"'

site-dev: ## product page at :4321
	cd site && npm run dev

site-build: ## build product page to site/dist
	cd site && npm run build
