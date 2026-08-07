/// Road / away-from-home VPN phone-home (ADR 0011).
library;

const defaultHomeCidrs = <String>[
  '192.168.89.0/24',
  '192.168.90.0/24',
  '172.16.90.0/24',
];

const roadProtocols = {'openvpn', 'l2tp', 'auto'};

class RoadConfig {
  const RoadConfig({
    this.enabled = false,
    this.protocol = 'openvpn',
    this.homeCidrs = defaultHomeCidrs,
    this.checkIntervalSeconds = 30,
    this.openvpnConnection = 'comstar-ovpn',
    this.l2tpConnection = 'comstar-l2tp',
    this.healthUrl = '',
    this.healBackoffMaxSeconds = 300,
  });

  final bool enabled;

  /// `openvpn` | `l2tp` | `auto` (prefer OpenVPN when both exist).
  final String protocol;

  final List<String> homeCidrs;

  /// Monitor tick while enabled (health + heal).
  final int checkIntervalSeconds;

  /// NetworkManager connection id / name for OpenVPN.
  final String openvpnConnection;

  /// NetworkManager connection id / name for L2TP/IPsec.
  final String l2tpConnection;

  /// HTTP probe when VPN should be up. Empty → orchestration `/health`.
  final String healthUrl;

  /// Cap for exponential heal backoff after repeated failures.
  final int healBackoffMaxSeconds;

  RoadConfig copyWith({
    bool? enabled,
    String? protocol,
    List<String>? homeCidrs,
    int? checkIntervalSeconds,
    String? openvpnConnection,
    String? l2tpConnection,
    String? healthUrl,
    int? healBackoffMaxSeconds,
  }) {
    return RoadConfig(
      enabled: enabled ?? this.enabled,
      protocol: protocol ?? this.protocol,
      homeCidrs: homeCidrs ?? this.homeCidrs,
      checkIntervalSeconds: checkIntervalSeconds ?? this.checkIntervalSeconds,
      openvpnConnection: openvpnConnection ?? this.openvpnConnection,
      l2tpConnection: l2tpConnection ?? this.l2tpConnection,
      healthUrl: healthUrl ?? this.healthUrl,
      healBackoffMaxSeconds:
          healBackoffMaxSeconds ?? this.healBackoffMaxSeconds,
    );
  }

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'protocol': protocol,
        'home_cidrs': homeCidrs,
        'check_interval_seconds': checkIntervalSeconds,
        'openvpn_connection': openvpnConnection,
        'l2tp_connection': l2tpConnection,
        'health_url': healthUrl,
        'heal_backoff_max_seconds': healBackoffMaxSeconds,
      };

  static RoadConfig fromJson(Map<String, dynamic> map, {RoadConfig? base}) {
    final b = base ?? const RoadConfig();
    final cidrsRaw = map['home_cidrs'];
    List<String>? cidrs;
    if (cidrsRaw is List) {
      cidrs = cidrsRaw
          .map((e) => e.toString().trim())
          .where((s) => s.isNotEmpty)
          .toList();
    }
    return b.copyWith(
      enabled: map.containsKey('enabled') ? map['enabled'] == true : null,
      protocol: map['protocol']?.toString(),
      homeCidrs: cidrs,
      checkIntervalSeconds: map['check_interval_seconds'] is int
          ? map['check_interval_seconds'] as int
          : int.tryParse('${map['check_interval_seconds'] ?? ''}'),
      openvpnConnection: map['openvpn_connection']?.toString(),
      l2tpConnection: map['l2tp_connection']?.toString(),
      healthUrl: map.containsKey('health_url')
          ? (map['health_url']?.toString() ?? '')
          : null,
      healBackoffMaxSeconds: map['heal_backoff_max_seconds'] is int
          ? map['heal_backoff_max_seconds'] as int
          : int.tryParse('${map['heal_backoff_max_seconds'] ?? ''}'),
    );
  }
}
