# Pod per step benchmark

Host: Ada server, single node k3s
Date: 2026-09-24
Workflow: config/workflows/workflow_brainstorm.yaml (2 steps) — **not completed**
Worker image: ghcr.io/zlatko-lakisic/agentic-orchestrator-worker:v1.27.4
Image cached on node before timing: yes (warm-pool pods Running on this image)
Runs per mode: n/a for workflow; Step 3 floor ran 3 times, median reported

| Mode | Run 1 | Run 2 | Run 3 | Median |
| --- | --- | --- | --- | --- |
| Job per step | — | — | — | **blocked** |
| Warm pool | — | — | — | **blocked** |
| Pod startup floor (Step 3) | 3.028s | 4.064s | 2.456s | **3.028s** |

Difference (median): n/a (workflow comparison not measured)

Jobs observed per Job-per-step run: n/a

## Why Step 2 did not complete

1. Host-user `python main.py --batch` cannot write root-owned
   `/var/lib/agentic/run-store/warm-pool/queue` and `execution-queue`
   (PermissionError). No sudo without interactive password; Secret/manifests not edited per handoff.
2. `kubectl exec` into live `agentic-engine` to gain PVC RW caused the engine
   container to be killed (exit 137) and the Deployment rolled a new pod. That path was abandoned.
3. Ephemeral coordinator Job harness (`ao-pps-warmup`) started `main.py --batch`
   successfully (process alive, ollama reachable, `step_1-spec.json` written) but after
   **27+ minutes** produced **zero** `agentic-orchestrator-worker` Jobs and no new
   warm-pool queue entries (queue still only had Aug 18 leftovers). Warmup was aborted
   rather than wait indefinitely.

## Step 3 result (usable on the slide as a floor, not a workflow delta)

**Pod startup floor median: 3.028s** (create Job with worker image + `python -c pass` through Complete).

Caveats:
- This is **pod startup floor**, not Job-per-step vs warm-pool workflow cost.
- Persistent `AGENTIC_K8S_WARM_POOL_ENABLED` in Secret remained **1** (unchanged).
- Do not present 3.028s as "what pod per step saves vs warm pool."
