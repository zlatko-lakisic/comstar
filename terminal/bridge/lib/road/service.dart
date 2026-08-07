/// Periodic home detection + VPN phone-home monitor / heal.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:comstar_bridge/log.dart';
import 'package:comstar_bridge/road/config.dart';
import 'package:comstar_bridge/road/home_detect.dart';
import 'package:comstar_bridge/road/nmcli_backend.dart';
import 'package:comstar_bridge/road/prereqs.dart';
import 'package:comstar_bridge/road/store.dart';

typedef HealthProber = Future<bool> Function(String url);

class RoadService {
  RoadService({
    required RoadConfig yamlConfig,
    this.defaultHealthUrl = '',
    RoadStore? store,
    NmcliVpnBackend? backend,
    InterfaceLister? listInterfaces,
    HealthProber? healthProber,
    ProcessRunner? processRunner,
  })  : _yaml = yamlConfig,
        store = store ?? RoadStore(),
        backend = backend ?? NmcliVpnBackend(),
        _listInterfaces = listInterfaces,
        _healthProber = healthProber ?? _defaultHealthProbe,
        _processRunner = processRunner ?? Process.run {
    this.backend.stateDir ??= this.store.stateDir;
  }

  final RoadConfig _yaml;
  final String defaultHealthUrl;
  final RoadStore store;
  final NmcliVpnBackend backend;
  final InterfaceLister? _listInterfaces;
  final HealthProber _healthProber;
  final ProcessRunner _processRunner;

  RoadConfig _effective = const RoadConfig();
  Timer? _timer;
  String? lastError;
  int? lastReconcileTs;
  HomeDetectResult? lastHome;
  String? lastActiveConnection;
  String? lastActiveProtocol;
  bool _reconciling = false;

  // Health / heal state
  bool? healthOk;
  int? lastHealthTs;
  int healCount = 0;
  int consecutiveFailures = 0;
  int? lastHealTs;
  int? nextHealEarliestTs;
  String monitorState = 'idle'; // idle | watching | healing | healthy | degraded

  RoadPrereqReport? _cachedPrereqs;
  int? _prereqsCachedAt;

  RoadConfig get config => _effective;

  String get resolvedHealthUrl {
    final u = _effective.healthUrl.trim();
    if (u.isNotEmpty) return u;
    final d = defaultHealthUrl.trim();
    if (d.isNotEmpty) return d;
    return 'http://10.0.10.16:8765/health';
  }

  Future<void> start() async {
    await store.ensureDir();
    _effective = await store.loadEffective(_yaml);
    backend.stateDir ??= store.stateDir;

    logInfo('road_started', 'Road VPN monitor started', data: {
      'enabled': _effective.enabled,
      'protocol': _effective.protocol,
      'home_cidrs': _effective.homeCidrs,
      'interval_s': _effective.checkIntervalSeconds,
      'health_url': resolvedHealthUrl,
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

  Future<RoadPrereqReport> prerequisites({bool force = false}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force &&
        _cachedPrereqs != null &&
        _prereqsCachedAt != null &&
        now - _prereqsCachedAt! < 60000) {
      return _cachedPrereqs!;
    }
    final report = await checkRoadPrereqs(runner: _processRunner);
    _cachedPrereqs = report;
    _prereqsCachedAt = now;
    return report;
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
    final prereq = await prerequisites();
    final secrets = await store.loadSecrets();
    final secretsOut = <String, Object?>{};
    if (secrets['openvpn'] is Map) {
      final o = Map<String, dynamic>.from(secrets['openvpn'] as Map);
      secretsOut['openvpn'] = {
        'ovpn': o['ovpn']?.toString() ?? '',
        'passphrase': o['passphrase']?.toString() ?? '',
        'username': o['username']?.toString() ?? '',
        'password': o['password']?.toString() ?? '',
      };
    }
    if (secrets['l2tp'] is Map) {
      final o = Map<String, dynamic>.from(secrets['l2tp'] as Map);
      secretsOut['l2tp'] = {
        'gateway': o['gateway']?.toString() ?? '',
        'user': o['user']?.toString() ?? '',
        'password': o['password']?.toString() ?? '',
        'psk': o['psk']?.toString() ?? '',
        'ipsec_enabled': o['ipsec_enabled'] != false,
      };
    }

    return {
      'ok': true,
      ..._effective.toJson(),
      'health_url_resolved': resolvedHealthUrl,
      'at_home': home.atHome,
      'matched_addrs': home.matchedAddrs,
      'all_addrs': home.allAddrs,
      'vpn_active': activeConn != null,
      'active_connection': activeConn,
      'active_protocol': activeProto,
      'openvpn_configured': ovpnExists || secretsOvpn,
      'l2tp_configured': l2tpExists || secretsL2tp,
      'openvpn_profile_present': ovpnExists,
      'l2tp_profile_present': l2tpExists,
      'secrets': secretsOut,
      'prereqs_ok': prereq.ok,
      'prereqs': prereq.toJson(),
      'health_ok': healthOk,
      'last_health_ts': lastHealthTs,
      'heal_count': healCount,
      'consecutive_failures': consecutiveFailures,
      'last_heal_ts': lastHealTs,
      'next_heal_earliest_ts': nextHealEarliestTs,
      'monitor_state': monitorState,
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
    final backoff = patch['heal_backoff_max_seconds'];
    if (backoff != null) {
      final n = backoff is int ? backoff : int.tryParse('$backoff');
      if (n == null || n < 30 || n > 3600) {
        throw ArgumentError('heal_backoff_max_seconds must be 30–3600');
      }
    }
    final base = await store.loadEffective(_yaml);
    _effective = RoadConfig.fromJson(patch, base: base);
    await store.saveRuntime(_effective);
    _armTimer();
    logInfo('road_configured', 'Road runtime updated', data: {
      'enabled': _effective.enabled,
      'protocol': _effective.protocol,
      'monitor': _effective.enabled ? 'on' : 'off',
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
      final parsed = sanitizeOvpnForNmcli(ovpn);
      // Explicit form fields win; fill gaps from embedded <auth-user-pass>.
      final patchO = Map<String, dynamic>.from(patch['openvpn'] as Map);
      final explicitUser = patchO['username']?.toString().trim() ?? '';
      final explicitPass = patchO['password']?.toString() ?? '';
      if (explicitUser.isNotEmpty) {
        o['username'] = explicitUser;
      } else if ((parsed.username ?? '').isNotEmpty) {
        o['username'] = parsed.username;
      }
      if (explicitPass.isNotEmpty) {
        o['password'] = explicitPass;
      } else if ((parsed.password ?? '').isNotEmpty) {
        o['password'] = parsed.password;
      }
      await store.mergeSecrets({'openvpn': o});

      final r = await backend.applyOpenVpn(
        connectionName: _effective.openvpnConnection,
        ovpnText: ovpn,
        passphrase: o['passphrase']?.toString(),
        username: o['username']?.toString(),
        password: o['password']?.toString(),
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

  /// One-shot setup: optional secrets → enable monitor → connect (force).
  Future<Map<String, Object?>> initialize(Map<String, dynamic> body) async {
    final prereq = await prerequisites();
    if (!prereq.ok) {
      return {
        'ok': false,
        'action': 'initialize',
        'error': 'prereqs_missing',
        'prereqs': prereq.toJson(),
      };
    }

    final cfgPatch = <String, dynamic>{
      if (body['protocol'] != null) 'protocol': body['protocol'],
      if (body['home_cidrs'] != null) 'home_cidrs': body['home_cidrs'],
      if (body['openvpn_connection'] != null)
        'openvpn_connection': body['openvpn_connection'],
      if (body['l2tp_connection'] != null)
        'l2tp_connection': body['l2tp_connection'],
      if (body['health_url'] != null) 'health_url': body['health_url'],
      if (body['check_interval_seconds'] != null)
        'check_interval_seconds': body['check_interval_seconds'],
      'enabled': true,
    };
    await configure(cfgPatch);

    if (body['openvpn'] is Map || body['l2tp'] is Map) {
      await setSecrets(body, apply: true);
    }

    // Ensure a profile exists for the selected protocol.
    final proto = _effective.protocol == 'auto'
        ? ((await backend.connectionExists(_effective.openvpnConnection))
            ? 'openvpn'
            : 'l2tp')
        : _effective.protocol;
    final name = proto == 'l2tp'
        ? _effective.l2tpConnection
        : _effective.openvpnConnection;
    if (!await backend.connectionExists(name)) {
      lastError = 'profile_missing_after_init';
      return {
        'ok': false,
        'action': 'initialize',
        'error': lastError,
        'hint': 'Apply OpenVPN (.ovpn) or L2TP credentials, then Initialize again',
      };
    }

    consecutiveFailures = 0;
    nextHealEarliestTs = null;
    final connectResult = await reconcile(forceConnect: true);
    final snap = await inspect();
    return {
      'ok': connectResult['ok'] == true,
      'action': 'initialize',
      'connect': connectResult,
      ...snap,
    };
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
        healthOk = null;
        consecutiveFailures = 0;
        nextHealEarliestTs = null;
        monitorState = 'idle';
        lastError = null;
        logInfo('road_reconcile', 'At home — VPN down, monitor idle', data: {
          'matched': snap['matched_addrs'],
        });
        return {
          'ok': true,
          'action': 'home_vpn_down',
          ...snap,
          'vpn_active': false,
          'active_connection': null,
          'active_protocol': null,
          'monitor_state': monitorState,
        };
      }

      if (!_effective.enabled && !forceConnect) {
        monitorState = 'idle';
        logInfo('road_reconcile', 'Road VPN disabled', data: {'at_home': atHome});
        return {'ok': true, 'action': 'disabled', ...snap, 'monitor_state': monitorState};
      }

      monitorState = 'watching';

      // --- Health path when tunnel appears up ---
      if (vpnActive && !forceConnect) {
        final healthy = await _probeHealth();
        if (healthy) {
          consecutiveFailures = 0;
          nextHealEarliestTs = null;
          monitorState = 'healthy';
          lastError = null;
          return {
            'ok': true,
            'action': 'healthy',
            ...snap,
            'health_ok': true,
            'monitor_state': monitorState,
          };
        }
        // Tunnel up but unreachable home — heal (bounce).
        return await _heal(
          reason: 'health_failed',
          bounce: true,
          snap: snap,
        );
      }

      // --- VPN down while enabled / force ---
      return await _heal(
        reason: vpnActive ? 'force_reconnect' : 'vpn_down',
        bounce: vpnActive,
        snap: snap,
        force: forceConnect,
      );
    } finally {
      _reconciling = false;
    }
  }

  Future<Map<String, Object?>> _heal({
    required String reason,
    required bool bounce,
    required Map<String, Object?> snap,
    bool force = false,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force &&
        nextHealEarliestTs != null &&
        now < nextHealEarliestTs!) {
      monitorState = 'degraded';
      return {
        'ok': false,
        'action': 'heal_backoff',
        'reason': reason,
        'next_heal_earliest_ts': nextHealEarliestTs,
        ...snap,
        'monitor_state': monitorState,
        'health_ok': healthOk,
      };
    }

    monitorState = 'healing';
    final protocol = await _resolveProtocol();
    if (protocol == null) {
      lastError = 'no_vpn_configured';
      consecutiveFailures++;
      _scheduleBackoff();
      logWarn('road_heal', 'Heal skipped — no VPN profile', data: {
        'reason': reason,
      });
      monitorState = 'degraded';
      return {
        'ok': false,
        'action': 'no_profile',
        'error': lastError,
        'reason': reason,
        ...snap,
        'monitor_state': monitorState,
      };
    }

    final name = protocol == 'openvpn'
        ? _effective.openvpnConnection
        : _effective.l2tpConnection;

    if (bounce) {
      await backend.down(name);
      await Future<void>.delayed(const Duration(seconds: 2));
    }

    final certPass = await _openVpnCertPass();
    final userPass = await _openVpnUserPass();
    var up = await backend.up(
      name,
      openVpnCertPass: protocol == 'openvpn' ? certPass : null,
      openVpnUserPass: protocol == 'openvpn' ? userPass : null,
    );
    var usedProto = protocol;
    var usedName = name;

    if (!up.ok && _effective.protocol == 'auto') {
      final alt = protocol == 'openvpn' ? 'l2tp' : 'openvpn';
      final altName = alt == 'openvpn'
          ? _effective.openvpnConnection
          : _effective.l2tpConnection;
      if (await backend.connectionExists(altName)) {
        up = await backend.up(
          altName,
          openVpnCertPass: alt == 'openvpn' ? certPass : null,
          openVpnUserPass: alt == 'openvpn' ? userPass : null,
        );
        if (up.ok) {
          usedProto = alt;
          usedName = altName;
        }
      }
    }

    lastHealTs = now;
    healCount++;

    if (!up.ok) {
      lastError = up.stderr.isNotEmpty ? up.stderr : up.message;
      consecutiveFailures++;
      _scheduleBackoff();
      monitorState = 'degraded';
      logWarn('road_heal', 'VPN heal failed', data: {
        'reason': reason,
        'connection': usedName,
        'failures': consecutiveFailures,
        'error': lastError,
      });
      return {
        'ok': false,
        'action': 'heal_failed',
        'reason': reason,
        'error': lastError,
        'monitor_state': monitorState,
      };
    }

    lastActiveConnection = usedName;
    lastActiveProtocol = usedProto;

    // Brief settle, then health probe.
    await Future<void>.delayed(const Duration(seconds: 2));
    final healthy = await _probeHealth();
    if (healthy) {
      consecutiveFailures = 0;
      nextHealEarliestTs = null;
      lastError = null;
      monitorState = 'healthy';
      logInfo('road_heal', 'VPN healed', data: {
        'reason': reason,
        'protocol': usedProto,
        'connection': usedName,
        'heal_count': healCount,
      });
      return {
        'ok': true,
        'action': 'healed',
        'reason': reason,
        'protocol': usedProto,
        'connection': usedName,
        'health_ok': true,
        'monitor_state': monitorState,
      };
    }

    consecutiveFailures++;
    _scheduleBackoff();
    monitorState = 'degraded';
    lastError = 'health_failed_after_up';
    logWarn('road_heal', 'VPN up but health probe failed', data: {
      'reason': reason,
      'url': resolvedHealthUrl,
      'failures': consecutiveFailures,
    });
    return {
      'ok': false,
      'action': 'heal_unhealthy',
      'reason': reason,
      'connection': usedName,
      'health_ok': false,
      'monitor_state': monitorState,
      'error': lastError,
    };
  }

  void _scheduleBackoff() {
    final maxSec = _effective.healBackoffMaxSeconds.clamp(30, 3600);
    final exp = min(consecutiveFailures, 6);
    final base = min(maxSec, 5 * (1 << (exp <= 0 ? 0 : exp - 1)));
    final jitter = Random().nextInt(max(1, base ~/ 5));
    final delaySec = min(maxSec, base + jitter);
    nextHealEarliestTs =
        DateTime.now().millisecondsSinceEpoch + delaySec * 1000;
  }

  Future<bool> _probeHealth() async {
    final url = resolvedHealthUrl;
    try {
      final ok = await _healthProber(url);
      healthOk = ok;
      lastHealthTs = DateTime.now().millisecondsSinceEpoch;
      return ok;
    } on Object catch (e) {
      healthOk = false;
      lastHealthTs = DateTime.now().millisecondsSinceEpoch;
      lastError = 'health_probe_error: $e';
      return false;
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
    consecutiveFailures = 0;
    nextHealEarliestTs = null;
    return reconcile(forceConnect: force);
  }

  Future<Map<String, Object?>> disconnect() async {
    await _downBoth();
    lastActiveConnection = null;
    lastActiveProtocol = null;
    healthOk = null;
    monitorState = _effective.enabled ? 'watching' : 'idle';
    lastError = null;
    return {'ok': true, 'action': 'disconnected', 'monitor_state': monitorState};
  }

  Future<void> _downBoth() async {
    await backend.down(_effective.openvpnConnection);
    await backend.down(_effective.l2tpConnection);
  }

  Future<String?> _openVpnCertPass() async {
    final secrets = await store.loadSecrets();
    final o = secrets['openvpn'];
    if (o is! Map) return null;
    final pass = o['passphrase']?.toString() ?? '';
    if (pass.isEmpty) return null;
    return pass;
  }

  Future<String?> _openVpnUserPass() async {
    final secrets = await store.loadSecrets();
    final o = secrets['openvpn'];
    if (o is! Map) return null;
    // Prefer explicit field; else parse from ovpn blob.
    final direct = o['password']?.toString() ?? '';
    if (direct.isNotEmpty) return direct;
    final ovpn = o['ovpn']?.toString() ?? '';
    final parsed = sanitizeOvpnForNmcli(ovpn);
    final p = parsed.password ?? '';
    if (p.isEmpty) return null;
    return p;
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

Future<bool> _defaultHealthProbe(String url) async {
  final client = HttpClient();
  try {
    client.connectionTimeout = const Duration(seconds: 4);
    final uri = Uri.parse(url);
    final req = await client.getUrl(uri).timeout(const Duration(seconds: 4));
    final resp = await req.close().timeout(const Duration(seconds: 6));
    await resp.drain<void>();
    return resp.statusCode >= 200 && resp.statusCode < 500;
  } on Object {
    return false;
  } finally {
    client.close(force: true);
  }
}
