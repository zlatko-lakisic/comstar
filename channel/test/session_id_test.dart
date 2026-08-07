import 'package:comstar_channel/session.dart';
import 'package:test/test.dart';

void main() {
  test('session id never shares terminal id', () {
    expect(ChannelSessionManager.sessionIdFor('zlatko'), 'comstar-zlatko-channel');
    expect(
      ChannelSessionManager.sessionIdFor('zlatko'),
      isNot('comstar-zlatko'),
    );
  });

  test('mtls enabled without PEMs fails closed', () async {
    final mgr = ChannelSessionManager(
      baseUrl: 'https://10.0.10.16:8765',
      overlayRoot: '/tmp',
      mtlsEnabled: true,
      mtlsMaterialDir: '/tmp/comstar-mtls-missing-${DateTime.now().microsecondsSinceEpoch}',
    );
    await expectLater(
      mgr.turn('zlatko', 'hi'),
      throwsA(isA<StateError>()),
    );
  });

  test('mtls enabled requires https base url', () async {
    final mgr = ChannelSessionManager(
      baseUrl: 'http://10.0.10.16:8765',
      overlayRoot: '/tmp',
      mtlsEnabled: true,
      mtlsMaterialDir: '/tmp/comstar-mtls-missing-x',
    );
    await expectLater(
      mgr.turn('zlatko', 'hi'),
      throwsA(
        predicate(
          (e) => e is StateError && '$e'.contains('https://'),
        ),
      ),
    );
  });
}
