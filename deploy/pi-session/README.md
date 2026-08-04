# COMSTAR Pi session chrome

Configs installed by `scripts/install-pi-session.sh` (`make pi-session`).

| Path | Role |
|---|---|
| `comstar-session.sh` | Starts `labwc` **without** `--merge-config` |
| `comstar-labwc.desktop` | Wayland session entry for LightDM |
| `labwc/autostart` | Dark `swaybg` + early kiosk; never starts panels |
| `labwc/environment` | Invisible cursor + dark GTK |
| `lightdm/50-comstar.conf` | Drop-in (also patches main `lightdm.conf`) |

Why not just kill panels: Pi `labwc-pi` uses `--merge-config`, so `/etc/xdg/labwc/autostart` keeps respawning `pcmanfm` / `wf-panel-pi` via `lwrespawn`. The COMSTAR session avoids that merge entirely.
