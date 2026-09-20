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

Spoken AO progress narration: `test/narration_policy_test.dart`,
`test/narration_phrase_bank_test.dart` (closed banks, stage gates, golden
transcripts). Toggle with `voice_narration.enabled`.

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

---

## UAT-6b — Spoken AO progress narration

Stand at the terminal in one sitting and run:

1. Three fast turns (answer expected under ~2s) — expect **no** progress chatter
   and no result preface, just the answer.
2. One news / world turn — expect at most one “doing” line, then optional
   heartbeat, then a short preface + headlines. No “Starting / Planning / Plan
   ready” stack and no sanitizer/debug leaks.
3. One open-ended planner turn — expect planning then doing (different banks),
   not four near-synonyms.
4. One turn while another is queued — expect silence at position 1; at position
   2 or higher, one queue line (no “position 1 of 1”).
5. One deliberately stalled turn (long research) — heartbeats should escalate
   (tier 1 → 2 → 3) so a 90s wait sounds different from a 20s wait.

Sign-off: the same opening line was not heard twice across ten hallway turns,
and the stalled turn sounded different from the merely slow one. Rollback:
`voice_narration.enabled: false` restores legacy `working_ack` + status pass-through
without touching the kiosk card.
