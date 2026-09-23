# Voice closed-form catalog

Closed-form hallway utterances have a known **data source** and **answer shape**
before any model runs. Classification always happens on the **Pi bridge**
(`comstar-bridge`). AO does not own this catalog.

## Routing mode

`orchestration.utterance_routing` (env `COMSTAR_UTTERANCE_ROUTING`, Admin Agents
toggle → runtime override):

| Value | Behavior |
|---|---|
| `split` (default) | Closed-form families below → bridge-local or pinned AO; else open AO |
| `ao` | Skip most content closed-form; forward to AO. **Exception:** home status overview stays bridge-local (brief TTS). |

Precedence: env → Admin runtime → yaml.

**Always local (both modes):** terminal self-care (sleep, volume, heal, restart,
reboot, health); Google / Nextcloud / channel **pairing**; and **home status**
overview (“status of my home”, “how’s the house”) — short HA spoken summary so
TTS does not read long AO markdown.

When AO still returns markdown (lists, bold, headings, links, fences), the bridge
runs `formatForSpeech` before every TTS call so the voice reads natural prose
instead of markup characters.

Lanes: `bridge-local` | `pinned-ao` | `open-ao` | `defer`.

Regression utterances: `terminal/bridge/test/fixtures/closed_form_utterances.yaml`.

## Anti-confusion

| Cue | Lane / source |
|---|---|
| around the house / last home / leave | HA `person.*` presence |
| status of my home / house status / around my house | HA home overview (presence + locks + garage) |
| driveway / front door / camera / saw you | Frigate vision MCP |
| family car / plate / LPR | Frigate/HA car sensors — never `person.*` |
| in the world / news / headlines | pinned `fetch_url` |
| what’s up (alone) | social |
| what’s happening + world/news | news, not social |
| bare what’s happening / banter after news | not news — do not recycle headlines |
| weather / forecast / rain | pinned `weather_mcp` (not news) |

## Families

### A. Control plane — always local

| Examples | Lane | Status |
|---|---|---|
| go to sleep, mute, volume up, set volume to 40 | bridge-local | done |
| how are you feeling / health, heal yourself, restart audio/kiosk, reboot | bridge-local | done |
| who am I, recognize me | bridge-local (split) | done |

### B. Clock & calendar

| Examples | Lane | Status |
|---|---|---|
| what time is it, what’s today’s date, what day is it, timezone, season | bridge-local | done |
| what’s on my calendar today | bridge-local | done |
| what’s on my calendar tomorrow | bridge-local | done |
| what’s my next meeting | bridge-local | done |
| list my calendars | bridge-local | done |

### C. Mail / workspace

| Examples | Lane | Status |
|---|---|---|
| what’s in my gmail today, google drive | bridge-local | done |
| reconnect / unlink my Google | bridge-local (pairing) | done |
| compose email to … | open-ao / defer | defer |

### D. Presence & people

| Examples | Lane | Status |
|---|---|---|
| who’s home, anyone home | bridge-local | done |
| where is Adna, is Zlatko home | bridge-local | done |
| when did Adna leave, last time around the house | bridge-local | done |
| status of my home, house status, what’s going on around my house | bridge-local **always** | done |

### E. Cameras / visitors / LPR

| Examples | Lane | Status |
|---|---|---|
| who was in the driveway today | bridge-local (vision) | done |
| when did you last see Adna on the driveway | bridge-local (vision) | done |
| where’s the family car, when did the car leave | bridge-local (HA Frigate) | done |

### F. House systems (reads)

| Examples | Lane | Status |
|---|---|---|
| is the front/office/back door locked | bridge-local | done |
| is the garage door open | bridge-local | done |
| turn on the lights | open-ao / defer writes | defer |

### G. Network / media / irrigation

| Examples | Lane | Status |
|---|---|---|
| WAN IP, speedtest, bandwidth, torrents, irrigation | bridge-local | done |

### H. News / weather

| Examples | Lane | Status |
|---|---|---|
| what’s happening in the world, tell me the news | pinned-ao `fetch_url` | done |
| what’s the weather, will it rain | pinned-ao `weather_mcp` | done |

### I. Social

| Examples | Lane | Status |
|---|---|---|
| hi, thanks, how are you, what’s up | bridge-local | done |
| what’s happening in the world | must **not** match social | done |

### J. Directory

| Examples | Lane | Status |
|---|---|---|
| who’s in the household | open-ao / gap | gap |

### K. Meta

| Examples | Lane | Status |
|---|---|---|
| what can you do | open-ao / gap | gap |

## Adding a family

1. Name the family and list ≥5 spoken variants in the fixture YAML.
2. Implement `parse*` (or pinned helper) + tests.
3. Update this doc status to `done`.
4. Never add bridge regex without a fixture row.
