.PHONY: doctor bridge-dev kiosk-dev audio-sync deploy logs test stt-dev verify-cpai ao-hello site-dev site-build admin console

ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
REMOTE ?= comstar
REMOTE_DIR ?= /opt/comstar/src

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

logs:
	@ssh "$(REMOTE)" 'journalctl --user -u comstar-bridge -u comstar-audio -u comstar-kiosk -n 80 --no-pager'

admin console:
	@echo "COMSTAR admin: http://127.0.0.1:8781/admin/"
	@echo "Requires SSH LocalForward 8781 (or LAN + ?token=)."
	@echo "Probe: curl -sS http://127.0.0.1:8781/admin/health"
	@command -v open >/dev/null && open "http://127.0.0.1:8781/admin/" || true

test:
	cd terminal/bridge && dart test
	cd terminal/audio && python3 -m unittest test_capture test_stream test_wakeword test_vad test_devices

verify-cpai:
	@CPAI_URL=$${CPAI_URL:-http://10.0.10.16:32168} ./scripts/verify_cpai.sh

ao-hello:
	@cd spike && dart run reach_hello.dart

site-dev: ## product page at :4321
	cd site && npm run dev

site-build: ## build product page to site/dist
	cd site && npm run build
