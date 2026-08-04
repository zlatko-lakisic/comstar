import 'dart:convert';
import 'dart:io';

import 'package:comstar_bridge/log.dart';
import 'package:http/http.dart' as http;

/// Thin client for HA Vibecode Agent HTTP API (same backend as Cursor HA MCP).
///
/// Env (first match wins):
/// - `COMSTAR_HA_AGENT_URL` / `COMSTAR_HA_AGENT_KEY`
/// - `HA_AGENT_URL` / `HA_AGENT_KEY`
class HaAgentClient {
  HaAgentClient({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final http.Client _http;

  static String? get configuredUrl {
    final u = Platform.environment['COMSTAR_HA_AGENT_URL']?.trim() ??
        Platform.environment['HA_AGENT_URL']?.trim() ??
        '';
    return u.isEmpty ? null : u.replaceAll(RegExp(r'/+$'), '');
  }

  static String? get configuredKey {
    final k = Platform.environment['COMSTAR_HA_AGENT_KEY']?.trim() ??
        Platform.environment['HA_AGENT_KEY']?.trim() ??
        '';
    return k.isEmpty ? null : k;
  }

  static bool get isConfigured =>
      configuredUrl != null && configuredKey != null;

  Future<Map<String, dynamic>?> entityState(String entityId) async {
    final base = configuredUrl;
    final key = configuredKey;
    if (base == null || key == null) return null;
    final uri = Uri.parse('$base/api/entities/state/$entityId');
    try {
      final resp = await _http
          .get(uri, headers: {'Authorization': 'Bearer $key'})
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) {
        logWarn('ha_agent_http', 'entity state failed', data: {
          'entity_id': entityId,
          'status': resp.statusCode,
        });
        return null;
      }
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      if (map['success'] == false) return null;
      final state = map['state'];
      if (state is Map) return Map<String, dynamic>.from(state);
      return map;
    } catch (e) {
      logWarn('ha_agent_http', e.toString(), data: {'entity_id': entityId});
      return null;
    }
  }

  /// Spoken summary of qBittorrent sensors in Home Assistant.
  Future<String?> torrentsSpokenSummary() async {
    if (!isConfigured) return null;

    const ids = <String>[
      'sensor.qbittorrent_status',
      'sensor.qbittorrent_active_torrents',
      'sensor.qbittorrent_all_torrents',
      'sensor.qbittorrent_paused_torrents',
      'sensor.qbittorrent_errored_torrents',
      'sensor.qbittorrent_download_speed',
      'sensor.qbittorrent_upload_speed',
    ];

    final states = <String, Map<String, dynamic>>{};
    for (final id in ids) {
      final s = await entityState(id);
      if (s != null) states[id] = s;
    }
    if (states.isEmpty) return null;

    String val(String id) => states[id]?['state']?.toString() ?? '';

    final status = val('sensor.qbittorrent_status');
    final active = val('sensor.qbittorrent_active_torrents');
    final all = val('sensor.qbittorrent_all_torrents');
    final paused = val('sensor.qbittorrent_paused_torrents');
    final errored = val('sensor.qbittorrent_errored_torrents');
    final down = val('sensor.qbittorrent_download_speed');
    final up = val('sensor.qbittorrent_upload_speed');

    final parts = <String>[];
    if (status.isNotEmpty) {
      parts.add('qBittorrent is ${status.replaceAll('_', ' ')}');
    }
    if (all.isNotEmpty) {
      parts.add('you have $all torrent${all == '1' ? '' : 's'} in the client');
    }
    if (active.isNotEmpty && active != '0') {
      parts.add('$active active');
    }
    if (paused.isNotEmpty && paused != '0') {
      parts.add('$paused paused');
    }
    if (errored.isNotEmpty && errored != '0') {
      parts.add('$errored errored');
    }

    String? rateLine(String raw, String label) {
      final n = double.tryParse(raw);
      if (n == null) return null;
      if (n <= 0.001) return null;
      final shown = n >= 10 ? n.toStringAsFixed(0) : n.toStringAsFixed(2);
      return '$label about $shown megabytes per second';
    }

    final downLine = rateLine(down, 'downloading at');
    final upLine = rateLine(up, 'uploading at');
    if (downLine != null) parts.add(downLine);
    if (upLine != null) parts.add(upLine);

    if (parts.isEmpty) {
      return "I checked Home Assistant, but qBittorrent did not return useful status.";
    }

    var spoken = parts.first;
    if (parts.length == 2) {
      spoken = '${parts[0]}, and ${parts[1]}.';
    } else if (parts.length > 2) {
      spoken =
          '${parts.sublist(0, parts.length - 1).join(', ')}, and ${parts.last}.';
    } else {
      spoken = '${parts.first}.';
    }
    return spoken;
  }
}
