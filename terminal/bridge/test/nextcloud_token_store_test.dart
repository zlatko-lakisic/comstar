import 'dart:io';

import 'package:comstar_bridge/nextcloud/token_store.dart';
import 'package:test/test.dart';

void main() {
  group('NextcloudTokenStore', () {
    late Directory tmp;
    late NextcloudTokenStore store;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('comstar_nc_tokens_');
      store = NextcloudTokenStore(root: Directory('${tmp.path}/nextcloud'));
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('write and read credentials', () async {
      await store.writeCredentials(
        'zlatko.lakisic',
        username: 'zlatko',
        appPassword: 'app-secret',
        host: 'https://cloud.example/',
      );
      final c = await store.readCredentials('zlatko.lakisic');
      expect(c, isNotNull);
      expect(c!.host, 'https://cloud.example');
      expect(c.username, 'zlatko');
      expect(c.appPassword, 'app-secret');
      // faceId alias
      final viaFace = await store.readCredentials('zlatko');
      expect(viaFace?.username, 'zlatko');
    });

    test('status omits password', () async {
      await store.writeCredentials(
        'zlatko',
        username: 'z',
        appPassword: 'secret',
        host: 'https://nc.test',
      );
      final s = await store.status('zlatko');
      expect(s['linked'], isTrue);
      expect(s['username'], 'z');
      expect(s.containsKey('app_password'), isFalse);
      expect(jsonSafe(s).contains('secret'), isFalse);
    });

    test('clear removes files', () async {
      await store.writeCredentials(
        'zlatko',
        username: 'z',
        appPassword: 'secret',
        host: 'https://nc.test',
      );
      await store.clear('zlatko');
      expect(await store.hasCredentials('zlatko'), isFalse);
    });
  });
}

String jsonSafe(Map<String, Object?> m) => m.toString();
