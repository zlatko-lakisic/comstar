import 'dart:io';

import 'package:comstar_bridge/google/token_store.dart';
import 'package:test/test.dart';

void main() {
  group('GoogleTokenStore', () {
    late Directory tmp;
    late GoogleTokenStore store;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('comstar_google_tokens_');
      store = GoogleTokenStore(root: Directory('${tmp.path}/google'));
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('write and read refresh token with 0600', () async {
      await store.writeRefreshToken('zlatko', 'rt-secret');
      expect(await store.readRefreshToken('zlatko'), 'rt-secret');
      expect(await store.hasTokens('zlatko'), isTrue);

      final file = File('${store.root.path}/zlatko.json');
      expect(file.existsSync(), isTrue);
      if (Platform.isMacOS || Platform.isLinux) {
        final stat = await Process.run('stat', ['-f', '%Lp', file.path]);
        if (stat.exitCode == 0) {
          expect(stat.stdout.toString().trim(), '600');
        }
      }
    });

    test('clear removes token', () async {
      await store.writeRefreshToken('zlatko', 'rt');
      await store.clear('zlatko');
      expect(await store.readRefreshToken('zlatko'), isNull);
      expect(await store.hasTokens('zlatko'), isFalse);
    });

    test('rejects guest userid', () {
      expect(
        () => GoogleTokenStore.safeUserid('guest'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
