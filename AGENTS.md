# AGENTS.md — COMSTAR agent rules

## Contracts first

Read `docs/CONTRACTS.md` before changing any cross-process interface. Update the
contract, then code, then tests — in that order.

## Milestone order

Work `docs/IMPLEMENTATION_PLAN.md` milestones in order (M0 → M9). Do not start
M(n+1) until M(n) exit criteria are met.

## Structured logs

Every process emits one JSON object per line:

| field | required | meaning |
|---|---|---|
| `ts` | yes | epoch ms |
| `level` | yes | debug, info, warn, error |
| `proc` | yes | bridge, audio, kiosk |
| `evt` | yes | event name |
| `msg` | yes | human-readable summary |
| `turn_id` | no | active turn ULID |
| `data` | no | structured payload |

Level from `COMSTAR_LOG` env var (default `info`).

## Latency spans

Emit on close via the `Span` helper. Standard names:

- `wake_to_listen`
- `stt`
- `orchestration`
- `tts_first`
- `tts_total`
- `avatar_start`
- `turn_total`

## LAN binding (triple gate)

Never bind WebSocket ports to `0.0.0.0` unless **all three** are true:

1. `COMSTAR_ENV=dev`
2. Config file basename is `comstar.dev.yaml`
3. `dev.bind_lan: true` **and** `dev.lan_token` is non-empty

Production configs must ship with `dev.bind_lan: false`.

## Architecture (speech vs brain)

- **On Pi:** capture, VAD, wake word, kiosk, playback. Thin I/O terminal.
- **On AI server:** AO Reach (incl. optional speech sidecars) + CodeProject.AI
  (detection + face). Prefer `SessionBridge.speechClient` for STT/TTS when AO ≥ 1.28
  advertises `hello.speech`; else fall back to `COMSTAR_STT_URL` / `COMSTAR_TTS_URL`
  (local `comstar-stt` / `comstar-tts` or Mac bring-up).
- Do **not** ferry PCM on the Reach WebSocket or route turns through the planner
  just for STT. See `docs/adr/0003-speech-on-ada.md`.
- STT accuracy: label **live bridge** fixtures (`testdata/stt/`). Parecord goldens are smoke-only.

## Secrets

Never commit tokens, keys, real `config/comstar.yaml` / `comstar.dev.yaml`, or
`config/comstar.mac.env`. Use the `.example` / `.example.yaml` templates.
