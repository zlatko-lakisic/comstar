import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:comstar_bridge/attention/clock.dart';
import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/directory/directory_resolver.dart';
import 'package:test/test.dart';

DirectoryConfig _dir({
  bool enabled = true,
  String sidecarUrl = 'http://127.0.0.1:18780',
  bool require = true,
  int cacheTtlSeconds = 600,
  int timeoutMs = 500,
}) =>
    DirectoryConfig(
      enabled: enabled,
      sidecarUrl: sidecarUrl,
      require: require,
      cacheTtlSeconds: cacheTtlSeconds,
      timeoutMs: timeoutMs,
    );

void main() {
  group('DirectoryResolver', () {
    late HttpServer server;
    late Uri base;
    late FakeClock clock;
    var resolveHits = 0;
    String? lastFaceId;
    String? lastVoiceId;
    int statusCode = 200;
    Map<String, dynamic>? body;

    setUp(() async {
      resolveHits = 0;
      lastFaceId = null;
      lastVoiceId = null;
      statusCode = 200;
      body = {
        'uid': 'zlatko',
        'displayName': 'Zlatko',
        'groups': ['comstar-users'],
        'dn': 'uid=zlatko,cn=users,cn=accounts,dc=example,dc=com',
        'faceId': 'face-z',
      };
      clock = FakeClock(1000);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = Uri.parse('http://127.0.0.1:${server.port}');
      server.listen((req) async {
        if (req.uri.path == '/v1/resolve') {
          resolveHits++;
          lastFaceId = req.uri.queryParameters['face_id'];
          lastVoiceId = req.uri.queryParameters['voice_id'];
          req.response.statusCode = statusCode;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(body ?? {}));
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('disabled passes through faceId as uid', () async {
      final resolver = DirectoryResolver(
        config: _dir(enabled: false),
        clock: clock,
      );
      final result = await resolver.resolveByFaceId('zlatko');
      expect(result, isA<DirectoryResolved>());
      final profile = (result as DirectoryResolved).profile;
      expect(profile.uid, 'zlatko');
      expect(profile.displayName, 'zlatko');
      expect(resolveHits, 0);
    });

    test('maps faceId to uid and displayName', () async {
      final resolver = DirectoryResolver(
        config: _dir(sidecarUrl: base.toString()),
        clock: clock,
      );
      final result = await resolver.resolveByFaceId('face-z');
      expect(lastFaceId, 'face-z');
      expect(result, isA<DirectoryResolved>());
      final profile = (result as DirectoryResolved).profile;
      expect(profile.uid, 'zlatko');
      expect(profile.displayName, 'Zlatko');
      expect(profile.groups, ['comstar-users']);
    });

    test('caches hit avoids second LDAP call', () async {
      final resolver = DirectoryResolver(
        config: _dir(sidecarUrl: base.toString(), cacheTtlSeconds: 600),
        clock: clock,
      );
      await resolver.resolveByFaceId('face-z');
      await resolver.resolveByFaceId('face-z');
      expect(resolveHits, 1);
      clock.advance(601000);
      await resolver.resolveByFaceId('face-z');
      expect(resolveHits, 2);
    });

    test('404 is DirectoryMiss', () async {
      statusCode = 404;
      body = {'error': 'not_found'};
      final resolver = DirectoryResolver(
        config: _dir(sidecarUrl: base.toString()),
        clock: clock,
      );
      final result = await resolver.resolveByFaceId('stranger');
      expect(result, isA<DirectoryMiss>());
    });

    test('5xx is DirectoryError', () async {
      statusCode = 503;
      body = {'error': 'ldap_unavailable'};
      final resolver = DirectoryResolver(
        config: _dir(sidecarUrl: base.toString()),
        clock: clock,
      );
      final result = await resolver.resolveByFaceId('face-z');
      expect(result, isA<DirectoryError>());
    });

    test('faceId≠uid mapping preserved', () async {
      body = {
        'uid': 'alice',
        'displayName': 'Alice',
        'groups': <String>[],
        'faceId': 'cpai-alice-1',
      };
      final resolver = DirectoryResolver(
        config: _dir(sidecarUrl: base.toString()),
        clock: clock,
      );
      final result = await resolver.resolveByFaceId('cpai-alice-1');
      final profile = (result as DirectoryResolved).profile;
      expect(profile.uid, 'alice');
      expect(profile.faceId, 'cpai-alice-1');
    });

    test('resolveByVoiceId uses voice_id query', () async {
      body = {
        'uid': 'zlatko',
        'displayName': 'Zlatko',
        'voiceId': 'voice-z',
        'haPerson': 'person.zlatko_lakisic',
      };
      final resolver = DirectoryResolver(
        config: _dir(sidecarUrl: base.toString()),
        clock: clock,
      );
      final result = await resolver.resolveByVoiceId('voice-z');
      expect(lastVoiceId, 'voice-z');
      expect(lastFaceId, isNull);
      final profile = (result as DirectoryResolved).profile;
      expect(profile.uid, 'zlatko');
      expect(profile.voiceId, 'voice-z');
      expect(profile.haPerson, 'person.zlatko_lakisic');
    });
  });
}
