# Infrastructure / NAS / containers (voice)

## NAS1 / NAS2 host

Disk, CPU, memory, uptime sensors under `sensor.nas1_*` / `sensor.nas2_*`.
NIC rates: `nas1_system_eth0_rx/tx`, `nas2_system_br0_rx/tx` (and other NICs).

## Docker / Compose

`sensor.nas*_compose_*`, container state/image/CPU/memory for Frigate, Sonarr,
Home Assistant addons when exposed.

## Glances / system monitor

HA host: `sensor.system_monitor_*` (CPU, memory, disk, NIC IPs).
NVR Glances NIC map: `sensor.nvr_glances_nic_ipv4`.

## UniFi / “AP” entities in HA

Many `sensor.unifi_*` / AP entities here are **container/host metrics**, not
client Wi‑Fi association lists. For Wi‑Fi client counts prefer MikroTik
`wired_clients` / `wireless_clients` (network skill).

Spoken: one host health line unless user asks for a specific disk or container.
