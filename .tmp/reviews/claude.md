# Claude review (captured from chat, 2026-08-03)

Third fetch noted stale HTML at time of review (pre-deploy or CDN). Caveat: CSS/JS-only changes invisible to HTML-only review.

## Gaps rather than errors (new findings)

### There is no physicality on a page about a physical object
Specs list ports, languages, licence. No dimensions, weight, power draw, enclosure description. Always-on power matters (~8-12W for Pi+panel+speakers; GPU server is larger). No photo of assembled form factor.

### What happens when two people are in the room
Identity section says partner gets theirs; never says what happens when both are present. Contracts already handle this (votes + TTL, two_people.yaml). One FAQ entry fixes it.

### Nothing about languages
Whisper and Piper support many languages. One FAQ line opens the audience.

### No way to follow this
No RSS, build log, watch prompt, newsletter. Most readers will not build this weekend. Add visible tracker link and "star to follow along" near status.

### The status section says what's broken but not what's next
Need direction: next up wake word training, room test, walk-up demo. Momentum vs abandoned.

### Stale FAQ note for later
FAQ says "It does not do music streaming." Will need update when music control ships.
