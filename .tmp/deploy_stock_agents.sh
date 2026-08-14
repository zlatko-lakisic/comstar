#!/usr/bin/env bash
set -euo pipefail
export HOME=/c/Users/Zlatko.Lakisic
export PATH=/d/Projects/comstar/.tmp/bin:/usr/bin:$PATH
HOST=md-admin@192.168.89.34

rsync -az \
  /d/Projects/comstar/terminal/bridge/lib/agents/reach_catalog.dart \
  /d/Projects/comstar/terminal/bridge/lib/agents/ao_stock_agents.g.dart \
  /d/Projects/comstar/terminal/bridge/lib/agents/ao_stock_agents.json \
  "$HOST:/opt/comstar/src/terminal/bridge/lib/agents/"

rsync -az \
  /d/Projects/comstar/terminal/admin/components/agents.js \
  "$HOST:/opt/comstar/src/terminal/admin/components/agents.js"

rsync -az \
  /d/Projects/comstar/docs/CONTRACTS.md \
  "$HOST:/opt/comstar/src/docs/CONTRACTS.md"

ssh "$HOST" 'systemctl --user restart comstar-bridge; sleep 6; systemctl --user is-active comstar-bridge'
TOKEN=$(ssh "$HOST" 'grep -E "^(COMSTAR_ADMIN_TOKEN|ADMIN_TOKEN|LAN_TOKEN)=" ~/.config/comstar/admin.env | head -1 | cut -d= -f2- | tr -d "\r" | sed "s/^\"//;s/\"$//"')
ssh "$HOST" "curl -fsS -H 'x-comstar-lan-token: $TOKEN' http://127.0.0.1:8781/admin/api/agents" \
  | python -c "import json,sys; d=json.load(sys.stdin); c=d.get('catalog') or {}; print('ok',c.get('ok'),'live',c.get('live_agent_count'),'stock',c.get('stock_agent_count'),'agents',len(c.get('agents') or [])); print('sample',[a.get('id') for a in (c.get('agents') or [])[:5]]); print('gpt', [a.get('id') for a in (c.get('agents') or []) if str(a.get('id','')).startswith('gpt')]); print('available', sum(1 for a in (c.get('agents') or []) if a.get('available') or a.get('onAo')))"
