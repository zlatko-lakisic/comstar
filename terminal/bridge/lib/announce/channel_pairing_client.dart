/// HTTP client: bridge → Ada channel pairing API (ADR 0015).
library;

import 'dart:convert';

import 'package:comstar_bridge/log.dart';
import 'package:http/http.dart' as http;

class ChannelPairingBegin {
  const ChannelPairingBegin({
    required this.id,
    required this.url,
    required this.userCode,
    required this.provider,
    required this.expiresAt,
  });

  final String id;
  final String url;
  final String userCode;
  final String provider;
  final DateTime? expiresAt;

  factory ChannelPairingBegin.fromJson(Map<String, dynamic> json) {
    return ChannelPairingBegin(
      id: '${json['id'] ?? ''}',
      url: '${json['url'] ?? ''}',
      userCode: '${json['user_code'] ?? json['userCode'] ?? ''}',
      provider: '${json['provider'] ?? ''}',
      expiresAt: DateTime.tryParse('${json['expires_at'] ?? ''}'),
    );
  }
}

class ChannelPairingClient {
  ChannelPairingClient({
    required this.baseUrl,
    this.token = '',
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String baseUrl;
  final String token;
  final http.Client _http;

  bool get enabled => baseUrl.trim().isNotEmpty;

  String get _root => baseUrl.replaceAll(RegExp(r'/+$'), '');

  Map<String, String> get _headers {
    final h = <String, String>{'content-type': 'application/json'};
    if (token.isNotEmpty) {
      h['x-comstar-channel-token'] = token;
    }
    return h;
  }

  Future<Map<String, dynamic>?> _post(
    String path,
    Map<String, Object?> body,
  ) async {
    if (!enabled) return null;
    try {
      final res = await _http
          .post(
            Uri.parse('$_root$path'),
            headers: _headers,
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        logWarn('channel_pairing_http', 'Pairing POST failed', data: {
          'path': path,
          'status': res.statusCode,
          'body': res.body.length > 200 ? res.body.substring(0, 200) : res.body,
        });
        try {
          final decoded = jsonDecode(res.body);
          if (decoded is Map) {
            return Map<String, dynamic>.from(decoded);
          }
        } catch (_) {}
        return {'ok': false, 'error': 'http_${res.statusCode}'};
      }
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (e) {
      logWarn('channel_pairing_error', e.toString(), data: {'path': path});
      return null;
    }
  }

  Future<Map<String, dynamic>?> _get(String path) async {
    if (!enabled) return null;
    try {
      final res = await _http
          .get(Uri.parse('$_root$path'), headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (e) {
      logWarn('channel_pairing_error', e.toString(), data: {'path': path});
      return null;
    }
  }

  Future<ChannelPairingBegin?> begin({
    required String userid,
    required String provider,
  }) async {
    final body = await _post('/v1/pairing/begin', {
      'userid': userid,
      'provider': provider,
    });
    if (body == null || body['ok'] != true) {
      return null;
    }
    return ChannelPairingBegin.fromJson(body);
  }

  /// Last error code from a failed begin (for speech).
  Future<({ChannelPairingBegin? begin, String? error})> beginDetailed({
    required String userid,
    required String provider,
  }) async {
    final body = await _post('/v1/pairing/begin', {
      'userid': userid,
      'provider': provider,
    });
    if (body == null) {
      return (begin: null, error: 'unreachable');
    }
    if (body['ok'] == true) {
      return (begin: ChannelPairingBegin.fromJson(body), error: null);
    }
    return (begin: null, error: '${body['error'] ?? 'failed'}');
  }

  Future<String?> status(String id) async {
    final body = await _get('/v1/pairing/status?id=${Uri.encodeQueryComponent(id)}');
    if (body == null || body['ok'] != true) return null;
    return '${body['status'] ?? ''}';
  }

  Future<void> cancel(String id) async {
    await _post('/v1/pairing/cancel', {'id': id});
  }

  Future<bool> unlink({required String userid, String? provider}) async {
    final body = await _post('/v1/pairing/unlink', {
      'userid': userid,
      if (provider != null && provider.isNotEmpty) 'provider': provider,
    });
    return body?['removed'] == true;
  }

  Future<List<String>> linkedProviders(String userid) async {
    final body = await _get(
      '/v1/pairing/links?userid=${Uri.encodeQueryComponent(userid)}',
    );
    if (body == null || body['ok'] != true) return const [];
    final raw = body['providers'];
    if (raw is! List) return const [];
    return [for (final p in raw) '$p'];
  }
}
