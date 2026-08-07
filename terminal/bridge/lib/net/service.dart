/// Host network inspect + Wi‑Fi / IPv4 mutations (ADR 0012).
library;

import 'package:comstar_bridge/log.dart';
import 'package:comstar_bridge/net/ipv4.dart';
import 'package:comstar_bridge/net/nmcli.dart';

class NetworkService {
  NetworkService({NmcliRunner? nmcli}) : _nm = nmcli ?? NmcliRunner();

  final NmcliRunner _nm;
  String? lastError;

  Future<Map<String, Object?>> inspect({bool scan = false}) async {
    final nmOk = await _nm.available();
    if (!nmOk) {
      lastError = 'nmcli_unavailable';
      return {
        'ok': false,
        'wifi_radio': null,
        'nmcli_ok': false,
        'devices': <Object>[],
        'wifi_networks': <Object>[],
        'saved_wifi': <Object>[],
        'last_error': lastError,
      };
    }

    if (scan) {
      await _nm.run(['device', 'wifi', 'rescan']);
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }

    final radio = await _wifiRadioOn();
    final devices = await _listDevices();
    final nets = await _wifiList();
    final saved = await _savedWifi();
    lastError = null;
    return {
      'ok': true,
      'wifi_radio': radio,
      'nmcli_ok': true,
      'devices': devices,
      'wifi_networks': nets,
      'saved_wifi': saved,
      'last_error': null,
    };
  }

  Future<Map<String, Object?>> handleAction(Map<String, dynamic> body) async {
    final action = (body['action'] ?? '').toString().trim();
    switch (action) {
      case 'wifi_radio':
        return _wifiRadioSet(body['enabled'] == true);
      case 'wifi_scan':
        return {...await inspect(scan: true), 'action': action};
      case 'wifi_connect':
        return _wifiConnect(body);
      case 'wifi_disconnect':
        return _wifiDisconnect(body['device']?.toString());
      case 'wifi_forget':
        return _wifiForget(
          ssid: body['ssid']?.toString(),
          connection: body['connection']?.toString(),
        );
      case 'ipv4_set':
        return _ipv4Set(body);
      default:
        throw ArgumentError(
          'invalid_action (wifi_radio|wifi_scan|wifi_connect|'
          'wifi_disconnect|wifi_forget|ipv4_set)',
        );
    }
  }

  Future<bool?> _wifiRadioOn() async {
    final r = await _nm.run(['-t', 'radio', 'wifi']);
    if (!r.ok) return null;
    final v = r.stdout.trim().toLowerCase();
    return v == 'enabled' || v == 'on';
  }

  Future<Map<String, Object?>> _wifiRadioSet(bool enabled) async {
    final r = await _nm.run(['radio', 'wifi', enabled ? 'on' : 'off']);
    if (!r.ok) {
      lastError = r.stderr.trim().isNotEmpty ? r.stderr.trim() : r.stdout.trim();
      throw StateError(lastError ?? 'wifi_radio_failed');
    }
    logInfo('net_wifi_radio', 'Wi‑Fi radio toggled', data: {'enabled': enabled});
    return {
      'ok': true,
      'action': 'wifi_radio',
      'enabled': enabled,
      ...await inspect(),
    };
  }

  Future<List<Map<String, Object?>>> _listDevices() async {
    final r = await _nm.run([
      '-t',
      '-f',
      'DEVICE,TYPE,STATE,CONNECTION',
      'device',
      'status',
    ]);
    if (!r.ok) return const [];
    final out = <Map<String, Object?>>[];
    for (final line in r.stdout.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final parts = t.split(':');
      if (parts.length < 3) continue;
      final device = parts[0];
      final type = parts[1];
      if (type != 'ethernet' && type != 'wifi') continue;
      final state = parts[2];
      final conn = parts.length > 3 && parts[3].isNotEmpty && parts[3] != '--'
          ? parts[3]
          : null;
      final detail = await _deviceDetail(device, type: type, connection: conn);
      out.add({
        'device': device,
        'type': type,
        'state': state,
        'connection': conn,
        ...detail,
      });
    }
    return out;
  }

  Future<Map<String, Object?>> _deviceDetail(
    String device, {
    required String type,
    String? connection,
  }) async {
    final show = await _nm.run(['-t', 'device', 'show', device]);
    String? mac;
    String? ssid;
    int? signal;
    if (show.ok) {
      for (final line in show.stdout.split('\n')) {
        final i = line.indexOf(':');
        if (i <= 0) continue;
        final k = line.substring(0, i);
        final v = line.substring(i + 1);
        if (k == 'GENERAL.HWADDR') mac = v;
        if (k == 'GENERAL.CONNECTION' && (connection == null || connection.isEmpty)) {
          if (v.isNotEmpty && v != '--') connection = v;
        }
        if (k == 'GENERAL.STATE') {
          // ignore — already have state
        }
      }
    }

    Map<String, Object?> ipv4 = {
      'method': 'auto',
      'addresses': <String>[],
      'gateway': null,
      'dns': <String>[],
    };
    if (connection != null && connection.isNotEmpty) {
      ipv4 = await _connectionIpv4(connection);
      // Live addresses from device show (may differ briefly from profile).
      final live = <String>[];
      String? gw;
      final dns = <String>[];
      if (show.ok) {
        for (final line in show.stdout.split('\n')) {
          final i = line.indexOf(':');
          if (i <= 0) continue;
          final k = line.substring(0, i);
          final v = line.substring(i + 1);
          if (k.startsWith('IP4.ADDRESS[')) {
            live.add(v.split(RegExp(r'\s+')).first);
          } else if (k == 'IP4.GATEWAY') {
            gw = v.isEmpty ? null : v;
          } else if (k.startsWith('IP4.DNS[')) {
            dns.add(v);
          }
        }
      }
      if (live.isNotEmpty) {
        ipv4 = {
          ...ipv4,
          'addresses': live,
          if (gw != null) 'gateway': gw,
          if (dns.isNotEmpty) 'dns': dns,
        };
      }
    }

    Map<String, Object?>? wifi;
    if (type == 'wifi') {
      final w = await _nm.run([
        '-t',
        '-f',
        'ACTIVE,SSID,SIGNAL',
        'device',
        'wifi',
        'list',
        'ifname',
        device,
      ]);
      if (w.ok) {
        for (final line in w.stdout.split('\n')) {
          final parts = line.split(':');
          if (parts.length < 2) continue;
          if (parts[0] == '*' || parts[0] == 'yes') {
            ssid = parts[1];
            signal = parts.length > 2 ? int.tryParse(parts[2]) : null;
            break;
          }
        }
      }
      wifi = {'ssid': ssid, 'signal': signal};
    }

    return {
      'mac': mac,
      'ipv4': ipv4,
      'wifi': wifi,
    };
  }

  Future<Map<String, Object?>> _connectionIpv4(String connection) async {
    final r = await _nm.run([
      '-t',
      '-f',
      'ipv4.method,ipv4.addresses,ipv4.gateway,ipv4.dns',
      'connection',
      'show',
      'id',
      connection,
    ]);
    var method = 'other';
    final addresses = <String>[];
    String? gateway;
    final dns = <String>[];
    if (r.ok) {
      // -t with multiple fields: one line with colon-separated values, OR
      // key:value per line depending on nmcli version. Handle both.
      final lines = r.stdout.trim().split('\n');
      if (lines.length == 1 && !lines.first.contains('ipv4.')) {
        final parts = lines.first.split(':');
        if (parts.isNotEmpty) method = _normMethod(parts[0]);
        if (parts.length > 1 && parts[1].isNotEmpty) {
          addresses.addAll(parts[1].split(RegExp(r'[,|]')).map((e) => e.trim()));
        }
        if (parts.length > 2 && parts[2].isNotEmpty) gateway = parts[2];
        if (parts.length > 3 && parts[3].isNotEmpty) {
          dns.addAll(parts[3].split(RegExp(r'[,|\s]+')).where((e) => e.isNotEmpty));
        }
      } else {
        for (final line in lines) {
          final i = line.indexOf(':');
          if (i <= 0) continue;
          final k = line.substring(0, i).toLowerCase();
          final v = line.substring(i + 1);
          if (k == 'ipv4.method') method = _normMethod(v);
          if (k == 'ipv4.addresses' && v.isNotEmpty) {
            addresses.addAll(v.split(RegExp(r'[,|]')).map((e) => e.trim()));
          }
          if (k == 'ipv4.gateway' && v.isNotEmpty) gateway = v;
          if (k == 'ipv4.dns' && v.isNotEmpty) {
            dns.addAll(v.split(RegExp(r'[,|\s]+')).where((e) => e.isNotEmpty));
          }
        }
      }
    }
    return {
      'method': method,
      'addresses': addresses.where((e) => e.isNotEmpty).toList(),
      'gateway': gateway,
      'dns': dns,
    };
  }

  String _normMethod(String raw) {
    final m = raw.trim().toLowerCase();
    if (m == 'auto' || m == 'manual') return m;
    return 'other';
  }

  Future<List<Map<String, Object?>>> _wifiList() async {
    final r = await _nm.run([
      '-t',
      '-f',
      'IN-USE,SSID,SIGNAL,SECURITY',
      'device',
      'wifi',
      'list',
    ]);
    if (!r.ok) return const [];
    final seen = <String>{};
    final out = <Map<String, Object?>>[];
    for (final line in r.stdout.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final parts = t.split(':');
      if (parts.length < 2) continue;
      final inUse = parts[0] == '*' || parts[0] == 'yes';
      final ssid = parts[1];
      if (ssid.isEmpty) continue;
      if (!seen.add(ssid)) continue;
      out.add({
        'ssid': ssid,
        'signal': parts.length > 2 ? int.tryParse(parts[2]) : null,
        'security': parts.length > 3 ? parts.sublist(3).join(':') : '',
        'in_use': inUse,
      });
    }
    out.sort((a, b) {
      final sa = a['signal'] as int? ?? 0;
      final sb = b['signal'] as int? ?? 0;
      return sb.compareTo(sa);
    });
    return out;
  }

  Future<List<String>> _savedWifi() async {
    final r = await _nm.run([
      '-t',
      '-f',
      'NAME,TYPE',
      'connection',
      'show',
    ]);
    if (!r.ok) return const [];
    final out = <String>[];
    for (final line in r.stdout.split('\n')) {
      final parts = line.split(':');
      if (parts.length < 2) continue;
      if (parts[1] == '802-11-wireless' || parts[1] == 'wifi') {
        out.add(parts[0]);
      }
    }
    out.sort();
    return out;
  }

  Future<Map<String, Object?>> _wifiConnect(Map<String, dynamic> body) async {
    final ssid = (body['ssid'] ?? '').toString().trim();
    if (ssid.isEmpty) throw ArgumentError('ssid required');
    final password = body['password']?.toString();
    final hidden = body['hidden'] == true;

    logInfo('net_wifi_connect', 'Connecting Wi‑Fi', data: {
      'ssid': ssid,
      'has_password': password != null && password.isNotEmpty,
      'hidden': hidden,
    });

    final args = <String>['device', 'wifi', 'connect', ssid];
    if (password != null && password.isNotEmpty) {
      args.addAll(['password', password]);
    }
    if (hidden) args.addAll(['hidden', 'yes']);
    final r = await _nm.run(args);
    if (!r.ok) {
      // Try bringing up a saved connection by name (SSID often == connection id).
      final up = await _nm.run(['connection', 'up', 'id', ssid]);
      if (!up.ok) {
        lastError = (r.stderr.trim().isNotEmpty ? r.stderr : r.stdout).trim();
        throw StateError(lastError ?? 'wifi_connect_failed');
      }
    }
    lastError = null;
    return {
      'ok': true,
      'action': 'wifi_connect',
      'ssid': ssid,
      ...await inspect(),
    };
  }

  Future<Map<String, Object?>> _wifiDisconnect(String? device) async {
    var dev = device?.trim() ?? '';
    if (dev.isEmpty) {
      final devices = await _listDevices();
      final wifi = devices.cast<Map<String, Object?>>().where(
            (d) => d['type'] == 'wifi',
          );
      if (wifi.isEmpty) throw StateError('no_wifi_device');
      dev = wifi.first['device']!.toString();
    }
    final r = await _nm.run(['device', 'disconnect', dev]);
    if (!r.ok) {
      lastError = (r.stderr.trim().isNotEmpty ? r.stderr : r.stdout).trim();
      throw StateError(lastError ?? 'wifi_disconnect_failed');
    }
    logInfo('net_wifi_disconnect', 'Wi‑Fi disconnected', data: {'device': dev});
    return {
      'ok': true,
      'action': 'wifi_disconnect',
      'device': dev,
      ...await inspect(),
    };
  }

  Future<Map<String, Object?>> _wifiForget({
    String? ssid,
    String? connection,
  }) async {
    final name = (connection ?? ssid ?? '').trim();
    if (name.isEmpty) throw ArgumentError('ssid or connection required');
    final r = await _nm.run(['connection', 'delete', 'id', name]);
    if (!r.ok) {
      lastError = (r.stderr.trim().isNotEmpty ? r.stderr : r.stdout).trim();
      throw StateError(lastError ?? 'wifi_forget_failed');
    }
    logInfo('net_wifi_forget', 'Forgot Wi‑Fi connection', data: {'connection': name});
    return {
      'ok': true,
      'action': 'wifi_forget',
      'connection': name,
      ...await inspect(),
    };
  }

  Future<Map<String, Object?>> _ipv4Set(Map<String, dynamic> body) async {
    final device = (body['device'] ?? '').toString().trim();
    if (device.isEmpty) throw ArgumentError('device required');
    final method = (body['method'] ?? '').toString().trim().toLowerCase();
    if (method != 'auto' && method != 'manual') {
      throw ArgumentError('method must be auto or manual');
    }

    final devices = await _listDevices();
    final match = devices.cast<Map<String, Object?>>().where(
          (d) => d['device'] == device,
        );
    if (match.isEmpty) throw ArgumentError('unknown_device');
    var connection = match.first['connection']?.toString();
    if (connection == null || connection.isEmpty) {
      // Ensure a connection exists for the device.
      final up = await _nm.run(['device', 'connect', device]);
      if (!up.ok) {
        throw StateError('no_connection_for_device');
      }
      final again = await _listDevices();
      connection = again
          .cast<Map<String, Object?>>()
          .where((d) => d['device'] == device)
          .map((d) => d['connection']?.toString())
          .firstWhere((c) => c != null && c.isNotEmpty, orElse: () => null);
      if (connection == null || connection.isEmpty) {
        throw StateError('no_connection_for_device');
      }
    }

    if (method == 'auto') {
      final r = await _nm.run([
        'connection',
        'modify',
        'id',
        connection,
        'ipv4.method',
        'auto',
        'ipv4.addresses',
        '',
        'ipv4.gateway',
        '',
        'ipv4.dns',
        '',
      ]);
      if (!r.ok) {
        throw StateError((r.stderr.trim().isNotEmpty ? r.stderr : r.stdout).trim());
      }
    } else {
      final address = (body['address'] ?? '').toString().trim();
      final prefixRaw = body['prefix'];
      final prefix = prefixRaw is int
          ? prefixRaw
          : int.tryParse(prefixRaw?.toString() ?? '') ?? 0;
      final gateway = body['gateway']?.toString().trim();
      final dnsRaw = body['dns'];
      final dns = <String>[];
      if (dnsRaw is List) {
        for (final e in dnsRaw) {
          final s = e.toString().trim();
          if (s.isNotEmpty) dns.add(s);
        }
      } else if (dnsRaw != null) {
        dns.addAll(
          dnsRaw
              .toString()
              .split(RegExp(r'[,;\s]+'))
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty),
        );
      }
      final err = validateManualIpv4(
        address: address,
        prefix: prefix,
        gateway: gateway,
        dns: dns,
      );
      if (err != null) throw ArgumentError(err);

      final mods = <String>[
        'connection',
        'modify',
        'id',
        connection,
        'ipv4.method',
        'manual',
        'ipv4.addresses',
        '$address/$prefix',
      ];
      if (gateway != null && gateway.isNotEmpty) {
        mods.addAll(['ipv4.gateway', gateway]);
      } else {
        mods.addAll(['ipv4.gateway', '']);
      }
      mods.addAll(['ipv4.dns', dns.join(',')]);
      final r = await _nm.run(mods);
      if (!r.ok) {
        throw StateError((r.stderr.trim().isNotEmpty ? r.stderr : r.stdout).trim());
      }
    }

    final up = await _nm.run(['connection', 'up', 'id', connection]);
    if (!up.ok) {
      lastError = (up.stderr.trim().isNotEmpty ? up.stderr : up.stdout).trim();
      throw StateError(lastError ?? 'connection_up_failed');
    }
    logInfo('net_ipv4_set', 'IPv4 updated', data: {
      'device': device,
      'connection': connection,
      'method': method,
    });
    lastError = null;
    return {
      'ok': true,
      'action': 'ipv4_set',
      'device': device,
      'connection': connection,
      'method': method,
      ...await inspect(),
    };
  }
}
