# Google Workspace MCP (auth + routing)

`client.google_workspace` exposes Gmail, Calendar, and Drive tools from
`mcp-server-google-workspace`. Detailed tool playbooks live in the
`calendar_voice`, `gmail_voice`, and `drive_voice` skills — follow those when
the question is about that product.

## Mandatory

- If this MCP is on the turn and the user asks about Google data, **call the
  matching tools** before answering. Do not invent calendar events, mail, or files.
- Prefer the product skill’s tool table (calendar / gmail / drive).
- Spoken answers only: titles, times, names — no IDs or URLs unless asked.

## Pairing / scopes (COMSTAR)

| Link type | Typical access |
|-----------|----------------|
| Device (TV) code | Calendar; limited Drive (`drive.file`); **no Gmail** |
| Desktop OAuth | Gmail read/send, Calendar, full Drive |

- “Connect my Google” / missing tools → tell them to link Google on the terminal
- Gmail or broad Drive unauthorized → Desktop upgrade link needed; say that clearly
- Empty tool results are real data (clear day / no mail / no files) — say so

## Cross-cutting

- `get_user_email` — who is linked
- Never claim “I can’t access Google” without attempting a tool first when the MCP is attached
