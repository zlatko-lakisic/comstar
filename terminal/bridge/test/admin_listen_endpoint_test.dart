import 'package:comstar_bridge/admin_listen_endpoint.dart';
import 'package:test/test.dart';

void main() {
  group('classifyIfaceKind', () {
    test('common linux names', () {
      expect(classifyIfaceKind('eth0'), 'lan');
      expect(classifyIfaceKind('enp1s0'), 'lan');
      expect(classifyIfaceKind('wlan0'), 'wlan');
      expect(classifyIfaceKind('wlp2s0'), 'wlan');
      expect(classifyIfaceKind('tun0'), 'vpn');
      expect(classifyIfaceKind('wg0'), 'vpn');
    });
  });

  group('ipv4FromHostHeader', () {
    test('parses host and host:port', () {
      expect(ipv4FromHostHeader('192.168.89.34'), '192.168.89.34');
      expect(ipv4FromHostHeader('192.168.89.34:8781'), '192.168.89.34');
      expect(ipv4FromHostHeader('comstar.example'), isNull);
      expect(ipv4FromHostHeader('127.0.0.1:8781'), isNull);
    });
  });
}
