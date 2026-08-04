# Network / WAN / MikroTik (voice)

Call `GetLiveContext` (or entity reads) before answering. Never invent IPs or rates.

## IP addresses (ask which one)

| Question | Entity / hint |
|----------|----------------|
| Home WAN (preferred) | `sensor.mikrotik_home_ether1_tx` **attributes** `client_ip_address` (strip `/24`); comment is WAN |
| HA / home LAN IP | `sensor.local_ip` |
| HA host NIC | `sensor.system_monitor_ipv4_address_enp1s0` |
| Phone public IP | `sensor.ibrica_samsung_public_ip_address` — often **cellular**, not home WAN |
| Phone Wi‑Fi LAN | `sensor.ibrica_samsung_wi_fi_ip_address` |
| Mostar router public IP | `sensor.mikrotik_mostar_environment_publicip` |
| NVR NIC IPv4 map | `sensor.nvr_glances_nic_ipv4` (attrs per NIC) |

“What’s my WAN / public IP?” (home) → MikroTik ether1 WAN attribute, **not** the phone sensor unless they say phone.
“What’s the Mostar public IP?” → MikroTik Mostar PublicIP.
“What’s the Home Assistant IP?” → `sensor.local_ip`.

## Internet speed (Speedtest)

- `sensor.speedtest_download`, `sensor.speedtest_upload`, `sensor.speedtest_ping`

## MikroTik home (hap ac) — clients & health

- CPU / mem / uptime: `sensor.mikrotik_home_hap_ac_cpu_load`, `_memory_usage`, `_uptime`
- Clients: `sensor.mikrotik_home_hap_ac_wired_clients`, `_wireless_clients`

## MikroTik home — interface bandwidth (RX/TX rates)

Live rates: `sensor.mikrotik_home_<iface>_rx` / `_tx` (**unit: kB/s**)  
Totals: `…_rx_total` / `…_tx_total`

| Spoken name | iface key |
|-------------|-----------|
| WAN / ether1 | `ether1` |
| ether2–5 | `ether2` … `ether5` |
| SFP | `sfp1` |
| Wi‑Fi 1 / 2 | `wlan1`, `wlan2` |
| Home Wi‑Fi VLAN | `home_wifi_vlan` |
| IoT VLAN | `iot_vlan` |
| WireGuard Mostar | `wg_mostar` |
| NBI hackathon | `nbi_hackathon` |
| Loopback | `lo` |

Port admin switches: `switch.mikrotik_home_<iface>_port`.

## MikroTik Mostar

Same pattern under `sensor.mikrotik_mostar_*` (ether1–5, wlan1, wlan_nyc, wg_nyc, L2TP/OVPN).
Public IP: `sensor.mikrotik_mostar_environment_publicip`.

## Basement perimeter switch (port speed / RX / TX)

`sensor.basement_perimiter_switch_pNN_<name>_speed` / `_rx_rate` / `_tx_rate`
Notable: p01 MikroTik, p05 NAS, p13 NAS2, p23 Frigate, p25/p26 SFP.

## NAS NIC rates

- NAS1: `sensor.nas1_system_eth0_rx` / `_tx`
- NAS2: `sensor.nas2_system_br0_rx` / `_tx` (also `enp1s0`, `enp2s0`, …)

## Spoken style

Speak one address or a couple of rates. Convert bytes/s to human units when obvious.
If Assist context lacks the sensor, say it is not exposed — do not invent an IP.
