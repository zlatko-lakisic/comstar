# COMSTAR testing

Companion to `docs/IMPLEMENTATION_PLAN.md` and `docs/IMPLEMENTATION_TRACKER.md`.

| Suite | What | Where |
|---|---|---|
| Unit | Dart / Python | `make test` |
| UAT | Operator scripts | §§ below + `docs/RUNBOOK.md` |
| Soak (T5) | 24 h unattended | `make soak` → Pi `~/.local/share/comstar/soak/` |

---

## T1 — Unit / contract

- Bridge: `cd terminal/bridge && dart test`
- Audio: `cd terminal/audio && python -m pytest` (when present)
- Failure inject rows that are software-mockable: `docs/FAILURE_MATRIX.md`

### T1.3 — Attention / voice (plan pointer)

Property and branch tests for the attention machine live under
`terminal/bridge/test/` (attention, session, speech_routing, intents).

---

## UAT-0 — Ground truth

Confirm CPAI + AO Reach reachable from the Pi (see `make doctor`,
`scripts/verify_cpai.sh`, `spike/reach_hello.dart`). Sign-off is environmental,
not a code gate.

---

## T5 — 24-hour soak (M9.4)

### How to run

```bash
# From Mac (SSH to Pi, nohup)
make soak
# Or shorter bring-up:
COMSTAR_SOAK_HOURS=1 make soak
```

Collector: `scripts/comstar_soak.sh`. Output:
`~/.local/share/comstar/soak/<timestamp>/` with `samples.jsonl`, `events.jsonl`,
`summary.json`.

### Acceptance thresholds

| Metric | Pass |
|---|---|
| Crashes / manual interventions | **0** over 24 h |
| Unexpected unit restarts (bridge/audio/kiosk) | investigate any; prefer **0** |
| False wake accepts | **≤ 2** in 24 h (force-wake era: count `force_wake` / sleep rejects carefully) |
| Bridge RSS | flat within **±5%** end vs start (ignore brief spikes) |
| Bridge fd count | flat (no monotonic climb) |
| CPAI / AO probe | error rate noted; sustained `down` must auto-recover when service returns |
| Temperature | no thermal throttle loops (`temp_c` in samples) |

### Evaluating a run

```bash
ssh comstar 'ls -lt ~/.local/share/comstar/soak | head'
ssh comstar 'cat ~/.local/share/comstar/soak/<id>/summary.json'
```

Partial runs (collector died early) may still salvage `summary.json` — note duration
in the tracker; only full ≥24 h closes M9.4 exit.

### Manual hardware injects during soak (optional)

Camera unplug, mic mute, Ethernet down — confirm soft-fail and auto-recover per
`docs/FAILURE_MATRIX.md`. Do not leave the Pi unreachable without a recovery path.

---

## T5b — Wake retune (M9.5)

Blocked while `COMSTAR_FORCE_WAKE_SCORE` is the production path and
`models/hey_comstar.onnx` is untrained. After ONNX + ROC (`make wake-sweep`),
use soak false-accept counts to retune thresholds. Until then document force-wake
RMS/refractory in `docs/RUNBOOK.md` §4.
