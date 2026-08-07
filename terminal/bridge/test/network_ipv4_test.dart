import 'package:comstar_bridge/net/ipv4.dart';
import 'package:test/test.dart';

void main() {
  group('isIpv4', () {
    test('accepts dotted quads', () {
      expect(isIpv4('192.168.89.34'), isTrue);
      expect(isIpv4('10.0.0.1'), isTrue);
      expect(isIpv4('255.255.255.255'), isTrue);
    });

    test('rejects junk', () {
      expect(isIpv4(''), isFalse);
      expect(isIpv4('192.168.89'), isFalse);
      expect(isIpv4('192.168.89.256'), isFalse);
      expect(isIpv4('hostname'), isFalse);
    });
  });

  group('validateManualIpv4', () {
    test('ok', () {
      expect(
        validateManualIpv4(
          address: '192.168.89.34',
          prefix: 24,
          gateway: '192.168.89.1',
          dns: ['192.168.89.1', '1.1.1.1'],
        ),
        isNull,
      );
    });

    test('bad address', () {
      expect(
        validateManualIpv4(address: 'x', prefix: 24),
        'invalid_address',
      );
    });

    test('bad prefix', () {
      expect(
        validateManualIpv4(address: '1.2.3.4', prefix: 0),
        'invalid_prefix',
      );
      expect(
        validateManualIpv4(address: '1.2.3.4', prefix: 33),
        'invalid_prefix',
      );
    });
  });
}
