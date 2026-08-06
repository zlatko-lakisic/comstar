-- COMSTAR: rename the panel HDMI ACP sink to a stable Pulse name.
-- COMSTAR_SPEAKER_SOURCE=comstar_hdmi expects this node.
-- Do not use module-remap-sink as an alias — under PipeWire it often corks
-- and swallows playback while paplay still exits 0.

rule = {
  matches = {
    {
      { "node.name", "matches", "alsa_output.platform-fef00700.hdmi.*" },
    },
  },
  apply_properties = {
    ["node.name"] = "comstar_hdmi",
    ["node.description"] = "COMSTAR HDMI",
    ["node.nick"] = "comstar_hdmi",
    -- Keep the PCM awake; suspend/resume races blank HDMI audio on some panels.
    ["session.suspend-timeout-seconds"] = 0,
  },
}
table.insert(alsa_monitor.rules, rule)
