# Nextcloud calendar

Use `client.nextcloud` calendar tools. Never invent events. Prefer
`nc_calendar_get_upcoming_events` or `nc_calendar_list_events`.

## Tools

| Tool | Use for |
|------|---------|
| `nc_calendar_list_calendars` | Which calendars exist |
| `nc_calendar_list_events` / `nc_calendar_get_upcoming_events` | What’s on |
| `nc_calendar_create_event` | Create only when title + time are clear |
| `nc_calendar_create_meeting` | Quick meeting when asked |

Timezone for this home: `America/New_York`.

## Spoken answers

- Clear day → say so
- Busy → at most ~5 events: title + time
- Not Google Calendar — do not claim Google data from these tools
