/// Periodic home detection + VPN phone-home reconciler.
library;

import 'dart:async';

import 'package:comstar_bridge/log.dart';
import 'package:comstar_bridge/road/config.dart';
import 'package:comstar_bridge/road/home_detect.dart';
import 'package:comstar_bridge/road/nmcli_backend.dart';
import 'package:comstar_bridge/road/store.dart';

class RoadService {
  RoadService({
    required RoadConfig yamlConfig,
    RoadStore? store,
    NmcliVpnBackend? backend,
    InterfaceLister? listInterfaces,
  })  : _yaml = yamlConfig,
        store = store ?? RoadStore(),
        backend = backend ?? NmcliVpnBackend(),
        _listInterfaces = listInterfaces {
    this.backend.stateDir ??= this.store.stateDir;
  }

  final RoadConfig _yaml;
  final RoadStore store;
  final NmcliVpnBackend backend;
  final InterfaceLister? _listInterfaces;

  RoadConfig _effective = const RoadConfig();
  Timer? _timer;
  String? lastError;
  int? lastReconcileTs;
  HomeDetectResult? lastHome;
  String? lastActiveConnection;
  String? lastActiveProtocol;
  bool _reconciling = false;

  RoadConfig get config => _effective;

  Future<void> start() async {
    await store.ensureDir();
    _effective = await store.loadEffective(_yaml);
    backend.stateDir ??= store.stateDir;

    logInfo('road_started', 'Road VPN reconciler started', data: {
      'enabled': _effective.enabled,
      'protocol': _effective.protocol,
      'home_cidrs': _effective.homeCidrs,
      'interval_s': _effective.checkIntervalSeconds,
    });
    await reconcile();
    _armTimer();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _armTimer() {
    _timer?.cancel();
    final secs = _effective.checkIntervalSeconds.clamp(5, 3600);
    _timer = Timer.periodic(Duration(seconds: secs), (_) {
      unawaited(reconcile());
    });
  }

  Future<Map<String, Object?>> inspect() async {
    _effective = await store.loadEffective(_yaml);
    final home = await detectHome(
      homeCidrs: _effective.homeCidrs,
      listInterfaces: _listInterfaces,
    );
    lastHome = home;
    final ovpnName = _effective.openvpnConnection;
    final l2tpName = _effective.l2tpConnection;
    final ovpnUp = await backend.isActive(ovpnName);
    final l2tpUp = await backend.isActive(l2tpName);
    final ovpnExists = await backend.connectionExists(ovpnName);
    final l2tpExists = await backend.connectionExists(l2tpName);
    String? activeConn;
    String? activeProto;
    if (ovpnUp) {
      activeConn = ovpnName;
      activeProto = 'openvpn';
    } else if (l2tpUp) {
      activeConn = l2tpName;
      activeProto = 'l2tp';
    }
    lastActiveConnection = activeConn;
    lastActiveProtocol = activeProto;

    final secretsOvpn = await store.hasOpenVpnSecrets();
    final secretsL2tp = await store.hasL2tpSecrets();

    return {
      'ok': true,
      ..._effective.toJson(),
      'at_home': home.atHome,
      'matched_addrs': home.matchedAddrs,
      'all_addrs': home.allAddrs,
      'vpn_active': activeConn != null,
      'active_connection': activeConn,
      'active_protocol': activeProto,
      'openvpn_configured': ovpnExists || secretsOvpn,
      'l2tp_configured': l2tpExists || secretsL2tp,
      'last_error': lastError,
      'last_reconcile_ts': lastReconcileTs,
    };
  }

  Future<RoadConfig> configure(Map<String, dynamic> patch) async {
    final proto = patch['protocol']?.toString();
    if (proto != null && !roadProtocols.contains(proto)) {
      throw ArgumentError('protocol must be one of: ${roadProtocols.join(', ')}');
    }
    if (patch.containsKey('home_cidrs')) {
      final raw = patch['home_cidrs'];
      if (raw is! List || raw.isEmpty) {
        throw ArgumentError('home_cidrs must be a non-empty list');
      }
    }
    final interval = patch['check_interval_seconds'];
    if (interval != null) {
      final n = interval is int ? interval : int.tryParse('$interval');
      if (n == null || n < 5 || n > 3600) {
        throw ArgumentError('check_interval_seconds must be 5–3600');
      }
    }
    final base = await store.loadEffective(_yaml);
    _effective = RoadConfig.fromJson(patch, base: base);
    await store.saveRuntime(_effective);
    _armTimer();
    logInfo('road_configured', 'Road runtime updated', data: {
      'enabled': _effective.enabled,
      'protocol': _effective.protocol,
    });
    return _effective;
  }

  Future<void> setSecrets(Map<String, dynamic> body, {bool apply = true}) async {
    final patch = <String, dynamic>{};
    if (body['openvpn'] is Map) {
      patch['openvpn'] = Map<String, dynamic>.from(body['openvpn'] as Map);
    }
    if (body['l2tp'] is Map) {
      patch['l2tp'] = Map<String, dynamic>.from(body['l2tp'] as Map);
    }
    if (patch.isEmpty) {
      throw ArgumentError('openvpn and/or l2tp required');
    }
    await store.mergeSecrets(patch);
    if (!apply) return;

    final secrets = await store.loadSecrets();
    if (patch.containsKey('openvpn')) {
      final o = Map<String, dynamic>.from(secrets['openvpn'] as Map? ?? {});
      final ovpn = o['ovpn']?.toString() ?? '';
      if (ovpn.trim().isEmpty) {
        throw ArgumentError('openvpn.ovpn text required');
      }
      final r = await backend.applyOpenVpn(
        connectionName: _effective.openvpnConnection,
        ovpnText: ovpn,
        passphrase: o['passphrase']?.toString(),
      );
      if (!r.ok) {
        lastError = r.message;
        throw StateError(r.stderr.isNotEmpty ? r.stderr : r.message);
      }
    }
    if (patch.containsKey('l2tp')) {
      final o = Map<String, dynamic>.from(secrets['l2tp'] as Map? ?? {});
      final r = await backend.applyL2tp(
        connectionName: _effective.l2tpConnection,
        gateway: o['gateway']?.toString() ?? '',
        user: o['user']?.toString() ?? '',
        password: o['password']?.toString() ?? '',
        psk: o['psk']?.toString() ?? '',
        ipsecEnabled: o['ipsec_enabled'] != false,
      );
      if (!r.ok) {
        lastError = r.message;
        throw StateError(r.stderr.isNotEmpty ? r.stderr : r.message);
      }
    }
    lastError = null;
  }

  Future<Map<String, Object?>> reconcile({bool forceConnect = false}) async {
    if (_reconciling) {
      return {'ok': true, 'skipped': 'in_progress'};
    }
    _reconciling = true;
    try {
      _effective = await store.loadEffective(_yaml);
      final snap = await inspect();
      lastReconcileTs = DateTime.now().millisecondsSinceEpoch;
      final atHome = snap['at_home'] == true;
      final vpnActive = snap['vpn_active'] == true;

      if (atHome && !forceConnect) {
        await _downBoth();
        lastError = null;
        logInfo('road_reconcile', 'At home — VPN down', data: {
          'matched': snap['matched_addrs'],
        });
        return {
          'ok': true,
          'action': 'home_vpn_down',
          ...snap,
          'vpn_active': false,
          'active_connection': null,
          'active_protocol': null,
        };
      }

      if (!_effective.enabled && !forceConnect) {
        logInfo('road_reconcile', 'Road VPN disabled', data: {'at_home': atHome});
        return {'ok': true, 'action': 'disabled', ...snap};
      }

      if (vpnActive && !forceConnect) {
        return {'ok': true, 'action': 'already_up', ...snap};
      }

      final protocol = await _resolveProtocol();
      if (protocol == null) {
        lastError = 'no_vpn_configured';
        logWarn('road_reconcile', 'Off-home but no VPN profile configured');
        return {
          'ok': false,
          'action': 'no_profile',
          'error': lastError,
          ...snap,
        };
      }
      final name = protocol == 'openvpn'
          ? _effective.openvpnConnection
          : _effective.l2tpConnection;
      final up = await backend.up(name);
      if (!up.ok) {
        lastError = up.stderr.isNotEmpty ? up.stderr : up.message;
        if (_effective.protocol == 'auto') {
          final alt = protocol == 'openvpn' ? 'l2tp' : 'openvpn';
          final altName = alt == 'openvpn'
              ? _effective.openvpnConnection
              : _effective.l2tpConnection;
          if (await backend.connectionExists(altName)) {
            final up2 = await backend.up(altName);
            if (up2.ok) {
              lastError = null;
              lastActiveConnection = altName;
              lastActiveProtocol = alt;
              return {
                'ok': true,
                'action': 'connected',
                'protocol': alt,
                'connection': altName,
                'fallback': true,
              };
            }
          }
        }
        return {'ok': false, 'action': 'connect_failed', 'error': lastError};
      }
      lastError = null;
      lastActiveConnection = name;
      lastActiveProtocol = protocol;
      logInfo('road_reconcile', 'VPN connected', data: {
        'protocol': protocol,
        'connection': name,
        'force': forceConnect,
      });
      return {
        'ok': true,
        'action': 'connected',
        'protocol': protocol,
        'connection': name,
      };
    } finally {
      _reconciling = false;
    }
  }

  /// Operator connect. Defaults to [force] so it works even while still at home.
  Future<Map<String, Object?>> connect({
    String? protocol,
    bool force = true,
  }) async {
    if (protocol != null) {
      if (protocol != 'openvpn' && protocol != 'l2tp') {
        throw ArgumentError('protocol must be openvpn or l2tp');
      }
      await configure({'protocol': protocol});
    }
    return reconcile(forceConnect: force);
  }

  Future<Map<String, Object?>> disconnect() async {
    await _downBoth();
    lastActiveConnection = null;
    lastActiveProtocol = null;
    lastError = null;
    return {'ok': true, 'action': 'disconnected'};
  }

  Future<void> _downBoth() async {
    await backend.down(_effective.openvpnConnection);
    await backend.down(_effective.l2tpConnection);
  }

  Future<String?> _resolveProtocol() async {
    final pref = _effective.protocol;
    final ovpn = _effective.openvpnConnection;
    final l2tp = _effective.l2tpConnection;
    final hasOvpn = await backend.connectionExists(ovpn);
    final hasL2tp = await backend.connectionExists(l2tp);
    if (pref == 'openvpn') return hasOvpn ? 'openvpn' : null;
    if (pref == 'l2tp') return hasL2tp ? 'l2tp' : null;
    if (hasOvpn) return 'openvpn';
    if (hasL2tp) return 'l2tp';
    return null;
  }
}
