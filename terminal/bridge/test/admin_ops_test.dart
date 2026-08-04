import 'package:comstar_bridge/admin_ops.dart';
import 'package:test/test.dart';

void main() {
  group('resolveAdminUnit', () {
    test('short keys', () {
      expect(resolveAdminUnit('bridge'), 'comstar-bridge.service');
      expect(resolveAdminUnit('audio'), 'comstar-audio.service');
      expect(resolveAdminUnit('kiosk'), 'comstar-kiosk.service');
      expect(resolveAdminUnit('stt'), 'comstar-stt.service');
      expect(resolveAdminUnit('health'), 'comstar-health.service');
      expect(resolveAdminUnit('all'), 'all');
    });

    test('full unit names', () {
      expect(resolveAdminUnit('comstar-bridge.service'), 'comstar-bridge.service');
      expect(resolveAdminUnit('comstar-bridge'), 'comstar-bridge.service');
    });

    test('rejects unknown', () {
      expect(resolveAdminUnit('ssh'), isNull);
      expect(resolveAdminUnit('rm -rf /'), isNull);
      expect(resolveAdminUnit(''), isNull);
    });
  });

  group('adminTokenMatches', () {
    test('loopback skips token', () {
      expect(
        adminTokenMatches(
          lanBound: false,
          expectedToken: 'secret',
          headerToken: null,
          queryToken: null,
        ),
        isTrue,
      );
    });

    test('LAN requires matching token', () {
      expect(
        adminTokenMatches(
          lanBound: true,
          expectedToken: 'secret',
          headerToken: null,
          queryToken: null,
        ),
        isFalse,
      );
      expect(
        adminTokenMatches(
          lanBound: true,
          expectedToken: 'secret',
          headerToken: 'secret',
          queryToken: null,
        ),
        isTrue,
      );
      expect(
        adminTokenMatches(
          lanBound: true,
          expectedToken: 'secret',
          headerToken: null,
          queryToken: 'secret',
        ),
        isTrue,
      );
      expect(
        adminTokenMatches(
          lanBound: true,
          expectedToken: 'secret',
          headerToken: 'wrong',
          queryToken: null,
        ),
        isFalse,
      );
    });

    test('empty expected token fails when LAN bound', () {
      expect(
        adminTokenMatches(
          lanBound: true,
          expectedToken: '',
          headerToken: 'x',
          queryToken: null,
        ),
        isFalse,
      );
    });
  });
}
