#!/usr/bin/env python3
"""One-shot COMSTAR deploy from Windows (no local rsync)."""
from __future__ import annotations

import io
import os
import tarfile
import time
from pathlib import Path

import paramiko

ROOT = Path(r"D:\Projects\comstar").resolve()
REMOTE = os.environ.get("COMSTAR_DEPLOY_HOST", "md-admin@192.168.89.34")
REMOTE_DIR = os.environ.get("COMSTAR_DEPLOY_DIR", "/opt/comstar/src")
user, host = REMOTE.split("@", 1) if "@" in REMOTE else ("md-admin", REMOTE)

EXCLUDES = {
    ".git",
    ".tmp",
    "vendor/agentic-orchestration",
    ".venv",
    ".venv-stt",
    "node_modules",
    ".dart_tool",
    "terminal/bridge/build",
    "terminal/audio/.venv",
    "config/comstar.yaml",
    "config/comstar.dev.yaml",
}


def excluded(rel: str) -> bool:
    rel = rel.replace("\\", "/")
    parts = rel.split("/")
    if rel in EXCLUDES:
        return True
    for ex in EXCLUDES:
        if rel == ex or rel.startswith(ex.rstrip("/") + "/"):
            return True
    if any(p in {".git", "node_modules", ".dart_tool", "__pycache__", ".venv"} for p in parts):
        return True
    if parts[-1].endswith((".pyc",)):
        return True
    return False


def main() -> None:
    print(f"Packing {ROOT} …")
    buf = io.BytesIO()
    count = 0
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for path in ROOT.rglob("*"):
            if not path.is_file():
                continue
            rel = path.relative_to(ROOT).as_posix()
            if excluded(rel):
                continue
            tar.add(path, arcname=rel)
            count += 1
    data = buf.getvalue()
    print(f"Packed {count} files ({len(data) / 1e6:.1f} MB gzip)")

    key = Path.home() / ".ssh" / "id_rsa"
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(
        host,
        username=user,
        key_filename=str(key),
        look_for_keys=False,
        allow_agent=False,
        timeout=20,
    )

    def run(cmd: str, check: bool = True, timeout: int = 600):
        print(f"$ {cmd[:140]}{'…' if len(cmd) > 140 else ''}")
        _i, o, e = c.exec_command(cmd, timeout=timeout)
        out = o.read().decode("utf-8", "replace")
        err = e.read().decode("utf-8", "replace")
        code = o.channel.recv_exit_status()
        if out.strip():
            print(out.rstrip())
        if err.strip():
            print(err.rstrip())
        if check and code != 0:
            raise SystemExit(f"remote failed ({code}): {cmd}")
        return code, out, err

    stamp = int(time.time())
    stage = f"/tmp/comstar-deploy-{stamp}"
    run(f"mkdir -p {stage}")
    print("Uploading archive…")
    sftp = c.open_sftp()
    remote_tar = f"{stage}/tree.tgz"
    with sftp.file(remote_tar, "wb") as f:
        f.write(data)
    sftp.close()

    print("Extracting + rsync --delete on Pi…")
    run(
        "set -e; "
        f"cd {stage}; tar -xzf tree.tgz; mkdir -p {REMOTE_DIR}; "
        f"rsync -a --delete "
        "--exclude config/comstar.yaml --exclude config/comstar.dev.yaml "
        f"{stage}/ {REMOTE_DIR}/; rm -rf {stage}"
    )

    remote_setup = f"""
set -euo pipefail
REMOTE_DIR='{REMOTE_DIR}'
CFG="$REMOTE_DIR/config/comstar.yaml"
if [[ ! -f "$CFG" ]]; then
  sed "s|overlay_root: ./overlays/comstar|overlay_root: $REMOTE_DIR/overlays/comstar|" \\
    "$REMOTE_DIR/config/comstar.example.yaml" > "$CFG"
  echo "created $CFG"
else
  echo "config present: $CFG"
fi
UNIT_DIR="$HOME/.config/systemd/user"
mkdir -p "$UNIT_DIR"
for unit in comstar-bridge comstar-audio comstar-kiosk comstar-stt comstar-health; do
  src="$REMOTE_DIR/deploy/systemd/${{unit}}.service"
  if [[ -f "$src" ]]; then
    cp "$src" "$UNIT_DIR/${{unit}}.service"
    echo "installed $unit.service"
  fi
done
if [[ -f "$REMOTE_DIR/deploy/systemd/comstar-health.timer" ]]; then
  cp "$REMOTE_DIR/deploy/systemd/comstar-health.timer" "$UNIT_DIR/comstar-health.timer"
  echo "installed comstar-health.timer"
fi
chmod +x "$REMOTE_DIR/scripts/comstar_health.sh" 2>/dev/null || true
chmod +x "$REMOTE_DIR/scripts/comstar_audio_health.sh" 2>/dev/null || true
chmod +x "$REMOTE_DIR/deploy/pi-session/comstar-session.sh" 2>/dev/null || true
chmod +x "$REMOTE_DIR/scripts/kiosk-launch.sh" 2>/dev/null || true
chmod +x "$REMOTE_DIR/deploy/pi-session/prefer-hdmi-audio.sh" 2>/dev/null || true
mkdir -p "$HOME/.config/comstar" "$HOME/.config/wireplumber/main.lua.d"
cp "$REMOTE_DIR/deploy/pi-session/prefer-hdmi-audio.sh" "$HOME/.config/comstar/prefer-hdmi-audio.sh"
chmod +x "$HOME/.config/comstar/prefer-hdmi-audio.sh"
cp "$REMOTE_DIR/deploy/pi-session/wireplumber/51-comstar-hdmi.lua" \\
  "$HOME/.config/wireplumber/main.lua.d/51-comstar-hdmi.lua"
systemctl --user daemon-reload
systemctl --user enable comstar-bridge.service comstar-audio.service comstar-kiosk.service comstar-stt.service >/dev/null
systemctl --user enable --now comstar-health.timer >/dev/null 2>&1 || true
"""
    print("Ensuring config + systemd units…")
    run(remote_setup)

    print("dart pub get…")
    run(f"cd '{REMOTE_DIR}/terminal/bridge' && dart pub get", timeout=300)

    print("Restarting units…")
    restart = """
set -euo pipefail
systemctl --user restart comstar-stt.service || true
systemctl --user restart comstar-bridge.service
for i in $(seq 1 45); do
  if ss -ltn | grep -q ':8778 '; then
    echo "bridge listening on 8778"
    break
  fi
  sleep 1
done
systemctl --user restart comstar-audio.service
systemctl --user restart comstar-kiosk.service
sleep 2
systemctl --user --no-pager is-active comstar-bridge comstar-audio comstar-kiosk comstar-stt || true
systemctl --user --no-pager is-active comstar-health.timer 2>/dev/null || true
curl -fsS http://127.0.0.1:8781/admin/health >/dev/null && echo ADMIN_HEALTH_OK || echo ADMIN_HEALTH_FAIL
test -f /opt/comstar/src/terminal/admin/components/agents.js && echo AGENTS_UI_OK || echo AGENTS_UI_MISSING
test -d /opt/comstar/src/vendor/agentic-orchestration-reach && echo REACH_VENDOR_OK || echo REACH_VENDOR_MISSING
ls /opt/comstar/src/terminal/bridge/lib/agents >/dev/null && echo AGENTS_LIB_OK || echo AGENTS_LIB_MISSING
"""
    run(restart, timeout=180)
    c.close()
    print("Deploy complete.")


if __name__ == "__main__":
    main()
