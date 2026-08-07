import 'dart:convert';

import 'package:comstar_bridge/vision_mcp_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('whoVisitedSpoken parses spoken_hint', () async {
    final client = VisionMcpClient(
      baseUrlOverride: 'http://vision.test/mcp',
      httpClient: MockClient((req) async {
        expect(req.url.toString(), 'http://vision.test/mcp');
        final body = jsonDecode(req.body) as Map;
        expect(body['params']['name'], 'who_visited');
        expect(body['params']['arguments']['camera'], 'driveway');
        expect(body['params']['arguments']['since'], 'yesterday');
        final payload = {
          'ok': true,
          'spoken_hint': 'Recognized: Zlatko (5:13 PM).',
          'visit_count': 1,
        };
        return http.Response(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'result': {
              'content': [
                {'type': 'text', 'text': jsonEncode(payload)},
              ],
            },
          }),
          200,
        );
      }),
    );
    final spoken = await client.whoVisitedSpoken(
      camera: 'driveway',
      since: 'yesterday',
    );
    expect(spoken, 'Recognized: Zlatko (5:13 PM).');
    client.close();
  });

  test('whoVisitedSpoken returns null on tool error', () async {
    final client = VisionMcpClient(
      baseUrlOverride: 'http://vision.test/mcp',
      httpClient: MockClient((req) async {
        final payload = {'ok': false, 'error': 'frigate_down'};
        return http.Response(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'result': {
              'content': [
                {'type': 'text', 'text': jsonEncode(payload)},
              ],
            },
          }),
          200,
        );
      }),
    );
    expect(
      await client.whoVisitedSpoken(camera: 'driveway', since: 'today'),
      isNull,
    );
    client.close();
  });
}
