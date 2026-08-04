# voice_google harness pack

Live probes for `client.voice_responder` + `client.google_workspace` with the
calendar / gmail / drive voice skills injected.

## Scenarios

| Id | Mode | Covers |
|----|------|--------|
| `linked_account` | read | `get_user_email` |
| `calendar_list` | read | `calendar_list_calendars` |
| `calendar_today` | read | `calendar_list_events` (today) |
| `calendar_tomorrow` | read | `calendar_list_events` (offset) |
| `calendar_week` | read | `calendar_list_events` (multi-day) |
| `calendar_create_incomplete` | clarify | refuse inventing create params |
| `calendar_create_probe` | **write** | `calendar_create_event` (disposable) |
| `gmail_today` | read | `gmail_list_emails` |
| `gmail_unread` | read | search/list unread |
| `gmail_search` | read | `gmail_search_emails` |
| `gmail_send_incomplete` | clarify | refuse inventing send params |
| `gmail_send_self` | **write** | `gmail_send_email` to self |
| `drive_list` | read | `drive_list_files` |
| `drive_shared` | read | shared-with-me list |
| `drive_search` | read | `drive_search_files` |
| `drive_create_folder_probe` | **write** | `drive_create_folder` |
| `drive_trash_probe` | **write** | `drive_delete_file` (trash) |

Disposable writes use the exact name **COMSTAR harness probe**. Prefer running
reads first; run write probes only when Desktop (or Calendar) scopes are linked.
