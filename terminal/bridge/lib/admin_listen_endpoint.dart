import 'dart:io';

/// Classify a Linux/macOS interface name for Admin badge display.
String classifyIfaceKind(String name) {
  final n = name.toLowerCase();
  if (n.startsWith('tun') ||
      n.startsWith('tap') ||
      n.startsWith('wg') ||
      n.contains('ovpn') ||
      n.contains('vpn')) {
    return 'vpn';
  }
  if (n.startsWith('wl') || n.startsWith('wlan') || n.startsWith('wifi')) {
    return 'wlan';
  }
  if (n.startsWith('eth') ||
      n.startsWith('en') ||
      n.startsWith('em') ||
      n.startsWith('eno') ||
      n.startsWith('ens') ||
      n.startsWith('enp')) {
    return 'lan';
  }
  return 'lan';
}

/// Strip brackets/port from an HTTP Host header; return IPv4 if Host is an IP.
String? ipv4FromHostHeader(String? hostHeader) {
  if (hostHeader == null) return null;
  var h = hostHeader.trim().toLowerCase();
  if (h.isEmpty) return null;
  // [v6]:port — ignore
  if (h.startsWith('[')) return null;
  // host:port
  final colon = h.lastIndexOf(':');
  if (colon > 0 && !h.contains('::')) {
    final maybePort = h.substring(colon + 1);
    if (int.tryParse(maybePort) != null) {
      h = h.substring(0, colon);
    }
  }
  final addr = InternetAddress.tryParse(h);
  if (addr == null || addr.type != InternetAddressType.IPv4) return null;
  if (addr.isLoopback) return null;
  return addr.address;
}

class ListenEndpoint {
  const ListenEndpoint({required this.ip, required this.kind});

  final String ip;

  /// `lan` | `wlan` | `vpn`
  final String kind;

  Map<String, Object?> toJson() => {'ip': ip, 'kind': kind};
}

typedef InterfaceLister = Future<List<NetworkInterface>> Function({
  bool includeLinkLocal,
  bool includeLoopback,
  InternetAddressType? type,
});

/// Pick the IPv4 the admin client is most likely using.
///
/// Prefers the Host header when it matches a local address; otherwise prefers
/// lan → wlan → vpn → first non-loopback IPv4.
Future<ListenEndpoint?> resolveListenEndpoint({
  String? hostHeader,
  InterfaceLister? listInterfaces,
}) async {
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

  final entries = <({String ip, String kind, String iface})>[];
  for (final iface in ifaces) {
    final kind = classifyIfaceKind(iface.name);
    for (final addr in iface.addresses) {
      if (addr.type != InternetAddressType.IPv4) continue;
      if (addr.isLoopback) continue;
      entries.add((ip: addr.address, kind: kind, iface: iface.name));
    }
  }
  if (entries.isEmpty) return null;

  final hostIp = ipv4FromHostHeader(hostHeader);
  if (hostIp != null) {
    for (final e in entries) {
      if (e.ip == hostIp) {
        return ListenEndpoint(ip: e.ip, kind: e.kind);
      }
    }
  }

  ListenEndpoint? pick(String kind) {
    for (final e in entries) {
      if (e.kind == kind) return ListenEndpoint(ip: e.ip, kind: e.kind);
    }
    return null;
  }

  return pick('lan') ??
      pick('wlan') ??
      pick('vpn') ??
      ListenEndpoint(ip: entries.first.ip, kind: entries.first.kind);
}
