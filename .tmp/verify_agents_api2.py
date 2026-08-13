import json
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
# read token on-box without printing it
_i, o, e = c.exec_command(
    "set -a; source ~/.config/comstar/admin.env; set +a; "
    "curl -fsS -H \"X-Comstar-Lan-Token: $COMSTAR_ADMIN_TOKEN\" "
    "http://127.0.0.1:8781/admin/api/agents"
)
out = o.read().decode()
err = e.read().decode()
code = o.channel.recv_exit_status()
if code != 0:
    print("FAIL", code, err, out[:200])
    raise SystemExit(1)
d = json.loads(out)
print("dynamic", d.get("dynamic_planning"))
print("voice", d.get("voice_backend"))
print("agents", [(a["id"], a["enabled"], a["ready"]) for a in d.get("agents", [])])
print("secrets_configured", {k: v.get("configured") for k, v in (d.get("secrets") or {}).items()})
print("apply", d.get("apply"))
_i, o, e = c.exec_command(
    "systemctl --user --no-pager is-active comstar-bridge; "
    "test -f /opt/comstar/src/terminal/admin/components/agents.js && echo AGENTS_UI_OK; "
    "grep -c dynamic_planning /opt/comstar/src/config/comstar.yaml"
)
print(o.read().decode().strip())
c.close()
