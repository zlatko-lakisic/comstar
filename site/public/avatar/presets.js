/**
 * Emblem presets for the COMSTAR avatar.
 *
 * Each preset is SVG markup centred on the origin, drawn inside a 512x512
 * viewBox whose origin has already been translated to the middle. The renderer
 * scales and fades the whole emblem by state; two optional hooks give a preset
 * extra behaviour:
 *
 *   .cs-rings   this group counter-rotates against its own halo copy, and
 *               spins faster while `thinking` is set
 *   .cs-bars    every <rect> inside is treated as a spectrum bar and its
 *               height is driven by speech amplitude with a phase offset
 *
 * Neither hook is required. A preset with no `.cs-rings` simply sits still.
 *
 * Add your own by appending to EMBLEMS; `avatar.render` in comstar.yaml takes
 * any key from this object. Raw SVG markup is not accepted at runtime.
 */

const PALE = '#eaf6ff';
const BLUE = '#a8d8ff';
const CYAN = '#7fc4ff';
const DARK = '#0d2136';

/** The ComStar starburst. The project's mark, and the default. */
const starburst = `
<g class="cs-rings">
  <circle r="196" fill="none" stroke="#cfeaff" stroke-width="7" stroke-dasharray="330 105"/>
  <circle r="172" fill="none" stroke="${BLUE}" stroke-width="5" stroke-dasharray="72 370"/>
  <circle r="155" fill="none" stroke="${BLUE}" stroke-width="5" stroke-dasharray="72 335"/>
  <circle r="138" fill="none" stroke="${BLUE}" stroke-width="5" stroke-dasharray="72 300"/>
</g>
<g class="cs-star">
  <path fill="${PALE}" d="M0 -246 L19 -60 L77 -123 L35 -28 L169 -53 L46 0 L169 53 L35 28
    L77 123 L19 60 L0 246 L-19 60 L-77 123 L-35 28 L-169 53 L-46 0 L-169 -53 L-35 -28
    L-77 -123 L-19 -60 Z"/>
  <path fill="${DARK}" d="M0 -109 L16 -35 L67 -60 L25 -14 L95 0 L25 14 L67 60 L16 35
    L0 109 L-16 35 L-67 60 L-25 14 L-95 0 L-25 -14 L-67 -60 L-16 -35 Z"/>
  <path fill="none" stroke="${CYAN}" stroke-width="4" d="M0 -46 L39 35 L-39 35 Z"/>
  <g stroke="${CYAN}" stroke-width="2.5">
    <path d="M-18 22 L-18 4 M0 22 L0 -2 M18 22 L18 8 M-18 14 L0 8 M0 8 L18 14"/>
    <circle cx="-18" cy="2" r="3" fill="${CYAN}" stroke="none"/>
    <circle cx="0" cy="-4" r="3" fill="${CYAN}" stroke="none"/>
    <circle cx="18" cy="6" r="3" fill="${CYAN}" stroke="none"/>
  </g>
</g>`;

/** Hexagonal containment rings around a faceted core. Industrial, machine-like. */
const hex = (r) => Array.from({ length: 6 }, (_, i) => {
  const a = (Math.PI / 3) * i - Math.PI / 2;
  return `${(Math.cos(a) * r).toFixed(1)} ${(Math.sin(a) * r).toFixed(1)}`;
}).join(' L ');

const reactor = `
<g class="cs-rings">
  <path fill="none" stroke="#cfeaff" stroke-width="6" stroke-dasharray="120 42"
        d="M ${hex(206)} Z"/>
  <path fill="none" stroke="${BLUE}" stroke-width="4" stroke-dasharray="34 96"
        d="M ${hex(176)} Z"/>
  <path fill="none" stroke="${BLUE}" stroke-width="3" stroke-dasharray="18 70"
        d="M ${hex(150)} Z"/>
</g>
<g>
  <path fill="${DARK}" stroke="${PALE}" stroke-width="6" d="M ${hex(104)} Z"/>
  <path fill="none" stroke="${CYAN}" stroke-width="3" d="M ${hex(72)} Z"/>
  <path fill="${PALE}" d="M0 -46 L40 -23 L40 23 L0 46 L-40 23 L-40 -23 Z"/>
  <g stroke="${CYAN}" stroke-width="3" opacity="0.85">
    <path d="M0 -104 L0 -150 M90 52 L130 75 M-90 52 L-130 75"/>
  </g>
</g>`;

/** A single vertical sensor slit between bracket arcs. Watchful, minimal. */
const sentinel = `
<g class="cs-rings">
  <circle r="200" fill="none" stroke="${BLUE}" stroke-width="4" stroke-dasharray="26 108"/>
  <circle r="178" fill="none" stroke="#cfeaff" stroke-width="6" stroke-dasharray="250 380"
          transform="rotate(-125)"/>
</g>
<g>
  <path fill="none" stroke="${PALE}" stroke-width="10" stroke-linecap="round"
        d="M-96 -104 A 132 132 0 0 0 -96 104"/>
  <path fill="none" stroke="${PALE}" stroke-width="10" stroke-linecap="round"
        d="M96 -104 A 132 132 0 0 1 96 104"/>
  <rect x="-19" y="-128" width="38" height="256" rx="19" fill="${PALE}"/>
  <rect x="-8" y="-104" width="16" height="208" rx="8" fill="${DARK}"/>
  <circle r="13" fill="${CYAN}"/>
  <g stroke="${CYAN}" stroke-width="3" stroke-linecap="round" opacity="0.8">
    <path d="M-150 0 L-186 0 M150 0 L186 0"/>
  </g>
</g>`;

/** Radial spectrum. The most reactive to speech, the least symbolic. */
const bars = Array.from({ length: 40 }, (_, i) =>
  `<g transform="rotate(${i * 9})"><rect x="-3.5" y="-198" width="7" height="34" rx="3.5" fill="${PALE}"/></g>`
).join('');

const spectrum = `
<g class="cs-rings">
  <circle r="214" fill="none" stroke="${BLUE}" stroke-width="3" stroke-dasharray="14 54"/>
</g>
<g class="cs-bars">${bars}</g>
<g>
  <circle r="112" fill="none" stroke="${BLUE}" stroke-width="4" opacity="0.7"/>
  <circle r="74" fill="${DARK}" stroke="${PALE}" stroke-width="6"/>
  <circle r="30" fill="${CYAN}"/>
</g>`;

/** Navigational instrument. Precise and quiet, reads as a tool not a face. */
const ticks = Array.from({ length: 48 }, (_, i) => {
  const major = i % 4 === 0;
  return `<g transform="rotate(${i * 7.5})"><line x1="0" y1="-196" x2="0" y2="${major ? -172 : -184}"
    stroke="${major ? PALE : BLUE}" stroke-width="${major ? 5 : 2.5}" stroke-linecap="round"/></g>`;
}).join('');

const instrument = `
<g class="cs-rings">
  ${ticks}
  <circle r="206" fill="none" stroke="${BLUE}" stroke-width="2.5" opacity="0.6"/>
</g>
<g>
  <circle r="146" fill="none" stroke="${PALE}" stroke-width="5" stroke-dasharray="200 60"/>
  <g stroke="${CYAN}" stroke-width="3" stroke-linecap="round" opacity="0.9">
    <path d="M-146 0 L-58 0 M146 0 L58 0 M0 -146 L0 -58 M0 146 L0 58"/>
  </g>
  <path fill="${PALE}" d="M0 -62 L44 0 L0 62 L-44 0 Z"/>
  <path fill="${DARK}" d="M0 -30 L21 0 L0 30 L-21 0 Z"/>
</g>`;

export const EMBLEMS = { starburst, reactor, sentinel, spectrum, instrument };

export const EMBLEM_NAMES = Object.keys(EMBLEMS);

/** Accepts a known preset name only. Raw SVG markup is rejected (XSS). */
export function resolveEmblem(nameOrMarkup) {
  if (!nameOrMarkup) return EMBLEMS.starburst;
  const key = String(nameOrMarkup).trim();
  if (EMBLEMS[key]) return EMBLEMS[key];
  console.warn(`[avatar] unknown emblem "${key}", using starburst`);
  return EMBLEMS.starburst;
}
