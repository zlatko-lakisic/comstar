# COMSTAR failure matrix (M9.1)

Each row: dependency failure → expected degraded behaviour → how to inject → recovery.

| Failure | Expected behaviour | Inject | Auto-recover? | Automated test / status |
|---|---|---|---|---|
| CPAI down | `vision.degraded`; ambient continues; no face engage | stop CPAI / block `:32168` | yes (probe backoff) | `vision_test.dart` degrade/recover |
| CPAI slow | timeouts; no crash; skip frame | FakeCpai latency / tc netem | yes | `vision_test.dart` timeout |
| AO down | speak fallback WAV; no crash | stop AO / block `:8765` | yes on next turn / reopen retry | `session.dart` reopen backoff |
| AO slow | turn timeout → sorry line | delay AO | yes | manual / soak |
| STT down (Ada + Pi) | fallback / sorry | stop speech sidecars + `comstar-stt` | yes | `stt_test.dart` soft-fail |
| TTS down | fallback WAV | stop TTS sidecars + `comstar-tts` | yes | soft-fail in coordinator |
| Kiosk dead | paplay local speaker still works | `systemctl --user stop comstar-kiosk` | yes on WS reconnect | verified (local speaker) |
| Camera unplugged | vision degraded / stub frames | unplug `/dev/video0` | yes when replugged | manual |
| Mic unplugged | audio capture warn; no crash | unplug mic | yes | manual |
| Network down (LAN) | local sleep/volume/clock/social still work; AO fails soft | `ip link set eth0 down` | yes | manual |
| Disk full | log rotate / soft-fail memory writes | fill partition carefully | yes | manual |
| Memory server down | voice continues without history | `systemctl --user stop comstar-memory` | yes | soft-fail coded |
| Bridge WS flap | audio/kiosk reconnect with full-jitter backoff | restart bridge | yes | kiosk/audio clients |

## Inject helpers (Pi)

```bash
# Kiosk dead (speech still via paplay)
systemctl --user stop comstar-kiosk
# …speak a turn… then
systemctl --user start comstar-kiosk

# Memory soft-fail
systemctl --user stop comstar-memory
# …voice turn should still answer…
systemctl --user start comstar-memory

# STT local fallback down (Ada path may still work)
systemctl --user stop comstar-stt

# CPAI unreachable (vision.degraded in bridge logs)
# On Ada: stop CodeProject.AI container/service, or temporarily block :32168
```

## Automated coverage

| Area | Path |
|---|---|
| CPAI degrade / timeout / recover | `terminal/bridge/test/vision_test.dart` |
| Backoff helper | `terminal/bridge/test/backoff_test.dart` |
| Session reopen retries | `terminal/bridge/lib/session.dart` `_reopen` |
| CPAI probe cooldown | `CpaiClient` + `vision_test.dart` |
| STT HTTP soft-fail | `terminal/bridge/test/stt_test.dart` |

Hardware rows (camera/mic/network/disk) stay on the soak checklist in `docs/TESTING.md` §T5.
