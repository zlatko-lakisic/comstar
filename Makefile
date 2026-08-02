.PHONY: doctor bridge-dev kiosk-dev audio-sync deploy logs test

ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

doctor:
	@bash scripts/doctor.sh

bridge-dev:
	cd terminal/bridge && dart run bin/comstar_bridge.dart --config ../../config/comstar.dev.yaml

kiosk-dev:
	cd terminal/kiosk && npm start

audio-sync:
	@echo "stub: rsync terminal/audio/ to comstar:~/comstar/terminal/audio/ and restart comstar-audio"

deploy:
	@echo "stub: build arm64 bridge, rsync all three processes, restart systemd units"

logs:
	@echo "stub: tail merged JSON logs from bridge, audio, and kiosk"

test:
	cd terminal/bridge && dart test
