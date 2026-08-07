import 'dart:convert';
import 'dart:io';

import 'package:comstar_bridge/log.dart';
import 'package:http/http.dart' as http;

/// Thin HTTP client for Ada `comstar-vision` MCP (`who_visited`, …).
///
/// Env: `COMSTAR_VISION_MCP_URL` (e.g. `http://10.0.10.16:8793/mcp`).
/// Raw IPs are fine here — AO tool-name rules do not apply to this client.
class VisionMcpClient {
  VisionMcpClient({
    http.Client? httpClient,
    this.baseUrlOverride,
  }) : _http = httpClient ?? http.Client();

  final http.Client _http;
  final String? baseUrlOverride;

  static String? get configuredUrl {
    final u = Platform.environment['COMSTAR_VISION_MCP_URL']?.trim() ?? '';
    return u.isEmpty ? null : u;
  }

  static bool get isConfigured => configuredUrl != null;

  String? get _url => baseUrlOverride ?? configuredUrl;

  bool get isReady => _url != null && _url!.isNotEmpty;

  void close() => _http.close();

  /// Call MCP `who_visited`. Returns `spoken_hint` when ok.
  Future<String?> whoVisitedSpoken({
    required String camera,
    required String since,
    int maxUnknown = 3,
    Duration timeout = const Duration(seconds: 75),
  }) async {
    final payload = await _callTool(
      'who_visited',
      {
        'camera': camera,
        'since': since,
        'max_unknown': maxUnknown,
      },
      timeout: timeout,
      logCtx: {'camera': camera, 'since': since},
    );
    if (payload == null) return null;
    final hint = payload['spoken_hint']?.toString().trim() ?? '';
    return hint.isEmpty ? null : hint;
  }

  /// Call MCP `person_last_seen` for a named Frigate face.
  Future<String?> personLastSeenSpoken({
    required String name,
    String since = '30d',
    String? camera,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final args = <String, dynamic>{
      'name': name,
      'since': since,
    };
    if (camera != null && camera.isNotEmpty) {
      args['camera'] = camera;
    }
    final payload = await _callTool(
      'person_last_seen',
      args,
      timeout: timeout,
      logCtx: {'name': name, 'since': since, 'camera': camera},
    );
    if (payload == null) return null;
    final hint = payload['spoken_hint']?.toString().trim() ?? '';
    return hint.isEmpty ? null : hint;
  }

  Future<Map<String, dynamic>?> _callTool(
    String tool,
    Map<String, dynamic> arguments, {
    required Duration timeout,
    Map<String, Object?>? logCtx,
  }) async {
    final base = _url;
    if (base == null || base.isEmpty) return null;
    final uri = Uri.parse(base);
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {
        'name': tool,
        'arguments': arguments,
      },
    });
    try {
      final resp = await _http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json, text/event-stream',
            },
            body: body,
          )
          .timeout(timeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        logWarn('vision_mcp_http', '$tool status', data: {
          'status': resp.statusCode,
          ...?logCtx,
          'body': resp.body.length > 200
              ? '${resp.body.substring(0, 200)}…'
              : resp.body,
        });
        return null;
      }
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map) return null;
      final result = decoded['result'];
      if (result is! Map) return null;
      final content = result['content'];
      if (content is! List || content.isEmpty) return null;
      final first = content.first;
      if (first is! Map) return null;
      final text = first['text']?.toString() ?? '';
      if (text.isEmpty) return null;
      final payload = jsonDecode(text);
      if (payload is! Map) return null;
      if (payload['ok'] == false) {
        logWarn('vision_mcp_tool', payload['error']?.toString() ?? 'not ok',
            data: logCtx);
        return null;
      }
      return Map<String, dynamic>.from(payload);
    } catch (e) {
      logWarn('vision_mcp_http', e.toString(), data: {
        'tool': tool,
        ...?logCtx,
      });
      return null;
    }
  }
}
