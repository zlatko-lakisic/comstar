#!/usr/bin/env bash
set -euo pipefail
export HOME=/c/Users/Zlatko.Lakisic
export PATH=/d/Projects/comstar/.tmp/bin:/usr/bin:$PATH
bash /d/Projects/comstar/.tmp/run_deploy.sh

ssh md-admin@192.168.89.34 bash -s <<'EOF'
set -euo pipefail
CFG=/opt/comstar/src/config/comstar.yaml
python3 - <<'PY'
from pathlib import Path
p = Path("/opt/comstar/src/config/comstar.yaml")
text = p.read_text(encoding="utf-8")
changed = False
if "dynamic_timeout_seconds:" in text:
    import re
    new, n = re.subn(
        r"(?m)^(\s*dynamic_timeout_seconds:\s*)\d+",
        r"\g<1>300",
        text,
        count=1,
    )
    if n:
        text = new
        changed = True
else:
    # Insert after timeout_seconds or dynamic_planning block
    if "dynamic_planning:" in text:
        text = text.replace(
            "dynamic_planning:",
            "dynamic_timeout_seconds: 300\n  dynamic_planning:",
            1,
        )
        changed = True
# Ensure research agents present in allowlist if the key exists
need = ["gpt_research", "claude_research"]
if "allowed_agent_provider_ids:" in text:
    for agent in need:
        if agent not in text:
            text = text.replace(
                "allowed_agent_provider_ids:",
                f"allowed_agent_provider_ids:\n    - {agent}",
                1,
            )
            changed = True
if changed:
    p.write_text(text, encoding="utf-8")
    print("patched comstar.yaml")
else:
    print("comstar.yaml already ok")
# show relevant lines
for i, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
    if any(k in line for k in (
        "timeout_seconds", "dynamic_timeout", "dynamic_planning",
        "allowed_agent", "gpt_research", "claude_research", "voice_backend",
    )):
        print(f"{i}:{line}")
PY
systemctl --user restart comstar-bridge.service
for i in $(seq 1 30); do
  if ss -ltn | grep -q ':8778 '; then echo bridge_up; break; fi
  sleep 1
done
systemctl --user --no-pager is-active comstar-bridge
# Confirm session open path logs after a moment — just grep binary defaults via dart source
grep -n "dynamicTimeoutSeconds\|aoRespondingTimeoutMs\|sessionEnv\|allowedAgentProviderIds" \
  /opt/comstar/src/terminal/bridge/lib/config.dart \
  /opt/comstar/src/terminal/bridge/lib/session.dart | head -20
EOF
