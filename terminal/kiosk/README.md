# terminal/kiosk

The avatar renderer. Chromium in kiosk mode on the Pi, driven entirely by
bridge messages over the local WebSocket (`docs/CONTRACTS.md` §1).

```
kiosk/
├── index.html          production entry point (portrait-friendly)
├── debug.html          standalone harness, no bridge required
├── avatar.js           Three.js scene, GLB head, starburst, gaze, analyser
├── bridge_client.js    envelope + reconnect
├── health_chart.js     CPU/mem sparkline
└── assets/
    ├── starburst.svg
    ├── reference-head.png
    ├── comstar-head.glb   optional — drop here when ready
    └── vendor/            vendored three@0.169 (offline-safe)
```

## Portrait panel

The Pi compositor output is rotated via `scripts/set-portrait.sh` (default
transform `90`). `kiosk-launch.sh` applies it before Chromium starts. Override
with `COMSTAR_DISPLAY_TRANSFORM=270` if the image is upside-down.

## Run it right now, with no model

```bash
cd terminal/kiosk
python3 -m http.server 5173
```

Open `http://localhost:5173/debug.html`. Without `assets/comstar-head.glb` the
console logs `glb_load_failed` and you get the starburst alone — that is the
intended fallback.

Must be served over HTTP (ES modules).

## Adding the head

Drop your GLB at `assets/comstar-head.glb`. Nothing else changes. Aim for
30k–50k triangles and 1024/2048 textures. Face should point down `+Z`.
