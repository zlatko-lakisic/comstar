# Nextcloud MCP (auth + routing)

`client.nextcloud` exposes Nextcloud apps via `nextcloud-mcp-server` (`nc_*`
tools). Product playbooks live in `nc_files_voice`, `nc_calendar_voice`,
`nc_tasks_voice`, `nc_contacts_voice`, `nc_notes_voice`, and `nc_mail_voice`.

## Mandatory

- If this MCP is on the turn and the user asks about Nextcloud / cloud / NAS
  data, **call matching `nc_*` tools** before answering. Do not invent files,
  notes, events, tasks, contacts, or mail.
- This account is **not** Google Workspace. If they said Google / Gmail / Drive,
  do not use Nextcloud tools.
- Spoken answers only: titles, times, names — no IDs or raw paths unless asked.

## Pairing (COMSTAR)

- “Connect my Nextcloud” → Login Flow QR on the terminal (or Admin inject)
- Missing / revoked credentials → tell them to connect Nextcloud
- Empty tool results are real (no notes / clear day) — say so

## Cross-cutting

- Never claim “I can’t access Nextcloud” without attempting a tool first when
  the MCP is attached
