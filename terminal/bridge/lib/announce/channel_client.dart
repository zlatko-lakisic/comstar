/// HTTP client: bridge → Ada `comstar-channel` announce ingress (M11.6).
library;

import 'dart:convert';

import 'package:comstar_bridge/log.dart';
import 'package:http/http.dart' as http;

class ChannelAnnounceClient {
  ChannelAnnounceClient({
    required this.baseUrl,
    this.token = '',
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  /// e.g. `http://10.0.10.16:8782` (no trailing slash).
  final String baseUrl;
  final String token;
  final http.Client _http;

  bool get enabled => baseUrl.trim().isNotEmpty;

  Uri get _announceUri => Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}/v1/announce');

  /// POST one announcement. Returns true only when channel reports delivered.
  Future<bool> deliver({
    required String id,
    required String recipient,
    required String text,
    required String priority,
    required bool presentAtTerminal,
    bool alreadyDelivered = false,
  }) async {
    if (!enabled) return false;
    final headers = <String, String>{
      'content-type': 'application/json',
    };
    if (token.isNotEmpty) {
      headers['x-comstar-channel-token'] = token;
    }
    try {
      final res = await _http
          .post(
            _announceUri,
            headers: headers,
            body: jsonEncode({
              'id': id,
              'recipient': recipient,
              'text': text,
              'priority': priority,
              'present_at_terminal': presentAtTerminal,
              'already_delivered': alreadyDelivered,
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 401) {
        logWarn('announce_channel_auth', 'Channel rejected token', data: {
          'status': res.statusCode,
        });
        return false;
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        logWarn('announce_channel_http', 'Channel announce HTTP error', data: {
          'status': res.statusCode,
          'body': res.body.length > 200 ? res.body.substring(0, 200) : res.body,
        });
        return false;
      }
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) return false;
      final delivered = decoded['delivered'] == true;
      if (!delivered) {
        logInfo('announce_channel_skip', 'Channel did not deliver', data: {
          'id': id,
          'reason': decoded['reason'],
        });
      }
      return delivered;
    } catch (e) {
      logWarn('announce_channel_error', e.toString(), data: {'id': id});
      return false;
    }
  }

  void close() => _http.close();
}
