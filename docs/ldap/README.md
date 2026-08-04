# FreeIPA / LDAP binding for COMSTAR

COMSTAR resolves biometric matches to FreeIPA people before opening an AO
session. See [ADR 0005](../adr/0005-ldap-identity.md).

## What goes in FreeIPA

| Field | Role |
|---|---|
| `uid` | Canonical AO / COMSTAR identity (`x-agentic-user-name`) |
| `cn` / `displayName` | Greeter and kiosk display name |
| `comstarFaceId` | CPAI face userid (default = `uid`) |
| `comstarVoiceId` | Reserved for speaker enrollment |
| IPA groups | Future MCP/ACL (e.g. `comstar-users`); not required for first ship |

Do **not** store face images, embeddings, passwords for COMSTAR, or Google
tokens in LDAP.

## Schema install

1. Review [`comstar.schema`](comstar.schema) (OIDs under `1.3.6.1.4.1.55555` —
   replace with your org PEN if you publish schema).
2. Load into 389 Directory Server / FreeIPA per site practice, then restart
   `dirsrv`.
3. For each household user COMSTAR should recognise:

```bash
# Example with ldapmodify (adjust BASEDN / bind)
ldapmodify -Y GSSAPI <<'EOF'
dn: uid=zlatko,cn=users,cn=accounts,dc=example,dc=com
changetype: modify
add: objectClass
objectClass: comstarPerson
-
add: comstarFaceId
comstarFaceId: zlatko
EOF
```

## Enrollment convention

```bash
./scripts/enroll_face.sh <ipa-uid>
```

The script verifies the IPA user exists, ensures `comstarFaceId` is set
(defaulting to `uid`), then registers that face id with CodeProject.AI.

## Directory sidecar

Bridge does not speak LDAP wire protocol. It calls the read-only HTTP sidecar:

```text
GET {directory.sidecar_url}/v1/resolve?face_id=<comstarFaceId>
```

See [`mcp/directory_sidecar/`](../../mcp/directory_sidecar/). Bind DN should be a
search-only service account (e.g. `uid=comstar-dir,cn=sysaccounts,cn=etc,$BASEDN`).

## Optional LDAP MCP (deferred)

A planner-facing MCP (`lookup_user`, `list_comstar_users`) may wrap the same
sidecar later. It must use `guest_allowed: false`. Session open must **not**
depend on that MCP.

Tracked in [`docs/BACKLOG.md`](../BACKLOG.md). Do not implement until the
session-path resolve above is deployed and stable.
