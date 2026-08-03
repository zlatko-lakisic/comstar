# ADR 0004 — Terminal control (sleep + speaker volume)

**Status:** Accepted  
**Date:** 2026-08-03  
**Milestone:** M5.4 / voice control

## Context

Users want the voice agent to put COMSTAR into a dormant mode (ignore vision and
speech until `hey comstar`) and to change HDMI speaker volume / mute. Control must
not ferry through AO’s planner as custom protocol — it should be ordinary MCP tools
on the Pi.

## Decision

1. **Bridge owns control.** Sleep state and `pactl` volume live in the Dart bridge.
2. **Agent API is tunnelled `client.terminal` MCP** (`mcp/terminal_mcp`), calling
   loopback HTTP `http://127.0.0.1:8776/control/...`.
3. **Sleep ≠ OS suspend.** Processes keep running; attention state is `sleeping`.
4. **Mute/volume = speaker sink** (prefer `comstar_hdmi`), not microphone mute.
5. **Guest sessions** do not register `client.terminal`.

## Consequences

- Requires AO `AGENTIC_SERVE_MCP_TUNNEL=1` and a working `LocalMcpHost` proxy.
- Voice responder prompt must instruct tool use for sleep/volume before confirming.
- Wake word remains the only exit from sleep (CONTRACTS §8).
