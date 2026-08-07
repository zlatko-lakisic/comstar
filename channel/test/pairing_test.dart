import 'dart:io';

import 'package:comstar_channel/bindings.dart';
import 'package:comstar_channel/identity.dart';
import 'package:comstar_channel/identity_resolver.dart';
import 'package:comstar_channel/pairing.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late BindingStore store;
  late PairingManager pairing;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('comstar-pair-');
    store = BindingStore(root: tmp);
    await store.load();
    pairing = PairingManager(bindings: store);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('telegram start payload parsing', () {
    expect(PairingManager.telegramStartPayload('/start'), '');
    expect(PairingManager.telegramStartPayload('/start pair_abc'), 'pair_abc');
    expect(
      PairingManager.telegramStartPayload('/start@Bot pair_xyz'),
      'pair_xyz',
    );
    expect(PairingManager.telegramStartPayload('hello'), isNull);
  });

  test('complete pairing persists binding', () async {
    final a = await pairing.begin(
      userid: 'zlatko',
      provider: 'telegram',
      urlBuilder: (t) => PairingManager.telegramPairUrl(
        botUsername: 'bot',
        token: t,
      ),
    );
    final uid = await pairing.completeFromStartPayload(
      provider: 'telegram',
      senderId: '42',
      payload: 'pair_${a.token}',
    );
    expect(uid, 'zlatko');
    expect(store.useridFor('telegram', '42'), 'zlatko');

    final resolver = IdentityResolver(
      staticAllowlist: Allowlist(const {}),
      bindings: store,
    );
    expect(resolver.useridFor(provider: 'telegram', senderId: '42'), 'zlatko');
    expect(resolver.senderIdsFor('zlatko'), ['42']);
  });

  test('static allowlist still resolves', () {
    final resolver = IdentityResolver(
      staticAllowlist: Allowlist({'111': 'zlatko'}),
      bindings: store,
    );
    expect(resolver.useridFor(provider: 'telegram', senderId: '111'), 'zlatko');
  });
}
