import 'dart:convert';
import 'dart:io';

import 'package:ao_reach/ao_reach.dart';
import 'package:path/path.dart' as p;

import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/log.dart';

/// AO Reach mTLS pairing (ADR 0013) — enroll / clear / probe.
class AoMtlsService {
  AoMtlsService({
    required this.config,
    ReachMtlsEnroller? enroller,
    Future<ProcessResult> Function(String executable, List<String> arguments)?
        runProcess,
  })  : _enroller = enroller ?? ReachMtlsEnroller(),
        _runProcess = runProcess ??
            ((exe, args) => Process.run(exe, args, runInShell: false));

  final ComstarConfig config;
  final ReachMtlsEnroller _enroller;
  final Future<ProcessResult> Function(String executable, List<String> arguments)
      _runProcess;

  String? _lastError;

  OrchestrationMtlsConfig get mtls => config.orchestration.mtls;

  String get materialDir => mtls.resolvedMaterialDir();

  static bool materialPresent(String dir) {
    final cert = File(p.join(dir, 'cert.pem'));
    final key = File(p.join(dir, 'key.pem'));
    final ca = File(p.join(dir, 'ca.pem'));
    return cert.existsSync() &&
        key.existsSync() &&
        ca.existsSync() &&
        cert.lengthSync() > 0 &&
        key.lengthSync() > 0 &&
        ca.lengthSync() > 0;
  }

  Future<bool> opensslOk() async {
    try {
      final r = await _runProcess('openssl', ['version']);
      return r.exitCode == 0;
    } on Object {
      return false;
    }
  }

  Map<String, dynamic>? _readMeta() {
    final f = File(p.join(materialDir, 'meta.json'));
    if (!f.existsSync()) return null;
    try {
      final decoded = jsonDecode(f.readAsStringSync());
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } on Object {
      // ignore corrupt meta
    }
    return null;
  }

  Future<void> _writeMeta({
    required String clientName,
    String? subject,
    double? expiresAt,
  }) async {
    final dir = Directory(materialDir);
    await dir.create(recursive: true);
    final meta = <String, dynamic>{
      'client_name': clientName,
      'enrolled_at': DateTime.now().toUtc().toIso8601String(),
      if (subject != null && subject.isNotEmpty) 'subject': subject,
      if (expiresAt != null) 'expires_at': expiresAt,
    };
    final f = File(p.join(materialDir, 'meta.json'));
    await f.writeAsString('${const JsonEncoder.withIndent('  ').convert(meta)}\n',
        flush: true);
  }

  Future<Map<String, dynamic>> inspect() async {
    final meta = _readMeta();
    final paired = materialPresent(materialDir);
    return {
      'ok': true,
      'enabled': mtls.enabled,
      'base_url': config.orchestration.baseUrl,
      'material_dir': materialDir,
      'paired': paired,
      'client_name': meta?['client_name']?.toString() ??
          (mtls.clientName.trim().isNotEmpty ? mtls.clientName.trim() : null),
      'subject': meta?['subject'],
      'expires_at': meta?['expires_at'],
      'enrolled_at': meta?['enrolled_at'],
      'openssl_ok': await opensslOk(),
      'last_error': _lastError,
    };
  }

  Future<Map<String, dynamic>> enroll({
    required String enrollToken,
    String? clientName,
  }) async {
    final token = enrollToken.trim();
    if (token.isEmpty) {
      throw ArgumentError('enroll_token is required');
    }
    final base = config.orchestration.baseUrl.replaceAll(RegExp(r'/+$'), '');
    assertReachMtlsUsesTls(base);

    final cn = (clientName?.trim().isNotEmpty ?? false)
        ? clientName!.trim()
        : (mtls.clientName.trim().isNotEmpty
            ? mtls.clientName.trim()
            : (Platform.localHostname.trim().isNotEmpty
                ? Platform.localHostname.trim()
                : 'comstar-terminal'));

    logInfo('ao_mtls_enroll', 'Enrolling AO mTLS client cert', data: {
      'base_url': base,
      'material_dir': materialDir,
      'client_name': cn,
    });

    try {
      final material = await _enroller.enroll(
        baseUrl: base,
        enrollToken: token,
        materialDir: materialDir,
        commonName: cn,
        trustEnrollmentCa: mtls.trustEnrollmentCa,
      );
      await _writeMeta(
        clientName: cn,
        subject: material.subject,
        expiresAt: material.expiresAt,
      );
      _lastError = null;
      logInfo('ao_mtls_enrolled', 'AO mTLS material saved', data: {
        'material_dir': materialDir,
        'client_name': cn,
        'subject': material.subject,
        'expires_at': material.expiresAt,
      });
      return {
        'ok': true,
        'action': 'enroll',
        ...(await inspect()),
      };
    } on Object catch (e) {
      _lastError = e.toString();
      logError('ao_mtls_enroll_fail', 'AO mTLS enroll failed', data: {
        'error': e.toString(),
      });
      rethrow;
    }
  }

  Future<Map<String, dynamic>> clear() async {
    final dir = materialDir;
    for (final name in ['cert.pem', 'key.pem', 'ca.pem', 'meta.json']) {
      final f = File(p.join(dir, name));
      if (f.existsSync()) {
        try {
          f.deleteSync();
        } on Object catch (e) {
          _lastError = e.toString();
          throw StateError('failed to delete ${f.path}: $e');
        }
      }
    }
    _lastError = null;
    logInfo('ao_mtls_cleared', 'AO mTLS material cleared', data: {
      'material_dir': dir,
    });
    return {
      'ok': true,
      'action': 'clear',
      ...(await inspect()),
    };
  }

  Future<Map<String, dynamic>> probe() async {
    final base = config.orchestration.baseUrl.replaceAll(RegExp(r'/+$'), '');
    if (!materialPresent(materialDir)) {
      throw StateError('not paired — enroll first');
    }
    assertReachMtlsUsesTls(base);
    final material =
        loadReachMtlsMaterial(ReachMtlsConfig(materialDir: materialDir));
    final client = reachMtlsHttpClient(material);
    try {
      final uri = Uri.parse('$base/health');
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final res = await req.close().timeout(const Duration(seconds: 10));
      final body = await res.transform(utf8.decoder).join();
      final ok = res.statusCode >= 200 && res.statusCode < 300;
      if (!ok) {
        _lastError = 'probe HTTP ${res.statusCode}';
      } else {
        _lastError = null;
      }
      return {
        'ok': ok,
        'action': 'probe',
        'status_code': res.statusCode,
        'body_preview': body.length > 200 ? body.substring(0, 200) : body,
        ...(await inspect()),
      };
    } on Object catch (e) {
      _lastError = e.toString();
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> handleAction(Map<String, dynamic> body) async {
    final action = (body['action'] ?? '').toString().trim();
    switch (action) {
      case 'enroll':
        return enroll(
          enrollToken: (body['enroll_token'] ?? body['token'] ?? '').toString(),
          clientName: body['client_name']?.toString(),
        );
      case 'clear':
        return clear();
      case 'probe':
        return probe();
      default:
        throw ArgumentError('unknown action: $action');
    }
  }
}
