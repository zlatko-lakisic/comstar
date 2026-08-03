# STT fixtures and benches

Production STT prefers **AO-advertised sidecars** on the AI server (Reach
`SpeechClient`). Local faster-whisper (`comstar-stt` /
`scripts/stt_server_whisper.py`) remains the env-URL fallback for Mac/dev.
Moonshine (`scripts/stt_server.py`) is kept for comparison only.

## Correct testing

Replaying one WAV ten times proves **determinism**, not product accuracy.

Score the live path:

```
mic → comstar-audio → bridge PCM → Reach SpeechClient or HttpSttClient → STT
```

Labeled fixtures are `*.wav` + sibling `*.json`:

```json
{
  "file": "haydt-….wav",
  "transcript": "How are you doing today",
  "source": "bridge",
  "path": "audio→bridge→stt"
}
```

| `source` | Counts toward `--require-live`? |
|---|---|
| `bridge` + `path: audio→bridge→stt` | **Yes** |
| `parecord` / `synthetic` | No (smoke only) |

## Commands

```bash
python3 -m unittest discover -s testdata/stt -p 'test_*.py'

COMSTAR_STT_BENCH=1 python3 -m testdata.stt.bench_stt --trials 1 --require-live 10
```

Pi live archives (optional): `/opt/comstar/testdata/stt/live/`.
Debug utterance: `/tmp/comstar-last-utterance.wav`.
