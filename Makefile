.PHONY: doctor bridge-dev kiosk-dev audio-sync deploy logs test stt-dev

ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

doctor:
	@bash scripts/doctor.sh

bridge-dev:
	cd terminal/bridge && dart run bin/comstar_bridge.dart --config ../../config/comstar.dev.yaml

kiosk-dev:
	cd terminal/kiosk && npm start

stt-dev:
	python3 scripts/stt_server.py

audio-sync:
	@echo "stub: rsync terminal/audio/ to comstar:~/comstar/terminal/audio/ and restart comstar-audio"

deploy:
	@bash deploy/deploy.sh

logs:
	@echo "stub: tail merged JSON logs from bridge, audio, and kiosk"

test:
	cd terminal/bridge && dart test
