# COMSTAR M9 failure matrix (scaffold)

Each row: dependency failure → expected degraded behaviour → how to inject → recovery.

| Failure | Expected behaviour | Inject | Auto-recover? | Status |
|---|---|---|---|---|
| CPAI down | `vision.degraded`; ambient continues; no face engage | stop CPAI / block `:32168` | yes when CPAI returns | partial (vision poller) |
| CPAI slow | timeouts; no crash; skip frame | tc netem / sleep in mock | yes | untested |
| AO down | speak fallback WAV; no crash | stop AO / block `:8765` | yes on next turn retry | partial (`direct_agent_failed`) |
| AO slow | turn timeout → sorry line | delay AO | yes | partial |
| STT down (Ada + Pi) | fallback / sorry | stop speech sidecars + `comstar-stt` | yes | partial |
| TTS down | fallback WAV | stop TTS sidecars + `comstar-tts` | yes | partial |
| Kiosk dead | paplay local speaker still works | `systemctl --user stop comstar-kiosk` | yes on reconnect | verified (local speaker) |
| Camera unplugged | vision degraded | unplug /dev/video0 | yes | untested |
| Mic unplugged | audio capture warn; no crash | unplug mic | yes | untested |
| Network down (LAN) | local sleep/volume/clock/social still work; AO fails soft | `ip link set eth0 down` | yes | untested |
| Disk full | log rotate / soft-fail memory writes | `dd` fill | yes | untested |
| Memory server down | voice continues without history | `systemctl --user stop comstar-memory` | yes | soft-fail coded |

## Inject helpers (Pi)

```bash
# Kiosk dead
systemctl --user stop comstar-kiosk
# …speak a turn… then
systemctl --user start comstar-kiosk

# Memory soft-fail
systemctl --user stop comstar-memory
# …voice turn should still answer…
systemctl --user start comstar-memory
```

Automated row tests live under `terminal/bridge/test/` where practical; hardware rows stay manual soak checklist.
