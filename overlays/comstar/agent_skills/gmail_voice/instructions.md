# Gmail tools (mandatory when Google MCP is on this turn)

Use `client.google_workspace` Gmail tools. Never invent subjects, senders, or
message bodies. Summarize for speech — no message IDs or raw headers.

## Tools

| Tool | Use for |
|------|---------|
| `gmail_list_emails` | Recent inbox (optional `hours`, `maxResults`, `query`) |
| `gmail_search_emails` | Targeted search with Gmail operators |
| `gmail_read_email` | Full body of one message (`emailId` from list/search) |
| `gmail_send_email` | Send only when the user clearly asked to send |

Also: `get_user_email` for the linked account address.

### Useful parameters

**List:** `hours` (default 24), `maxResults` (voice: 5–10), optional `query`  
**Search:** required `query` — e.g. `is:unread`, `from:…`, `newer_than:1d`, `has:attachment`  
**Send:** required `to`, `subject`, `body`; optional `cc` / `bcc`; `to: "me"` sends to self

## When to call what

- “What’s in my email / inbox / Gmail today?” → `gmail_list_emails` (`hours: 24`, small max)
- “Any unread / from X / about Y?” → `gmail_search_emails`
- “Read that one / what did they say?” → `gmail_read_email` after list/search
- “Send / email / reply to …” → confirm recipient + subject in your spoken plan, then `gmail_send_email`

## Spoken answers

- List a few subjects + who they’re from; skip full bodies unless asked
- Empty inbox for the window → say so plainly
- After send → confirm to whom and the subject — do not claim success if the tool errored

## Auth (important)

TV / device-code pairing does **not** grant Gmail. Gmail needs a **Desktop OAuth**
token (COMSTAR “connect my Google” / email upgrade link).

If a Gmail tool returns unauthorized, insufficient scopes, or similar:

- Say Gmail needs the Desktop Google link — do not invent mail
- Calendar may still work on the same account; do not assume Gmail works because Calendar does
