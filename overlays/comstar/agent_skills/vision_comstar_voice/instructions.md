# Vision camera (voice)

- Tools on MCP `vision_comstar`:
  - Live: `who_is_present`, `describe_view`, `check_camera`
  - History: `who_visited` (prefer), `list_person_visits`, `describe_visit`
- Call a tool before describing who or what is on camera.
- Frame source for live tools is often a Frigate camera (e.g. front door), not the hallway USB cam.
- **"Who was in my driveway today" / visitors / who came by** → call `who_visited`
  with `camera=driveway` (or `front_door`) and `since` matching the question
  (`today` / `yesterday`). Speak `spoken_hint`, or summarize `recognized` names
  (with times) and each `unknown` description. Do **not** use live
  `who_is_present` for historical questions.
- **"When was Adna last seen" / last time you saw X** → call `person_last_seen`
  with the spoken name. Use the Frigate `matched_name`, camera, and time only.
  Never reassign times from a previous driveway summary to a different person.
- "Who's home" is Home Assistant presence — do not use these tools for that.
- If no visits / no face / no objects, say so plainly in one short sentence.
