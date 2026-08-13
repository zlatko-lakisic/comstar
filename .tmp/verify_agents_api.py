import json
import re
from pathlib import Path

import paramiko

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(
    "192.168.89.34",
    username="md-admin",
    key_filename=str(Path.home() / ".ssh" / "id_rsa"),
    look_for_keys=False,
    allow_agent=False,
    timeout=20,
)


def run(cmd: str) -> tuple[int, str, str]:
    _i, o, e = c.exec_command(cmd, timeout=60)
    out = o.read().decode("utf-8", "replace")
    err = e.read().decode("utf-8", "replace")
    code = o.channel.recv_exit_status()
    return code, out, err


# Prefer env token from user unit
code, out, err = run(
    "systemctl --user show-environment | grep -E 'COMSTAR_ADMIN_TOKEN|COMSTAR_LAN' || true"
)
print("env:", out.strip() or "(none)")

sftp = c.open_sftp()
with sftp.open("/opt/comstar/src/config/comstar.yaml", "r") as f:
    text = f.read().decode("utf-8", "replace")
sftp.close()


def grab(section: str, key: str) -> str:
    in_sec = False
    for line in text.splitlines():
        if re.match(rf"^{re.escape(section)}:\s*$", line):
            in_sec = True
            continue
        if in_sec:
            if re.match(r"^[^\s]", line):
                break
            m = re.match(rf"^\s+{re.escape(key)}:\s*(.*)$", line)
            if m:
                v = m.group(1).strip().strip('"').strip("'")
                return v.split("#", 1)[0].strip()
    return ""


token = grab("admin", "token") or grab("dev", "lan_token")
print("token_len", len(token))
if not token:
    raise SystemExit("no admin token in yaml")

code, out, err = run(
    f"curl -fsS -H 'X-Comstar-Lan-Token: {token}' http://127.0.0.1:8781/admin/api/agents"
)
if code != 0:
    print("curl failed", code, err, out)
    raise SystemExit(1)
d = json.loads(out)
print("dynamic", d.get("dynamic_planning"))
print("voice", d.get("voice_backend"))
print("agents", [(a["id"], a["enabled"], a["ready"]) for a in d.get("agents", [])])
print("secrets", d.get("secrets"))
print("apply", d.get("apply"))

code, out, err = run(
    "systemctl --user --no-pager is-active comstar-bridge comstar-audio comstar-kiosk comstar-stt"
)
print("units:\n" + out)
c.close()
