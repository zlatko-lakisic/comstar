# COMSTAR Pi session chrome

Configs copied by `scripts/install-pi-session.sh` (also `make pi-session`).

| Path | Role |
|---|---|
| `labwc/autostart` | Dark `swaybg` if present |
| `labwc/environment` | Invisible cursor theme + dark GTK |
| `labwc/rc.xml` | Minimal labwc (opt-in via `COMSTAR_REPLACE_LABWC_RC=1`) |
| `lightdm/50-comstar.conf` | Autologin seat drop-in (needs sudo) |

Does not run on every `make deploy`. Install once, then reboot.
