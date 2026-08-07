/// Offline SoftAP when ethernet + Wi‑Fi client are both down (ADR 0014).
library;

import 'dart:async';
import 'dart:io';

import 'package:comstar_bridge/log.dart';
import 'package:comstar_bridge/net/nmcli.dart';
import 'package:comstar_bridge/net/service.dart';

class HotspotService {
  HotspotService({
    required this.network,
    NmcliRunner? nmcli,
    this.onChanged,
    this.interval = const Duration(seconds: 12),
    String? ssidOverride,
  })  : _nm = nmcli ?? NmcliRunner(),
        _ssidOverride = ssidOverride;

  /// NM connection id (not the broadcast SSID).
  static const connectionName = NetworkService.hotspotConnectionName;

  /// Gateway / Pi address on the shared subnet (DHCP via NM).
  static const gatewayIp = '10.87.65.1';
  static const cidr = '10.87.65.1/24';

  final NetworkService network;
  final NmcliRunner _nm;
  final void Function()? onChanged;
  final Duration interval;
  final String? _ssidOverride;

  Timer? _timer;
  bool _active = false;
  String? _ssid;
  String? _lastError;
  bool _busy = false;

  bool get active => _active;
  String? get ssid => _ssid;
  String? get ip => _active ? gatewayIp : null;
  String? get lastError => _lastError;

  bool get enabled => Platform.environment['COMSTAR_HOTSPOT'] != '0';

  String resolveSsid() {
    final override = _ssidOverride?.trim();
    if (override != null && override.isNotEmpty) {
      return override.length <= 32 ? override : override.substring(0, 32);
    }
    final host = Platform.localHostname
        .replaceAll(RegExp(r'[^A-Za-z0-9-]'), '')
        .trim();
    final base = 'COMSTAR-${host.isEmpty ? 'pi' : host}';
    return base.length <= 32 ? base : base.substring(0, 32);
  }

  Future<void> start() async {
    if (!enabled) {
      logInfo('hotspot_disabled', 'Fallback hotspot disabled (COMSTAR_HOTSPOT=0)');
      return;
    }
    _ssid = resolveSsid();
    await reconcile();
    onChanged?.call();
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) {
      unawaited(reconcile());
    });
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    if (_active) {
      await _tearDown(reason: 'service_stop');
    }
  }

  /// Ensure SoftAP is up iff no ethernet/Wi‑Fi-client uplink.
  Future<Map<String, Object?>> reconcile() async {
    if (!enabled) {
      return {'ok': true, 'enabled': false, 'active': false};
    }
    if (_busy) {
      return {
        'ok': true,
        'enabled': true,
        'active': _active,
        'ssid': _ssid,
        'busy': true,
      };
    }
    _busy = true;
    final prev = _active;
    try {
      final uplink = await network.hasUplink();
      if (uplink) {
        if (_active || await _hotspotConnectionUp()) {
          await _tearDown(reason: 'uplink_restored');
        }
        _lastError = null;
        return {
          'ok': true,
          'enabled': true,
          'active': false,
          'uplink': true,
          'ssid': _ssid,
        };
      }
      await _ensureUp();
      _lastError = null;
      return {
        'ok': true,
        'enabled': true,
        'active': _active,
        'uplink': false,
        'ssid': _ssid,
        'ip': gatewayIp,
      };
    } on Object catch (e) {
      _lastError = e.toString();
      logWarn('hotspot_reconcile_failed', e.toString());
      return {
        'ok': false,
        'enabled': true,
        'active': _active,
        'error': e.toString(),
      };
    } finally {
      _busy = false;
      if (prev != _active) {
        onChanged?.call();
      }
    }
  }

  Future<bool> _hotspotConnectionUp() async {
    final r = await _nm.run([
      '-t',
      '-f',
      'NAME,DEVICE',
      'connection',
      'show',
      '--active',
    ]);
    if (!r.ok) return false;
    for (final line in r.stdout.split('\n')) {
      final parts = line.split(':');
      if (parts.isNotEmpty && parts[0] == connectionName) return true;
    }
    return false;
  }

  Future<String?> _wifiDevice() async {
    final devices = await network.listDeviceSummaries();
    for (final d in devices) {
      if (d['type'] == 'wifi') return d['device']?.toString();
    }
    return null;
  }

  Future<bool> _profileExists() async {
    final r = await _nm.run(['-t', '-f', 'NAME', 'connection', 'show']);
    if (!r.ok) return false;
    return r.stdout.split('\n').any((l) => l.trim() == connectionName);
  }

  Future<void> _stripWifiSec() async {
    // `key-mgmt none` makes NM demand WEP secrets. Remove wireless-security
    // so SoftAP is open.
    await _nm.run([
      'connection',
      'modify',
      'id',
      connectionName,
      'remove',
      '802-11-wireless-security',
    ]);
  }

  Future<void> _ensureProfile(String ifname) async {
    _ssid ??= resolveSsid();
    final ssid = _ssid!;
    final exists = await _profileExists();
    if (!exists) {
      final add = await _nm.run([
        'connection',
        'add',
        'type',
        'wifi',
        'ifname',
        ifname,
        'con-name',
        connectionName,
        'autoconnect',
        'no',
        'ssid',
        ssid,
      ]);
      if (!add.ok) {
        throw StateError(
          'hotspot profile create failed: ${add.stderr.trim().isNotEmpty ? add.stderr.trim() : add.stdout.trim()}',
        );
      }
    }

    final mod = await _nm.run([
      'connection',
      'modify',
      'id',
      connectionName,
      'connection.interface-name',
      ifname,
      '802-11-wireless.ssid',
      ssid,
      '802-11-wireless.mode',
      'ap',
      '802-11-wireless.band',
      'bg',
      'ipv4.method',
      'shared',
      'ipv4.addresses',
      cidr,
      'ipv6.method',
      'disabled',
    ]);
    if (!mod.ok) {
      throw StateError(
        'hotspot profile modify failed: ${mod.stderr.trim().isNotEmpty ? mod.stderr.trim() : mod.stdout.trim()}',
      );
    }
    await _stripWifiSec();
  }

  Future<void> _ensureUp() async {
    final ifname = await _wifiDevice();
    if (ifname == null || ifname.isEmpty) {
      throw StateError('no wifi device for hotspot');
    }
    await _nm.run(['radio', 'wifi', 'on']);
    await _ensureProfile(ifname);

    // SoftAP needs the radio; drop any client association on this iface.
    final devices = await network.listDeviceSummaries();
    for (final d in devices) {
      if (d['type'] != 'wifi') continue;
      if (d['device'] != ifname) continue;
      final conn = d['connection']?.toString();
      if (conn != null &&
          conn.isNotEmpty &&
          conn != connectionName &&
          d['state'] == 'connected') {
        await _nm.run(['device', 'disconnect', ifname]);
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }

    if (await _hotspotConnectionUp()) {
      if (!_active) {
        _active = true;
        logInfo('hotspot_active', 'Fallback hotspot already up', data: {
          'ssid': _ssid,
          'ip': gatewayIp,
          'device': ifname,
        });
      }
      return;
    }

    var up = await _nm.run(['connection', 'up', 'id', connectionName]);
    if (!up.ok) {
      final err = '${up.stderr}\n${up.stdout}'.toLowerCase();
      if (err.contains('secret') || err.contains('password') || err.contains('wep')) {
        // Rebuild profile without wifi-sec (older broken open-AP settings).
        await _nm.run(['connection', 'delete', 'id', connectionName]);
        await _ensureProfile(ifname);
        up = await _nm.run(['connection', 'up', 'id', connectionName]);
      }
    }
    if (!up.ok) {
      throw StateError(
        'hotspot up failed: ${up.stderr.trim().isNotEmpty ? up.stderr.trim() : up.stdout.trim()}',
      );
    }
    _active = true;
    logInfo('hotspot_up', 'Fallback hotspot started', data: {
      'ssid': _ssid,
      'ip': gatewayIp,
      'device': ifname,
      'cidr': cidr,
    });
  }

  Future<void> _tearDown({required String reason}) async {
    final down = await _nm.run(['connection', 'down', 'id', connectionName]);
    // Ignore "not active" failures.
    final was = _active;
    _active = false;
    if (was || down.ok) {
      logInfo('hotspot_down', 'Fallback hotspot stopped', data: {
        'reason': reason,
        'ssid': _ssid,
      });
    }
  }
}
