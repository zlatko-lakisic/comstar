.PHONY: doctor bridge-dev kiosk-dev audio-sync deploy logs test stt-dev verify-cpai ao-hello

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
	python3 scripts/stt_server.py

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

test:
	cd terminal/bridge && dart test
	cd terminal/audio && python3 -m unittest test_capture test_stream test_wakeword test_vad test_devices

verify-cpai:
	@CPAI_URL=$${CPAI_URL:-http://10.0.10.16:32168} ./scripts/verify_cpai.sh

ao-hello:
	@cd spike && dart run reach_hello.dart
