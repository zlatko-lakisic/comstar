# COMSTAR directory sidecar

Read-only HTTP helper that resolves biometric modality IDs to FreeIPA users.
The bridge calls this after face votes and before `OpenSession` (ADR 0005 /
CONTRACTS §3b). This is **not** an MCP — planner LDAP tools are deferred.

## API

```
GET /health
→ 200 {"ok":true,"ldap":"up"|"down"}

GET /v1/resolve?face_id=<comstarFaceId>
GET /v1/resolve?voice_id=<comstarVoiceId>   # reserved
→ 200 {"uid","displayName","groups","dn","faceId"?,"voiceId"?}
→ 404 {"error":"not_found"}
→ 503 {"error":"ldap_unavailable"}
```

Bind `127.0.0.1` by default. LAN bind only when you intentionally expose it on
the AI server behind the same trust boundary as CPAI/AO.

## Env

| var | meaning |
|---|---|
| `COMSTAR_LDAP_URL` | `ldap://ipa.example.com` or `ldaps://…` |
| `COMSTAR_LDAP_BIND_DN` | search-only service account DN |
| `COMSTAR_LDAP_BIND_PASSWORD` | bind password (never commit) |
| `COMSTAR_LDAP_BASE_DN` | e.g. `cn=users,cn=accounts,dc=example,dc=com` |
| `COMSTAR_LDAP_FACE_ATTR` | default `comstarFaceId` |
| `COMSTAR_LDAP_VOICE_ATTR` | default `comstarVoiceId` |
| `COMSTAR_DIR_HOST` | default `127.0.0.1` |
| `COMSTAR_DIR_PORT` | default `8780` |

## Run

```bash
pip install -r requirements.txt
python -m directory_sidecar
```

Package root is `mcp/` (same as `terminal_mcp`):

```bash
cd mcp && PYTHONPATH=. python -m directory_sidecar
```
