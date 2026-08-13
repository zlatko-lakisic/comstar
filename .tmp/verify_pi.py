import paramiko
from pathlib import Path

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
cmd = r"""
set -e
for i in $(seq 1 40); do
  if ss -ltn | grep -q ':8781 '; then echo admin_up; break; fi
  sleep 1
done
systemctl --user --no-pager is-active comstar-bridge comstar-audio comstar-kiosk comstar-stt
echo '---health---'
curl -fsS http://127.0.0.1:8781/admin/health | head -c 160; echo
echo '---agents---'
curl -fsS http://127.0.0.1:8781/admin/api/agents | python3 -c 'import sys,json; d=json.load(sys.stdin); print("dynamic", d.get("dynamic_planning")); print("agents", [a["id"] for a in d.get("agents",[])]); print("voice", d.get("voice_backend")); print("secrets", d.get("secrets"))'
echo '---yaml orch---'
grep -A25 '^orchestration:' /opt/comstar/src/config/comstar.yaml | head -30
"""
_i, o, e = c.exec_command(cmd, timeout=90)
print(o.read().decode())
err = e.read().decode()
if err.strip():
    print(err)
print("exit", o.channel.recv_exit_status())
c.close()
