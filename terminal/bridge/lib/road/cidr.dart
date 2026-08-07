/// IPv4 CIDR parse + containment (road home detection).
library;

import 'dart:io';

class Ipv4Cidr {
  Ipv4Cidr({required this.network, required this.prefixLength}) {
    if (prefixLength < 0 || prefixLength > 32) {
      throw FormatException('prefix length out of range: $prefixLength');
    }
  }

  /// Network address as host-order uint32.
  final int network;
  final int prefixLength;

  int get mask {
    if (prefixLength == 0) return 0;
    if (prefixLength == 32) return 0xffffffff;
    return (0xffffffff << (32 - prefixLength)) & 0xffffffff;
  }

  bool containsAddress(InternetAddress addr) {
    if (addr.type != InternetAddressType.IPv4) return false;
    final raw = addr.rawAddress;
    if (raw.length != 4) return false;
    final ip = (raw[0] << 24) | (raw[1] << 16) | (raw[2] << 8) | raw[3];
    return (ip & mask) == (network & mask);
  }

  bool containsIpString(String ip) {
    final addr = InternetAddress.tryParse(ip);
    if (addr == null) return false;
    return containsAddress(addr);
  }

  @override
  String toString() {
    final a = (network >> 24) & 0xff;
    final b = (network >> 16) & 0xff;
    final c = (network >> 8) & 0xff;
    final d = network & 0xff;
    return '$a.$b.$c.$d/$prefixLength';
  }

  /// Parse `a.b.c.d/nn` or bare `a.b.c.d` (treated as /32).
  static Ipv4Cidr parse(String raw) {
    final s = raw.trim();
    if (s.isEmpty) throw FormatException('empty CIDR');
    final slash = s.indexOf('/');
    final addrPart = slash < 0 ? s : s.substring(0, slash);
    final prefix = slash < 0
        ? 32
        : int.tryParse(s.substring(slash + 1).trim()) ??
            (throw FormatException('bad prefix: $s'));
    final addr = InternetAddress.tryParse(addrPart);
    if (addr == null || addr.type != InternetAddressType.IPv4) {
      throw FormatException('bad IPv4: $s');
    }
    final rawBytes = addr.rawAddress;
    final network =
        (rawBytes[0] << 24) | (rawBytes[1] << 16) | (rawBytes[2] << 8) | rawBytes[3];
    final cidr = Ipv4Cidr(network: network, prefixLength: prefix);
    // Canonicalize to network address.
    return Ipv4Cidr(network: network & cidr.mask, prefixLength: prefix);
  }
}

List<Ipv4Cidr> parseCidrList(Iterable<String> raw) {
  final out = <Ipv4Cidr>[];
  for (final s in raw) {
    out.add(Ipv4Cidr.parse(s));
  }
  return out;
}
