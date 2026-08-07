/// IPv4 dotted-quad + prefix helpers for admin network API.
library;

final _v4 = RegExp(
  r'^(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}'
  r'(?:25[0-5]|2[0-4]\d|[01]?\d\d?)$',
);

bool isIpv4(String s) => _v4.hasMatch(s.trim());

/// Returns null if valid; else an error message.
String? validateManualIpv4({
  required String address,
  required int prefix,
  String? gateway,
  List<String> dns = const [],
}) {
  if (!isIpv4(address)) return 'invalid_address';
  if (prefix < 1 || prefix > 32) return 'invalid_prefix';
  if (gateway != null && gateway.trim().isNotEmpty && !isIpv4(gateway)) {
    return 'invalid_gateway';
  }
  for (final d in dns) {
    final t = d.trim();
    if (t.isEmpty) continue;
    if (!isIpv4(t)) return 'invalid_dns';
  }
  return null;
}
