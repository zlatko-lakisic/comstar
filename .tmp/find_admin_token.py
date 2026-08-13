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


for cmd in [
    "systemctl --user cat comstar-bridge.service | head -80",
    "ls -la ~/.config/comstar ~/.config/systemd/user/comstar-bridge* 2>/dev/null || true",
    "grep -RIn 'COMSTAR_ADMIN\\|lan_token\\|ADMIN_TOKEN' ~/.config/comstar /opt/comstar/src/deploy/systemd /opt/comstar/src/config 2>/dev/null | head -40",
]:
    code, out, err = run(cmd)
    print("====", cmd)
    print(out)
    if err.strip():
        print(err)

c.close()
