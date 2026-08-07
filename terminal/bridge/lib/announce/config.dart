/// M10 announce config + quiet hours.
library;

class AnnounceConfig {
  const AnnounceConfig({
    this.enabled = true,
    this.queuePath = '',
    this.schedulePath = 'announce/schedule.yaml',
    this.haRulesPath = 'announce/ha_rules.yaml',
    this.quietStart = '22:00',
    this.quietEnd = '07:00',
    this.timezone = '',
    this.channelUrl = '',
    this.channelToken = '',
  });

  final bool enabled;

  /// SQLite path; empty → ~/.local/share/comstar/announce/queue.db
  final String queuePath;

  /// Relative to repo / config parent parent, or absolute.
  final String schedulePath;
  final String haRulesPath;

  /// Local wall-clock quiet window (hold normal; urgent may deliver).
  final String quietStart;
  final String quietEnd;

  /// IANA TZ label for schedule evaluation; empty → system local.
  final String timezone;

  /// Ada `comstar-channel` base URL for M11.6 dual-surface (e.g. http://10.0.10.16:8782).
  /// Empty disables channel delivery. Overridable via `COMSTAR_CHANNEL_URL`.
  final String channelUrl;

  /// Shared token for `X-Comstar-Channel-Token`. Env `COMSTAR_CHANNEL_TOKEN`.
  final String channelToken;
}
