import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ao_reach/ao_reach.dart';
import 'package:path/path.dart' as p;

import 'package:comstar_bridge/announce/types.dart';
import 'package:comstar_bridge/attention/clock.dart';
import 'package:comstar_bridge/attention/coordinator.dart';
import 'package:comstar_bridge/attention/events.dart';
import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/directory/directory_resolver.dart';
import 'package:comstar_bridge/google/desktop_upgrade.dart';
import 'package:comstar_bridge/host_metrics.dart';
import 'package:comstar_bridge/house_presence.dart';
import 'package:comstar_bridge/log.dart';
import 'package:comstar_bridge/admin_ops.dart';
import 'package:comstar_bridge/ao_mtls/service.dart';
import 'package:comstar_bridge/net/service.dart';
import 'package:comstar_bridge/road/service.dart';

/// Always-on admin + shared public HTTP on :8781.
///
/// Paths:
/// - `/admin/*` — ops UI + APIs (token when LAN-bound)
/// - `/oauth/google/*` — Desktop Google OAuth (no admin token)
/// - `/health` — alias of `/admin/health` for heal scripts
class AdminServer {
  AdminServer({
    required this.coordinator,
    required this.config,
    required this.adminRoot,
    this.hostMetrics,
    this.oauth,
    this.kioskRoot,
    this.road,
    this.network,
    this.aoMtls,
    this.port = 8781,
    this.httpClientFactory,
    Future<Process> Function(String executable, List<String> arguments)?
        processRunner,
  }) : processRunner = processRunner ??
            ((exe, args) => Process.start(exe, args));

  final AttentionCoordinator coordinator;
  final ComstarConfig config;
  final String adminRoot;
  final HostMetrics? hostMetrics;
  final GoogleDesktopUpgrade? oauth;
  final String? kioskRoot;
  final RoadService? road;
  final NetworkService? network;
  final AoMtlsService? aoMtls;
  final int port;

  /// Injectable for tests.
  final HttpClient Function()? httpClientFactory;
  final Future<Process> Function(String executable, List<String> arguments)
      processRunner;

  HttpServer? _server;
  final _logStreams = <HttpResponse>{};

  bool get lanBound =>
      config.adminLanBindingEnabled || (oauth?.wantsLanBind ?? false);
  bool get injectEnabled => isAdminInjectEnabled();
  String get _authToken => config.adminAuthToken;

  Future<void> start() async {
    if (_server != null) return;
    final address = lanBound
        ? InternetAddress.anyIPv4
        : InternetAddress.loopbackIPv4;
    _server = await HttpServer.bind(address, port);
    logInfo('admin_started', 'Admin/OAuth HTTP listening', data: {
      'port': port,
      'bind': address.address,
      'lan': lanBound,
      'inject': injectEnabled,
      'admin_root': adminRoot,
      'oauth': oauth != null,
    });
    if (lanBound) {
      logWarn(
        'admin_lan_bind',
        'Admin bound to LAN — /admin requires token; /oauth/google does not',
        data: {'port': port},
      );
    }
    unawaited(_server!.listen(_handleRequest).asFuture());
  }

  Future<void> stop() async {
    for (final r in List<HttpResponse>.from(_logStreams)) {
      try {
        await r.close();
      } on Object {
        // ignore
      }
    }
    _logStreams.clear();
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;

      // Google Desktop OAuth — no admin token.
      if (path.startsWith('/oauth/google')) {
        final o = oauth;
        if (o == null) {
          await _writeJson(request, 503, {
            'ok': false,
            'error': 'oauth_unavailable',
          });
          return;
        }
        await o.handleHttp(request);
        return;
      }

      // Shared emblem / presets for admin ES modules (same origin).
      if (request.method == 'GET' && path.startsWith('/kiosk/')) {
        final root = kioskRoot;
        if (root == null) {
          await _writeJson(request, 404, {'ok': false, 'error': 'not_found'});
          return;
        }
        final rel = path.substring('/kiosk/'.length);
        final ok = await _tryServeFrom(request, root, rel);
        if (!ok) {
          await _writeJson(request, 404, {'ok': false, 'error': 'not_found'});
        }
        return;
      }

      // Convenience: / → /admin/
      if (request.method == 'GET' && (path == '/' || path.isEmpty)) {
        final q = request.uri.query.isEmpty ? '' : '?${request.uri.query}';
        request.response
          ..statusCode = HttpStatus.movedTemporarily
          ..headers.set(HttpHeaders.locationHeader, '/admin/$q');
        await request.response.close();
        return;
      }

      // House presence snapshot (CONTRACTS §7b) — no admin token; LAN trust.
      if (request.method == 'GET' && path == '/v1/presence/home') {
        final svc = HousePresenceService(
          config: config.presence,
          clock: SystemClock(),
        );
        await _writeJson(request, 200, await svc.snapshot());
        return;
      }

      // Normalize admin paths: /health → /admin/health (heal scripts).
      final adminPath = path == '/health'
          ? '/admin/health'
          : path == '/inject'
              ? '/admin/inject'
              : path;

      if (!adminPath.startsWith('/admin')) {
        await _writeJson(request, 404, {'ok': false, 'error': 'not_found'});
        return;
      }

      final isAsset = _isStaticAsset(adminPath);
      // Require token for /admin when LAN-exposed with a configured admin token.
      final authGate = config.adminLanBindingEnabled ||
          (lanBound && _authToken.isNotEmpty);
      final needsAuth = adminPath != '/admin/health' && !isAsset;
      if (needsAuth &&
          !adminTokenMatches(
            lanBound: authGate,
            expectedToken: _authToken,
            headerToken: request.headers.value('x-comstar-lan-token') ??
                request.headers.value('X-Comstar-Lan-Token'),
            queryToken: request.uri.queryParameters['token'],
          )) {
        await _writeJson(request, 401, {'ok': false, 'error': 'unauthorized'});
        return;
      }

      if (request.method == 'GET' && adminPath == '/admin/health') {
        await _writeJson(request, 200, coordinator.healthStatus());
        return;
      }

      if (request.method == 'GET' && adminPath == '/admin/api/status') {
        await _writeJson(request, 200, await _status());
        return;
      }

      if (request.method == 'GET' && adminPath == '/admin/api/logs') {
        await _streamLogs(request);
        return;
      }

      if (request.method == 'POST' && adminPath == '/admin/api/restart') {
        await _handleRestart(request);
        return;
      }

      if (request.method == 'POST' && adminPath == '/admin/api/reboot') {
        await _handleReboot(request);
        return;
      }

      if (request.method == 'POST' && adminPath == '/admin/api/sleep') {
        await _handleSleep(request);
        return;
      }

      if (request.method == 'GET' && adminPath == '/admin/api/announce') {
        final svc = coordinator.announce;
        if (svc == null) {
          await _writeJson(request, 503, {'ok': false, 'error': 'announce_disabled'});
          return;
        }
        await _writeJson(request, 200, {
          'ok': true,
          ...Map<String, Object?>.from(svc.inspect()),
        });
        return;
      }

      if (request.method == 'POST' && adminPath == '/admin/api/announce') {
        await _handleAnnounce(request);
        return;
      }

      if (request.method == 'GET' && adminPath == '/admin/api/road') {
        await _handleRoadGet(request);
        return;
      }

      if (request.method == 'POST' && adminPath == '/admin/api/road') {
        await _handleRoadPost(request);
        return;
      }

      if (request.method == 'GET' && adminPath == '/admin/api/network') {
        await _handleNetworkGet(request);
        return;
      }

      if (request.method == 'POST' && adminPath == '/admin/api/network') {
        await _handleNetworkPost(request);
        return;
      }

      if (request.method == 'GET' && adminPath == '/admin/api/ao_mtls') {
        await _handleAoMtlsGet(request);
        return;
      }

      if (request.method == 'POST' && adminPath == '/admin/api/ao_mtls') {
        await _handleAoMtlsPost(request);
        return;
      }

      if (request.method == 'POST' && adminPath == '/admin/inject') {
        await _handleInject(request);
        return;
      }

      if (request.method == 'GET') {
        await _serveStatic(request, adminPath);
        return;
      }

      await _writeJson(request, 404, {'ok': false, 'error': 'not_found'});
    } on Object catch (e) {
      logWarn('admin_request_failed', e.toString());
      try {
        await _writeJson(request, 500, {'ok': false, 'error': 'internal'});
      } on Object {
        // ignore
      }
    }
  }

  Future<Map<String, Object?>> _status() async {
    final base = Map<String, Object?>.from(coordinator.healthStatus());
    base['inject_enabled'] = injectEnabled;
    base['lan_bound'] = lanBound;
    base['admin'] = true;
    base['hostname'] = Platform.localHostname;
    base['port'] = port;
    base['bind'] = lanBound ? '0.0.0.0' : '127.0.0.1';
    try {
      final up = await File('/proc/uptime').readAsString();
      final secs = double.tryParse(up.split(RegExp(r'\s+')).first);
      if (secs != null) base['uptime_s'] = secs.round();
    } on Object {
      // non-linux
    }

    final metrics = hostMetrics;
    if (metrics != null) {
      try {
        final sample = await metrics.sample();
        base['cpu'] = sample.cpuPercent;
        base['mem'] = sample.memPercent;
        base['metrics_ts'] = sample.tsMs;
      } on Object {
        // leave unset
      }
    }

    final aoBase = config.orchestration.baseUrl.replaceAll(RegExp(r'/+$'), '');
    final aoUrl = Platform.environment['COMSTAR_AO_URL']?.trim().isNotEmpty ==
            true
        ? Platform.environment['COMSTAR_AO_URL']!.trim()
        : '$aoBase/health';
    final cpaiBase = Platform.environment['COMSTAR_CPAI_URL']?.trim().isNotEmpty ==
            true
        ? Platform.environment['COMSTAR_CPAI_URL']!.trim()
        : (config.vision.codeprojectUrl.isNotEmpty
            ? config.vision.codeprojectUrl
            : 'http://10.0.10.16:32168');
    final aoProbe = aoUrl.endsWith('/health') ? aoUrl : '$aoUrl/health';
    final aoOk = await _probeAoHttp(aoProbe);
    final cpaiOk = await _probeHttp('$cpaiBase/v1/server/status/ping') ||
        await _probeHttp(cpaiBase);
    base['ao_ok'] = aoOk;
    base['cpai_ok'] = cpaiOk;
    base['ao_url'] = aoProbe;
    base['cpai_url'] = cpaiBase;

    // Unit active hints (best-effort).
    final units = <String, Object?>{};
    for (final e in adminRestartUnits.entries) {
      units[e.key] = await _unitActive(e.value);
    }
    base['units'] = units;

    final roadSvc = road;
    if (roadSvc != null) {
      try {
        final r = await roadSvc.inspect();
        base['road'] = {
          'enabled': r['enabled'],
          'at_home': r['at_home'],
          'vpn_active': r['vpn_active'],
          'active_protocol': r['active_protocol'],
          'protocol': r['protocol'],
          'monitor_state': r['monitor_state'],
          'health_ok': r['health_ok'],
          'prereqs_ok': r['prereqs_ok'],
          'last_error': r['last_error'],
        };
      } on Object {
        base['road'] = {'ok': false};
      }
    }

    final mtlsSvc = aoMtls;
    if (mtlsSvc != null) {
      try {
        base['ao_mtls'] = {
          'enabled': mtlsSvc.mtls.enabled,
          'paired': AoMtlsService.materialPresent(mtlsSvc.materialDir),
        };
      } on Object {
        base['ao_mtls'] = {'ok': false};
      }
    }
    return base;
  }

  Future<bool> _unitActive(String unit) async {
    try {
      final proc = await processRunner(
        'systemctl',
        ['--user', 'is-active', '--quiet', unit],
      );
      final code = await proc.exitCode.timeout(const Duration(seconds: 3));
      return code == 0;
    } on Object {
      return false;
    }
  }

  Future<bool> _probeAoHttp(String url) async {
    final mtls = config.orchestration.mtls;
    if (mtls.enabled) {
      final dir = mtls.resolvedMaterialDir();
      if (AoMtlsService.materialPresent(dir)) {
        HttpClient? client;
        try {
          final material =
              loadReachMtlsMaterial(ReachMtlsConfig(materialDir: dir));
          client = reachMtlsHttpClient(material);
          client.connectionTimeout = const Duration(seconds: 2);
          final uri = Uri.parse(url);
          final req =
              await client.getUrl(uri).timeout(const Duration(seconds: 2));
          final resp = await req.close().timeout(const Duration(seconds: 3));
          await resp.drain<void>();
          return resp.statusCode >= 200 && resp.statusCode < 500;
        } on Object {
          return false;
        } finally {
          client?.close(force: true);
        }
      }
    }
    return _probeHttp(url);
  }

  Future<bool> _probeHttp(String url) async {
    HttpClient? client;
    try {
      client = httpClientFactory?.call() ?? HttpClient();
      client.connectionTimeout = const Duration(seconds: 2);
      final uri = Uri.parse(url);
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 2));
      final resp = await req.close().timeout(const Duration(seconds: 3));
      await resp.drain<void>();
      return resp.statusCode >= 200 && resp.statusCode < 500;
    } on Object {
      return false;
    } finally {
      client?.close(force: true);
    }
  }

  Future<void> _handleRestart(HttpRequest request) async {
    final body = await _readJson(request);
    final key = body['unit']?.toString() ?? '';
    final resolved = resolveAdminUnit(key);
    if (resolved == null) {
      await _writeJson(request, 400, {
        'ok': false,
        'error': 'invalid_unit',
        'allowed': adminRestartUnits.keys.toList()..add('all'),
      });
      return;
    }

    final units = resolved == 'all' ? allAdminUnits() : [resolved];
    logInfo('admin_restart', 'Restarting units', data: {
      'units': units,
      'src': 'admin',
    });

    final results = <String, Object?>{};
    for (final unit in units) {
      try {
        final proc = await processRunner(
          'systemctl',
          ['--user', 'restart', unit],
        );
        final code = await proc.exitCode.timeout(const Duration(seconds: 30));
        results[unit] = code == 0 ? 'ok' : 'exit_$code';
      } on Object catch (e) {
        results[unit] = 'error: $e';
      }
    }
    await _writeJson(request, 200, {'ok': true, 'results': results});
  }

  Future<void> _handleReboot(HttpRequest request) async {
    final body = await _readJson(request);
    if (body['confirm']?.toString() != 'reboot') {
      await _writeJson(request, 400, {
        'ok': false,
        'error': 'confirm_required',
        'hint': 'POST {"confirm":"reboot"}',
      });
      return;
    }
    logWarn('admin_reboot', 'Host reboot requested', data: {'src': 'admin'});
    // Respond before reboot so the client gets a body.
    await _writeJson(request, 200, {'ok': true, 'rebooting': true});
    try {
      await processRunner('sudo', ['/sbin/reboot']);
    } on Object catch (e) {
      logWarn('admin_reboot_failed', e.toString());
    }
  }

  Future<void> _handleSleep(HttpRequest request) async {
    final body = await _readJson(request);
    final action = (body['action'] ?? 'enter').toString();
    if (action != 'enter' && action != 'exit') {
      await _writeJson(request, 400, {'ok': false, 'error': 'invalid_action'});
      return;
    }
    if (action == 'enter') {
      coordinator.handle(const EnterSleep());
    } else {
      coordinator.handle(const ExitSleep());
    }
    logInfo('admin_sleep', 'Sleep action', data: {
      'action': action,
      'src': 'admin',
    });
    await _writeJson(request, 200, {
      'ok': true,
      'action': action,
      'sleeping': coordinator.healthStatus()['sleeping'],
    });
  }

  Future<void> _handleAnnounce(HttpRequest request) async {
    final svc = coordinator.announce;
    if (svc == null) {
      await _writeJson(request, 503, {'ok': false, 'error': 'announce_disabled'});
      return;
    }
    final body = await _readJson(request);
    final action = (body['action'] ?? 'enqueue').toString();
    if (action == 'evaluate' || action == 'force_gate') {
      final decision = await svc.evaluateAndMaybeDeliver(force: true);
      await _writeJson(request, 200, {
        'ok': true,
        'action': action,
        'decision': decision.deliver ? 'deliver' : decision.reasonWire,
        'count': decision.items.length,
      });
      return;
    }
    if (action == 'enqueue') {
      final recipient = body['recipient']?.toString().trim() ?? '';
      final intent = body['intent']?.toString().trim() ?? '';
      if (recipient.isEmpty || intent.isEmpty) {
        await _writeJson(request, 400, {
          'ok': false,
          'error': 'recipient_and_intent_required',
        });
        return;
      }
      final ttlMin = (body['ttl_minutes'] as num?)?.toInt() ?? 120;
      final row = svc.enqueue(
        recipient: recipient,
        intent: intent,
        priority: AnnouncementPriority.parse(body['priority']?.toString()),
        source: AnnouncementSource.injected,
        ttl: Duration(minutes: ttlMin.clamp(1, 24 * 60)),
        dedupeKey: body['dedupe_key']?.toString(),
        text: body['text']?.toString(),
      );
      logInfo('admin_announce_enqueue', 'Injected announcement', data: {
        'id': row.id,
        'src': 'injected',
      });
      await _writeJson(request, 200, {'ok': true, 'announcement': row.toJson()});
      return;
    }
    await _writeJson(request, 400, {'ok': false, 'error': 'invalid_action'});
  }

  Future<void> _handleRoadGet(HttpRequest request) async {
    final svc = road;
    if (svc == null) {
      await _writeJson(request, 503, {'ok': false, 'error': 'road_unavailable'});
      return;
    }
    await _writeJson(request, 200, await svc.inspect());
  }

  Future<void> _handleNetworkGet(HttpRequest request) async {
    final svc = network;
    if (svc == null) {
      await _writeJson(request, 503, {'ok': false, 'error': 'network_unavailable'});
      return;
    }
    final scan = request.uri.queryParameters['scan'] == '1' ||
        request.uri.queryParameters['scan'] == 'true';
    await _writeJson(request, 200, await svc.inspect(scan: scan));
  }

  Future<void> _handleNetworkPost(HttpRequest request) async {
    final svc = network;
    if (svc == null) {
      await _writeJson(request, 503, {'ok': false, 'error': 'network_unavailable'});
      return;
    }
    final body = await _readJson(request);
    try {
      final result = await svc.handleAction(body);
      final code = result['ok'] == true ? 200 : 502;
      await _writeJson(request, code, result);
    } on ArgumentError catch (e) {
      await _writeJson(request, 400, {'ok': false, 'error': e.message});
    } on StateError catch (e) {
      await _writeJson(request, 502, {'ok': false, 'error': e.message});
    }
  }

  Future<void> _handleAoMtlsGet(HttpRequest request) async {
    final svc = aoMtls;
    if (svc == null) {
      await _writeJson(request, 503, {'ok': false, 'error': 'ao_mtls_unavailable'});
      return;
    }
    await _writeJson(request, 200, await svc.inspect());
  }

  Future<void> _handleAoMtlsPost(HttpRequest request) async {
    final svc = aoMtls;
    if (svc == null) {
      await _writeJson(request, 503, {'ok': false, 'error': 'ao_mtls_unavailable'});
      return;
    }
    final body = await _readJson(request);
    try {
      final result = await svc.handleAction(body);
      final code = result['ok'] == true ? 200 : 502;
      await _writeJson(request, code, result);
    } on ArgumentError catch (e) {
      await _writeJson(request, 400, {'ok': false, 'error': e.message});
    } on StateError catch (e) {
      await _writeJson(request, 502, {'ok': false, 'error': e.message});
    } on Object catch (e) {
      await _writeJson(request, 502, {'ok': false, 'error': e.toString()});
    }
  }

  Future<void> _handleRoadPost(HttpRequest request) async {
    final svc = road;
    if (svc == null) {
      await _writeJson(request, 503, {'ok': false, 'error': 'road_unavailable'});
      return;
    }
    final body = await _readJson(request);
    final action = (body['action'] ?? '').toString().trim();
    try {
      switch (action) {
        case 'configure':
          final cfg = await svc.configure(body);
          await _writeJson(request, 200, {
            'ok': true,
            'action': action,
            'config': cfg.toJson(),
          });
          return;
        case 'set_secrets':
          final apply = body['apply'] != false;
          await svc.setSecrets(body, apply: apply);
          await _writeJson(request, 200, {
            'ok': true,
            'action': action,
            'applied': apply,
          });
          return;
        case 'initialize':
          final result = await svc.initialize(body);
          final code = result['ok'] == true ? 200 : 502;
          await _writeJson(request, code, result);
          return;
        case 'prereqs':
          final report = await svc.prerequisites(force: true);
          await _writeJson(request, 200, {
            'ok': report.ok,
            'action': action,
            ...report.toJson(),
          });
          return;
        case 'reconcile':
          final result = await svc.reconcile();
          await _writeJson(request, 200, {'ok': true, 'action': action, ...result});
          return;
        case 'connect':
          final proto = body['protocol']?.toString();
          final force = body['force'] != false;
          final result = await svc.connect(protocol: proto, force: force);
          await _writeJson(request, 200, {'ok': result['ok'] == true, 'action': action, ...result});
          return;
        case 'disconnect':
          final result = await svc.disconnect();
          await _writeJson(request, 200, {...result});
          return;
        default:
          await _writeJson(request, 400, {
            'ok': false,
            'error': 'invalid_action',
            'hint':
                'configure|set_secrets|initialize|prereqs|reconcile|connect|disconnect',
          });
      }
    } on ArgumentError catch (e) {
      await _writeJson(request, 400, {'ok': false, 'error': e.message});
    } on StateError catch (e) {
      await _writeJson(request, 502, {'ok': false, 'error': e.message});
    }
  }

  Future<void> _handleInject(HttpRequest request) async {
    if (!injectEnabled) {
      await _writeJson(request, 403, {
        'ok': false,
        'error': 'inject_disabled',
        'hint': 'Set COMSTAR_ENV=dev to enable inject',
      });
      return;
    }
    final body = await _readJson(request);
    final eventName = body['event']?.toString();
    if (eventName == null || eventName.isEmpty) {
      await _writeJson(request, 400, {'ok': false, 'error': 'missing_event'});
      return;
    }

    // Voice speaker-ID stub (P2.3) — resolve via directory then FaceRecognized.
    if (eventName == 'VoiceRecognized') {
      final voiceId = body['voice_id']?.toString() ?? body['voiceId']?.toString();
      if (voiceId == null || voiceId.isEmpty) {
        await _writeJson(request, 400, {
          'ok': false,
          'error': 'missing_voice_id',
        });
        return;
      }
      final conf = (body['confidence'] as num?)?.toDouble() ?? 0.9;
      final result = await coordinator.directory.resolveByVoiceId(voiceId);
      switch (result) {
        case DirectoryResolved(:final profile):
          coordinator.handle(
            FaceRecognized(
              profile.uid,
              conf,
              displayName: profile.displayName,
            ),
          );
          await _writeJson(request, 200, {
            'ok': true,
            'event': eventName,
            'uid': profile.uid,
          });
        case DirectoryMiss():
          coordinator.handle(const FaceUnknown());
          await _writeJson(request, 200, {
            'ok': true,
            'event': eventName,
            'uid': null,
            'miss': true,
          });
        case DirectoryError(:final message):
          await _writeJson(request, 502, {
            'ok': false,
            'error': message,
          });
      }
      return;
    }

    if (eventName == 'EnqueueAnnouncement') {
      final svc = coordinator.announce;
      if (svc == null) {
        await _writeJson(request, 503, {'ok': false, 'error': 'announce_disabled'});
        return;
      }
      final recipient = body['recipient']?.toString().trim() ?? '';
      final intent = body['intent']?.toString().trim() ?? '';
      if (recipient.isEmpty || intent.isEmpty) {
        await _writeJson(request, 400, {
          'ok': false,
          'error': 'recipient_and_intent_required',
        });
        return;
      }
      final row = svc.enqueue(
        recipient: recipient,
        intent: intent,
        priority: AnnouncementPriority.parse(body['priority']?.toString()),
        source: AnnouncementSource.injected,
        text: body['text']?.toString(),
        dedupeKey: body['dedupe_key']?.toString(),
      );
      await _writeJson(request, 200, {
        'ok': true,
        'event': eventName,
        'announcement': row.toJson(),
        'src': 'injected',
      });
      return;
    }

    final event = parseInjectEvent(eventName, body);
    if (event == null) {
      await _writeJson(request, 400, {
        'ok': false,
        'error': 'unknown_event',
        'event': eventName,
      });
      return;
    }
    logInfo('dev_inject', 'Injected attention event', data: {
      'event': eventName,
      'src': 'injected',
    });
    coordinator.handle(event);
    await _writeJson(request, 200, {'ok': true, 'event': eventName});
  }

  Future<void> _streamLogs(HttpRequest request) async {
    final units = [
      'comstar-bridge',
      'comstar-audio',
      'comstar-kiosk',
      'comstar-stt',
      'comstar-health',
    ];
    final args = <String>[
      '--user',
      '-f',
      '-n',
      '200',
      '-o',
      'cat',
      for (final u in units) ...['-u', u],
    ];

    Process? proc;
    try {
      proc = await processRunner('journalctl', args);
    } on Object catch (e) {
      await _writeJson(request, 503, {
        'ok': false,
        'error': 'journalctl_unavailable',
        'detail': e.toString(),
      });
      return;
    }

    request.response.statusCode = 200;
    request.response.bufferOutput = false;
    request.response.headers.contentType =
        ContentType('text', 'event-stream', charset: 'utf-8');
    request.response.headers.set('Cache-Control', 'no-cache');
    request.response.headers.set('Connection', 'keep-alive');
    request.response.headers.set('X-Accel-Buffering', 'no');
    _logStreams.add(request.response);

    void send(String line) {
      try {
        request.response.write('data: ${jsonEncode(line)}\n\n');
        // ignore: discarded_futures
        request.response.flush();
      } on Object {
        // client gone
      }
    }

    final sub = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(send, onError: (_) {}, onDone: () {});

    proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => send('[journalctl] $line'));

    // Heartbeat so proxies keep the stream open.
    final beat = Timer.periodic(const Duration(seconds: 15), (_) {
      try {
        request.response.write(': ping\n\n');
      } on Object {
        // ignore
      }
    });

    try {
      await request.response.done;
    } on Object {
      // disconnect
    } finally {
      beat.cancel();
      await sub.cancel();
      proc.kill(ProcessSignal.sigterm);
      _logStreams.remove(request.response);
      try {
        await request.response.close();
      } on Object {
        // ignore
      }
    }
  }

  Future<void> _serveStatic(HttpRequest request, String path) async {
    var rel = path;
    if (rel == '/admin' || rel == '/admin/') {
      rel = 'index.html';
    } else if (rel.startsWith('/admin/')) {
      rel = rel.substring('/admin/'.length);
    } else if (rel.startsWith('/')) {
      rel = rel.substring(1);
    }
    if (rel.isEmpty) rel = 'index.html';
    final ok = await _tryServeFile(request, rel);
    if (!ok) {
      await _writeJson(request, 404, {'ok': false, 'error': 'not_found'});
    }
  }

  Future<bool> _tryServeFile(HttpRequest request, String relPath) async {
    return _tryServeFrom(request, adminRoot, relPath);
  }

  Future<bool> _tryServeFrom(
    HttpRequest request,
    String root,
    String relPath,
  ) async {
    var rel = relPath;
    if (rel.startsWith('/')) rel = rel.substring(1);
    if (rel.startsWith('admin/')) rel = rel.substring('admin/'.length);
    final normalized = p.normalize(rel);
    if (normalized.startsWith('..') || p.isAbsolute(normalized)) {
      return false;
    }
    final file = File(p.join(root, normalized));
    if (!file.existsSync()) return false;
    final bytes = await file.readAsBytes();
    request.response.statusCode = 200;
    request.response.headers.contentType = _contentTypeFor(normalized);
    request.response.headers.set('Cache-Control', 'no-store');
    request.response.add(bytes);
    await request.response.close();
    return true;
  }

  bool _isStaticAsset(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.js') ||
        lower.endsWith('.css') ||
        lower.endsWith('.svg') ||
        lower.endsWith('.map') ||
        lower.endsWith('.woff2') ||
        lower.endsWith('.png') ||
        lower.endsWith('.ico');
  }

  ContentType _contentTypeFor(String path) {
    final ext = p.extension(path).toLowerCase();
    switch (ext) {
      case '.html':
        return ContentType.html;
      case '.js':
        return ContentType('application', 'javascript', charset: 'utf-8');
      case '.css':
        return ContentType('text', 'css', charset: 'utf-8');
      case '.svg':
        return ContentType('image', 'svg+xml');
      case '.json':
        return ContentType.json;
      default:
        return ContentType.binary;
    }
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest request) async {
    final raw = await utf8.decodeStream(request);
    if (raw.trim().isEmpty) return {};
    final decoded = jsonDecode(raw);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return {};
  }

  Future<void> _writeJson(
    HttpRequest request,
    int status,
    Map<String, Object?> body,
  ) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..headers.set('Cache-Control', 'no-store')
      ..write(jsonEncode(body));
    await request.response.close();
  }
}

/// Parses a dev inject payload into an [AttentionEvent].
AttentionEvent? parseInjectEvent(String name, Map<String, dynamic> payload) {
  switch (name) {
    case 'PersonDetected':
      return PersonDetected(
        (payload['confidence'] as num?)?.toDouble() ?? 0.9,
      );
    case 'PersonAbsent':
      return const PersonAbsent();
    case 'FaceRecognized':
      final userid = payload['userid']?.toString();
      if (userid == null || userid.isEmpty) return null;
      return FaceRecognized(
        userid,
        (payload['confidence'] as num?)?.toDouble() ?? 0.87,
        displayName: payload['displayName']?.toString(),
        faceId: payload['faceId']?.toString(),
      );
    case 'FaceUnknown':
      return const FaceUnknown();
    case 'WakeWord':
      return WakeWord((payload['score'] as num?)?.toDouble() ?? 0.8);
    case 'ExitSleep':
      return const ExitSleep();
    case 'EnterSleep':
      return const EnterSleep();
    case 'SpeechStart':
      return const SpeechStart();
    case 'SpeechEnd':
      return SpeechEnd((payload['durationMs'] as num?)?.toInt() ?? 1000);
    case 'TranscriptReady':
      final text = payload['text']?.toString() ?? '';
      return TranscriptReady(text);
    case 'ResponseReady':
      final text = payload['text']?.toString() ?? '';
      final audioUrl = payload['audioUrl']?.toString() ?? '';
      return ResponseReady(text, audioUrl);
    case 'PlaybackEnded':
      return const PlaybackEnded();
    case 'Tick':
      return const Tick();
    case 'AttentionError':
      return AttentionError(
        payload['scope']?.toString() ?? 'injected',
        fatal: payload['fatal'] as bool? ?? true,
      );
    case 'VisionDegraded':
      return const VisionDegraded();
    case 'VisionRecovered':
      return const VisionRecovered();
    case 'AnnouncementReady':
      final text = payload['text']?.toString() ?? '';
      if (text.isEmpty) return null;
      return AnnouncementReady(
        id: payload['id']?.toString() ?? 'inject',
        text: text,
        audioUrl: payload['audioUrl']?.toString() ?? '',
      );
    case 'EnqueueAnnouncement':
      // Handled specially in _handleInject when present — fall through null.
      return null;
    default:
      return null;
  }
}
