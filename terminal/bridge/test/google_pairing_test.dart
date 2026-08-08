import 'dart:io';

import 'package:comstar_bridge/google/device_pairing.dart';
import 'package:comstar_bridge/google/mcp_yaml.dart';
import 'package:comstar_bridge/google/qr_svg.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('loadOverlayMcpProviders', () {
    test('loads google_workspace from overlay', () {
      final root = Directory.current.path.contains('terminal/bridge')
          ? '${Directory.current.path}/../../overlays/comstar'
          : '${Directory.current.path}/overlays/comstar';
      final defs = loadOverlayMcpProviders(root);
      expect(defs, isNotEmpty);
      final gw = defs.firstWhere((d) => d.id == 'google_workspace');
      expect(gw.alias, 'google_workspace');
      expect(gw.clientId, 'client.google_workspace');
      expect(gw.npxPackage, contains('mcp-server-google-workspace@'));
      expect(gw.command, isEmpty);
      expect(gw.requiresTokens, isTrue);
      expect(gw.guestAllowed, isFalse);
      expect(gw.envFrom, contains('GOOGLE_REFRESH_TOKEN'));

      final nc = defs.firstWhere((d) => d.id == 'nextcloud');
      expect(nc.clientId, 'client.nextcloud');
      expect(nc.usesCommand, isTrue);
      expect(nc.command.first, 'uvx');
      expect(nc.envFrom, contains('NEXTCLOUD_PASSWORD'));
      expect(nc.guestAllowed, isFalse);
    });
  });

  group('qrSvg', () {
    test('emits svg with modules', () {
      final svg = qrSvg('https://www.google.com/device?user_code=ABCD-EFGH');
      expect(svg, startsWith('<svg'));
      expect(svg, contains('<rect'));
      expect(svg, endsWith('</svg>'));
    });
  });

  group('GoogleDevicePairing', () {
    test('speakableUserCode', () {
      expect(
        GoogleDevicePairing.speakableUserCode('ABCD-EFGH'),
        'A B C D dash E F G H',
      );
    });

    test('begin parses device code response', () async {
      final client = MockClient((req) async {
        expect(req.url.host, 'oauth2.googleapis.com');
        expect(req.url.path, '/device/code');
        return http.Response(
          '{"device_code":"dc","user_code":"AB-CD",'
          '"verification_uri":"https://www.google.com/device",'
          '"verification_uri_complete":"https://www.google.com/device?user_code=AB-CD",'
          '"expires_in":600,"interval":1}',
          200,
        );
      });
      final pairing = GoogleDevicePairing(
        httpClient: client,
        clientId: 'cid',
        clientSecret: 'sec',
      );
      final code = await pairing.begin();
      expect(code.userCode, 'AB-CD');
      expect(code.deviceCode, 'dc');
      expect(code.verificationUrlComplete, contains('AB-CD'));
    });

    test('waitForApproval returns tokens', () async {
      var polls = 0;
      final client = MockClient((req) async {
        if (req.url.path.contains('device/code')) {
          return http.Response(
            '{"device_code":"dc","user_code":"AB",'
            '"verification_uri":"https://www.google.com/device",'
            '"expires_in":30,"interval":0}',
            200,
          );
        }
        polls++;
        if (polls < 2) {
          return http.Response('{"error":"authorization_pending"}', 400);
        }
        return http.Response(
          '{"access_token":"at","refresh_token":"rt","token_type":"Bearer"}',
          200,
        );
      });
      final pairing = GoogleDevicePairing(
        httpClient: client,
        clientId: 'cid',
        clientSecret: 'sec',
      );
      final code = await pairing.begin();
      final result = await pairing.waitForApproval(
        GoogleDeviceCode(
          deviceCode: code.deviceCode,
          userCode: code.userCode,
          verificationUrl: code.verificationUrl,
          verificationUrlComplete: code.verificationUrlComplete,
          expiresIn: 30,
          intervalSeconds: 0,
        ),
      );
      expect(result.outcome, GooglePairingOutcome.success);
      expect(result.tokens!.refreshToken, 'rt');
    });
  });
}
