# Home Assistant (voice) — routing

When the `home_assistant` MCP is attached, **call HA tools before answering** any
home / network / media / climate / security / irrigation question. Never invent
state. Prefer `GetLiveContext` first (no args, or name/domain filters).

Detailed playbooks live in sibling skills — use the matching one:

| Skill | Topics |
|-------|--------|
| `ha_network_voice` | WAN/LAN IPs, MikroTik interfaces, VLANs, speedtest, switch ports |
| `ha_irrigation_voice` | Zones, 7d minutes, soil, rain delay, BHyve |
| `ha_security_voice` | Locks, garage, doors, motion, Frigate |
| `ha_climate_voice` | Thermostats, Nest, humidity, weather |
| `ha_lights_voice` | Indoor/outdoor lights and plugs |
| `ha_media_voice` | Plex, OwnTone, TVs, speakers |
| `ha_downloads_voice` | qBittorrent, Sonarr, Radarr, Prowlarr |
| `ha_infra_voice` | NAS, containers, host health |
| `ha_presence_voice` | Who’s home, where is \<name\>, person entities |

Assist only sees **exposed** entities. If live context is empty for a topic, say
you checked Home Assistant and that entity is not exposed — do not guess.

Spoken answers only: short sentences, friendly names, no markdown or entity-id dumps.
