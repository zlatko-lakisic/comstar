# Gemini review (captured from chat, 2026-08-03)

A deep technical, UX, and strategic review of the ComStar landing page reveals several opportunities for improvement, broken down by architectural honesty, conversion psychology, and front-end execution.

## 1. Architectural & Technical Transparency Gaps

**The Host-to-Terminal Latency Elephant:** The page sets a brutal target budget (11.8s total, with 6s+ spent in agentic reasoning). While it is commendable to be upfront about the fact that LLM + tool-calling latency is slow, the sequence graphic treats the network hop between the Raspberry Pi 4 terminal and the off-device NVIDIA server as an invisible implementation detail. You should explicitly clarify where the latency lives (e.g., "~1.2s local face reg, ~4s network transit + LLM tool loop, ~2s local Piper TTS synthesis"). If a builder reads that and thinks the Pi is doing the heavy lifting locally, they will run into severe expectation mismatches.

**The CodeProject.AI Dependency vs. Modern Ecosystems:** Listing CodeProject.AI alongside bleeding-edge modular stacks (faster-whisper, openWakeWord, Piper) creates a slight architectural dissonance. CodeProject.AI historically leans toward a heavier containerized modular wrapper model (often popular in Blue Iris/surveillance ecosystems). For a modern edge agent stack, builders might question why facial recognition isn't decoupled into a direct face_recognition or InsightFace microservice pipeline. A single line explaining why CodeProject.AI is chosen for vision handling would preempt technical skepticism.

**The "Wake Word Not Trained" Reality Check:** In the pre-alpha section, you note: "Wake word model untrained: bring-up uses a key press." For an interface framed as a walk-up ambient terminal ("Walk up. Get answered."), relying on a key press for bring-up neuters the core value proposition. While honesty is great, positioning a button-press trigger as a "walk-up" experience on the hero section creates a conceptual contradiction. It might be safer to frame the current milestone explicitly as Proximity-Triggered Key-Press Session Initiation until openWakeWord is baked in.

## 2. Copywriting & Value Propositional Edges

**The Proto Hologram Comparison is a Double-Edged Sword:** Comparing yourself to a $10K-$250K Proto Hologram box is brilliant for establishing the feeling you are chasing (embodied ambient presence vs. a flat screen). However, a skeptical developer will immediately think: "A Proto has a volumetric light field display; this is an 800x480/1280x720 HDMI panel strapped to a Pi." Lean harder into why a 2D digital avatar or dynamic SVG emblem on an inexpensive screen achieves 80% of the psychological presence of a hologram at 0.2% of the cost, rather than inviting direct physical hardware comparisons.

**The "What About My Guests?" Edge Case:** The guest session handling is a killer feature. However, it glosses over the security/privacy vector: How does it know a guest is a guest vs. an unknown family member? Does it default to a generic unauthenticated sandbox session on a facial recognition miss? Clarifying that an unrecognised face maps to a hardened zero-trust guest sandbox would satisfy paranoid self-hosters immediately.

**IP Acknowledgement Placement:** Dropping the BattleTech legal disclaimer at the very bottom in the footer (and referencing it awkwardly in the FAQ) is standard compliance, but because "ComStar" evokes a very specific sci-fi religious telecom monopoly, it borders on inviting a cease-and-desist if the project gains GitHub trending traction. Make sure the personal/non-commercial nature is bulletproof right under the main title if you intend to keep the name publicly indexed.

## 3. User Experience & Information Architecture (UI/UX)

**The Timeline / Sequence Section Lacks Interactive Proof:** The sequence breakdown (0.0s -> 1.4s -> 3.1s -> 11.8s) is structured like a vertical list. Converting this into a live stepping animation or a horizontal interactive timeline where users can click each phase to see the underlying architecture sequence would make the engineering depth tangible.

**Hardware Sourcing Friction:** The parts list totals ~$200. Adding a small note like "Tested with component X, substitutes welcome" or linking directly to verified pinout guides in the wiki would reduce drop-off for builders ready to buy today.

**Missing System State Visualization:** The page mentions "The emblem tells you at a glance: idle, watching, listening, thinking, speaking." Given that the UI relies heavily on an SVG face/emblem responding to these states, embedding a tiny animated web component or a high-res GIF preview of the actual SVG transitions on the page would instantly sell the "alive" aesthetic you are engineering.

## Summary Verdict

The page is remarkably refreshing: it avoids AI-hype sludge, speaks engineer-to-engineer, and clearly separates current status from aspirational architecture. Tightening the distinction between local terminal tasks and server-side heavy lifting, and showing (rather than just telling) what the SVG state machine looks like in motion, would elevate it from a great documentation landing page to an elite open-source project launchpad.
