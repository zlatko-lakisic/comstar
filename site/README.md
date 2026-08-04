# COMSTAR product page

Outcome-focused landing page for GitHub Pages
(`https://zlatko-lakisic.github.io/comstar/`). Documentation stays on the
wiki (and later `/docs/`) - this site sells the walk-up, not the contracts.

## Develop

```bash
cd site
npm install
npm run dev          # http://127.0.0.1:4321/comstar/
```

Or from the repo root: `make site-dev`.

`npm run sync-avatar` copies `terminal/kiosk/avatar.js` and `presets.js` into
`public/avatar/` so the hero never drifts from the product.

## Build

```bash
npm run build        # output in site/dist
```

## Notes

- Dark-only palette from the diagram visual system.
- Live SVG avatar is the hero; preset buttons recreate it.
- Latency numbers in the walk-up strip are labelled **targets** until M8 UAT.
- Drop a real night photo of the powered panel at `public/media/device.webp`
  when you have one.
