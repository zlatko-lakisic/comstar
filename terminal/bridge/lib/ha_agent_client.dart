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

  /// Spoken irrigation summary from 7-day minute sensors + key zone histories.
  Future<String?> irrigationSpokenSummary() async {
    if (!isConfigured) return null;

    const zones = <(String id, String label)>[
      ('sensor.irrigation_7d_east_lawn_minutes', 'east lawn'),
      ('sensor.irrigation_7d_east_flower_bed_minutes', 'east flower bed'),
      ('sensor.irrigation_7d_front_yard_minutes', 'front yard'),
      ('sensor.irrigation_7d_back_lawn_minutes', 'back lawn'),
      ('sensor.irrigation_7d_slope_kitchen_left_minutes', 'kitchen slope'),
      ('sensor.irrigation_7d_peppers_kale_minutes', 'peppers and kale'),
      ('sensor.irrigation_7d_tomato_minutes', 'tomato'),
      ('sensor.irrigation_7d_zucchini_eggplant_minutes', 'zucchini and eggplant'),
    ];

    final minutes = <String, double>{};
    for (final z in zones) {
      final s = await entityState(z.$1);
      final raw = s?['state']?.toString();
      final n = double.tryParse(raw ?? '');
      if (n != null) minutes[z.$2] = n;
    }
    if (minutes.isEmpty) return null;

    final total = minutes.values.fold<double>(0, (a, b) => a + b);
    final watered = minutes.entries.where((e) => e.value > 0.05).toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final parts = <String>[];
    if (total < 0.05) {
      parts.add(
        'Over the last seven days, irrigation zones show zero minutes of watering',
      );
    } else {
      final shown = total >= 10 ? total.toStringAsFixed(0) : total.toStringAsFixed(1);
      parts.add(
        'Over the last seven days, zones logged about $shown minutes of irrigation total',
      );
      for (final e in watered.take(4)) {
        final m = e.value >= 10
            ? e.value.toStringAsFixed(0)
            : e.value.toStringAsFixed(1);
        parts.add('${e.key} $m minutes');
      }
    }

    final east = await entityState(
      'sensor.east_lawn_timer_east_lawn_zone_zone_history',
    );
    if (east != null) {
      final when = east['state']?.toString() ?? '';
      final attrs = east['attributes'];
      String? runMin;
      String? status;
      if (attrs is Map) {
        final rt = attrs['run_time'];
        if (rt is num) {
          runMin = rt >= 10 ? rt.toStringAsFixed(0) : rt.toStringAsFixed(1);
        }
        status = attrs['status']?.toString();
      }
      if (when.isNotEmpty) {
        final day = when.length >= 10 ? when.substring(0, 10) : when;
        final detail = [
          if (runMin != null) '$runMin minutes',
          if (status != null && status.isNotEmpty) status.replaceAll('_', ' '),
        ].join(', ');
        parts.add(
          detail.isEmpty
              ? 'east lawn last recorded run was $day'
              : 'east lawn last recorded run was $day ($detail)',
        );
      }
    }

    final rain = await entityState('switch.east_lawn_timer_rain_delay');
    if (rain?['state']?.toString() == 'on') {
      parts.add('east lawn rain delay is on');
    }

    if (parts.length == 1) return '${parts.first}.';
    if (parts.length == 2) return '${parts[0]}, and ${parts[1]}.';
    return '${parts.sublist(0, parts.length - 1).join(', ')}, and ${parts.last}.';
  }

  /// Spoken network summary (WAN/LAN IPs, speedtest, MikroTik rates/clients).
  ///
  /// [query] is normalized lowercase text from [parseHomeDataIntent] for sub-routing.
  Future<String?> networkSpokenSummary({String query = ''}) async {
    if (!isConfigured) return null;
    final q = query.toLowerCase();

    final wantMostar = RegExp(r'\bmostar\b').hasMatch(q);
    final wantPhone = RegExp(r'\b(phone|samsung|ibrica|cellular|mobile)\b')
        .hasMatch(q);
    final wantLocal = RegExp(
      r'\b(local|lan)\s*ip\b|\bhome assistant\b|\bha\b.*\bip\b',
    ).hasMatch(q);
    final wantSpeed = RegExp(
      r'\bspeed\s*test\b|\b(download|upload)\s+speed\b|\bping\b',
    ).hasMatch(q);
    final wantBandwidth = RegExp(
      r'\b(bandwidth|mikrotik|vlan|wireguard|interface|ether|wlan|sfp)\b|'
      r'\b(wired|wireless)\s+clients\b|\bwifi\s+clients\b',
    ).hasMatch(q);
    final wantWan = RegExp(r'\b(wan|public)\s*ip\b|\bip address\b|\b\bip\b')
            .hasMatch(q) &&
        !wantLocal &&
        !wantMostar &&
        !wantPhone;

    final parts = <String>[];

    Future<void> addLocalIp() async {
      final s = await entityState('sensor.local_ip');
      final ip = s?['state']?.toString() ?? '';
      if (ip.isNotEmpty && ip != 'unknown' && ip != 'unavailable') {
        parts.add('Home Assistant LAN IP is $ip');
      }
    }

    Future<void> addHomeWan() async {
      final s = await entityState('sensor.mikrotik_home_ether1_tx');
      String? wan;
      final attrs = s?['attributes'];
      if (attrs is Map) {
        final raw = attrs['client_ip_address']?.toString() ?? '';
        wan = raw.split('/').first.trim();
      }
      if (wan != null &&
          wan.isNotEmpty &&
          wan != 'none' &&
          wan != 'unknown') {
        parts.add('home WAN IP is $wan');
      }
    }

    Future<void> addMostarIp() async {
      final s =
          await entityState('sensor.mikrotik_mostar_environment_publicip');
      final ip = s?['state']?.toString() ?? '';
      if (ip.isNotEmpty && ip != 'unknown' && ip != 'unavailable') {
        parts.add('Mostar public IP is $ip');
      }
    }

    Future<void> addPhoneIp() async {
      final s = await entityState('sensor.ibrica_samsung_public_ip_address');
      final ip = s?['state']?.toString() ?? '';
      if (ip.isNotEmpty && ip != 'unknown' && ip != 'unavailable') {
        parts.add('phone public IP is $ip');
      }
    }

    Future<void> addSpeedtest() async {
      final down = await entityState('sensor.speedtest_download');
      final up = await entityState('sensor.speedtest_upload');
      final ping = await entityState('sensor.speedtest_ping');
      final d = down?['state']?.toString() ?? '';
      final u = up?['state']?.toString() ?? '';
      final p = ping?['state']?.toString() ?? '';
      final bits = <String>[];
      if (d.isNotEmpty && d != 'unknown') {
        bits.add('download about ${_fmtNum(d)} megabits per second');
      }
      if (u.isNotEmpty && u != 'unknown') {
        bits.add('upload about ${_fmtNum(u)} megabits per second');
      }
      if (p.isNotEmpty && p != 'unknown') {
        bits.add('ping about ${_fmtNum(p)} milliseconds');
      }
      if (bits.isNotEmpty) {
        parts.add('Speedtest shows ${bits.join(', ')}');
      }
    }

    Future<void> addMikrotik() async {
      final wired =
          await entityState('sensor.mikrotik_home_hap_ac_wired_clients');
      final wireless =
          await entityState('sensor.mikrotik_home_hap_ac_wireless_clients');
      final w = wired?['state']?.toString() ?? '';
      final wl = wireless?['state']?.toString() ?? '';
      if (w.isNotEmpty || wl.isNotEmpty) {
        final clientBits = <String>[];
        if (w.isNotEmpty) clientBits.add('$w wired');
        if (wl.isNotEmpty) clientBits.add('$wl wireless');
        parts.add('MikroTik home has ${clientBits.join(' and ')} clients');
      }

      const ifaces = <(String id, String label)>[
        ('sensor.mikrotik_home_ether1_tx', 'WAN transmit'),
        ('sensor.mikrotik_home_ether1_rx', 'WAN receive'),
        ('sensor.mikrotik_home_sfp1_tx', 'SFP transmit'),
        ('sensor.mikrotik_home_sfp1_rx', 'SFP receive'),
        ('sensor.mikrotik_home_home_wifi_vlan_tx', 'home Wi‑Fi VLAN transmit'),
        ('sensor.mikrotik_home_home_wifi_vlan_rx', 'home Wi‑Fi VLAN receive'),
        ('sensor.mikrotik_home_iot_vlan_tx', 'IoT VLAN transmit'),
        ('sensor.mikrotik_home_iot_vlan_rx', 'IoT VLAN receive'),
        ('sensor.mikrotik_home_wg_mostar_tx', 'WireGuard Mostar transmit'),
        ('sensor.mikrotik_home_wg_mostar_rx', 'WireGuard Mostar receive'),
      ];
      final rates = <String>[];
      for (final e in ifaces) {
        final s = await entityState(e.$1);
        final raw = s?['state']?.toString() ?? '';
        final n = double.tryParse(raw);
        if (n == null || n < 1) continue;
        rates.add('${e.$2} about ${_fmtNum(raw)} kilobytes per second');
        if (rates.length >= 4) break;
      }
      if (rates.isNotEmpty) {
        parts.add(rates.join(', '));
      }
    }

    // Sub-route: only fetch what was asked when specific; else a short overview.
    if (wantMostar) {
      await addMostarIp();
    } else if (wantPhone) {
      await addPhoneIp();
    } else if (wantLocal) {
      await addLocalIp();
    } else if (wantSpeed) {
      await addSpeedtest();
    } else if (wantBandwidth) {
      await addMikrotik();
    } else if (wantWan || q.contains('ip')) {
      await addHomeWan();
      if (parts.isEmpty) await addLocalIp();
    } else {
      await addHomeWan();
      await addLocalIp();
      await addSpeedtest();
    }

    if (parts.isEmpty) return null;
    if (parts.length == 1) return '${parts.first}.';
    if (parts.length == 2) return '${parts[0]}, and ${parts[1]}.';
    return '${parts.sublist(0, parts.length - 1).join(', ')}, and ${parts.last}.';
  }

  static String _fmtNum(String raw) {
    final n = double.tryParse(raw);
    if (n == null) return raw;
    if (n >= 100) return n.toStringAsFixed(0);
    if (n >= 10) return n.toStringAsFixed(1);
    return n.toStringAsFixed(2);
  }
}
