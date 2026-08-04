# Media players (voice)

## TVs / speakers (Cast / Google)

- Living room TV / speaker: `media_player.living_room_tv*`, `media_player.living_room_speaker*`
- Master bedroom: `media_player.master_bedroom_tv*`, `media_player.master_bedroom_speaker*`
- Office: `media_player.office_tv`, `media_player.office_speaker*`

## OwnTone

- `media_player.owntone_server*`, garden output `media_player.owntone_output_garden_speaker*`

## Plex clients

Many `media_player.plex_*` (Samsung TVs, Android, Chrome, Fold, Ultra). Prefer the
room-named TV/speaker unless the user names Plex or a device.

## Control

Report playing/paused/idle and title when attributes exist. Pause/play/volume only
when user asks and the entity supports it via HA services.

Ambiguous “TV” → living room vs master bedroom vs office.
