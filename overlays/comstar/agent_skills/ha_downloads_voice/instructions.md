# Downloads / *arr (voice)

## qBittorrent

- Status: `sensor.qbittorrent_status`
- Speeds: `sensor.qbittorrent_download_speed`, `sensor.qbittorrent_upload_speed`
- Counts: `sensor.qbittorrent_active_torrents` (and related count sensors if exposed)

Plus integration may mirror under `sensor.qbittorrent_plus_*` if present.

## Sonarr

- `sensor.sonarr_queue`, `sensor.sonarr_wanted`, `sensor.sonarr_upcoming`,
  `sensor.sonarr_shows`, `sensor.sonarr_disk_space`, `sensor.sonarr_commands`
- Health: `sensor.sonarr_state`, CPU/memory usage sensors

## Radarr

- `sensor.radarr_queue`, `sensor.radarr_movies`, `sensor.radarr_disk_space_movies`,
  `sensor.radarr_start_time`
- Health: `sensor.radarr_state`, CPU/memory usage sensors

## Prowlarr

Same pattern under `sensor.prowlarr_*` when present — queue, wanted, disk, state.

Spoken: one status line (e.g. “qBittorrent downloading at X, N active”).
Do not start/stop torrents unless the user clearly asks and tools allow it.
