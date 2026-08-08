import 'dart:convert';

import 'package:comstar_bridge/nextcloud/login_flow.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('NextcloudLoginFlow', () {
    test('begin parses login/v2', () async {
      final client = MockClient((req) async {
        expect(req.url.path, '/index.php/login/v2');
        return http.Response(
          jsonEncode({
            'login': 'https://cloud.example/login/v2/flow/abc',
            'poll': {
              'token': 'tok',
              'endpoint': 'https://cloud.example/login/v2/poll',
            },
          }),
          200,
        );
      });
      final flow = NextcloudLoginFlow(
        httpClient: client,
        host: 'https://cloud.example',
      );
      final session = await flow.begin();
      expect(session.loginUrl, contains('/login/v2/flow/'));
      expect(session.pollToken, 'tok');
    });

    test('waitForApproval returns credentials', () async {
      var polls = 0;
      final client = MockClient((req) async {
        if (req.url.path.contains('login/v2') &&
            !req.url.path.contains('poll')) {
          return http.Response(
            jsonEncode({
              'login': 'https://cloud.example/login',
              'poll': {
                'token': 'tok',
                'endpoint': 'https://cloud.example/login/v2/poll',
              },
            }),
            200,
          );
        }
        polls++;
        if (polls < 2) {
          return http.Response('Not found', 404);
        }
        return http.Response(
          jsonEncode({
            'server': 'https://cloud.example',
            'loginName': 'zlatko',
            'appPassword': 'app-pw',
          }),
          200,
        );
      });
      final flow = NextcloudLoginFlow(
        httpClient: client,
        host: 'https://cloud.example',
      );
      final session = await flow.begin();
      final result = await flow.waitForApproval(
        session,
        pollInterval: Duration.zero,
      );
      expect(result.outcome, NextcloudPairingOutcome.success);
      expect(result.loginName, 'zlatko');
      expect(result.appPassword, 'app-pw');
    });
  });
}
