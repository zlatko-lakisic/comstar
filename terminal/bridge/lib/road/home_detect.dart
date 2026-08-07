/// Detect whether this host currently has an address on a home CIDR.
library;

import 'dart:io';

import 'package:comstar_bridge/road/cidr.dart';

class HomeDetectResult {
  const HomeDetectResult({
    required this.atHome,
    required this.matchedAddrs,
    required this.allAddrs,
  });

  final bool atHome;
  final List<String> matchedAddrs;
  final List<String> allAddrs;

  Map<String, Object?> toJson() => {
        'at_home': atHome,
        'matched_addrs': matchedAddrs,
        'all_addrs': allAddrs,
      };
}

typedef InterfaceLister = Future<List<NetworkInterface>> Function({
  bool includeLinkLocal,
  bool includeLoopback,
  InternetAddressType? type,
});

/// Returns true when any non-loopback IPv4 is inside [homeCidrs].
Future<HomeDetectResult> detectHome({
  required List<String> homeCidrs,
  InterfaceLister? listInterfaces,
}) async {
  final cidrs = parseCidrList(homeCidrs);
  final lister = listInterfaces ??
      (({bool includeLinkLocal = false,
          bool includeLoopback = false,
          InternetAddressType? type}) {
        return NetworkInterface.list(
          includeLinkLocal: includeLinkLocal,
          includeLoopback: includeLoopback,
          type: type ?? InternetAddressType.IPv4,
        );
      });

  final ifaces = await lister(
    includeLinkLocal: false,
    includeLoopback: false,
    type: InternetAddressType.IPv4,
  );

  final all = <String>[];
  final matched = <String>[];
  for (final iface in ifaces) {
    for (final addr in iface.addresses) {
      if (addr.type != InternetAddressType.IPv4) continue;
      if (addr.isLoopback) continue;
      final ip = addr.address;
      all.add(ip);
      for (final c in cidrs) {
        if (c.containsAddress(addr)) {
          matched.add(ip);
          break;
        }
      }
    }
  }
  return HomeDetectResult(
    atHome: matched.isNotEmpty,
    matchedAddrs: matched,
    allAddrs: all,
  );
}
