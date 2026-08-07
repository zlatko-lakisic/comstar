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
  });

  final bool enabled;

  /// `openvpn` | `l2tp` | `auto` (prefer OpenVPN when both exist).
  final String protocol;

  final List<String> homeCidrs;
  final int checkIntervalSeconds;

  /// NetworkManager connection id / name for OpenVPN.
  final String openvpnConnection;

  /// NetworkManager connection id / name for L2TP/IPsec.
  final String l2tpConnection;

  RoadConfig copyWith({
    bool? enabled,
    String? protocol,
    List<String>? homeCidrs,
    int? checkIntervalSeconds,
    String? openvpnConnection,
    String? l2tpConnection,
  }) {
    return RoadConfig(
      enabled: enabled ?? this.enabled,
      protocol: protocol ?? this.protocol,
      homeCidrs: homeCidrs ?? this.homeCidrs,
      checkIntervalSeconds: checkIntervalSeconds ?? this.checkIntervalSeconds,
      openvpnConnection: openvpnConnection ?? this.openvpnConnection,
      l2tpConnection: l2tpConnection ?? this.l2tpConnection,
    );
  }

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'protocol': protocol,
        'home_cidrs': homeCidrs,
        'check_interval_seconds': checkIntervalSeconds,
        'openvpn_connection': openvpnConnection,
        'l2tp_connection': l2tpConnection,
      };

  static RoadConfig fromJson(Map<String, dynamic> map, {RoadConfig? base}) {
    final b = base ?? const RoadConfig();
    final cidrsRaw = map['home_cidrs'];
    List<String>? cidrs;
    if (cidrsRaw is List) {
      cidrs = cidrsRaw.map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
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
    );
  }
}
