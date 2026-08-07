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
}
