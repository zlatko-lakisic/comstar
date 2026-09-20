import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:comstar_bridge/log.dart';

/// Loopback wayvnc lifecycle for Admin Live view (WebSocket RFB).
///
/// Starts `wayvnc -w -d` on first subscriber and stops when the last client
/// disconnects. Bound to 127.0.0.1 only — Admin auth gates the bridge proxy.
class WayvncPanel {
  WayvncPanel({
    this.port = 5901,
    this.maxFps = 15,
    this.wayvncPath = 'wayvnc',
    Future<Process> Function(String executable, List<String> arguments,
            {Map<String, String>? environment})?
        processRunner,
    Future<WebSocket> Function(Uri uri)? webSocketConnect,
  })  : processRunner = processRunner ??
            ((exe, args, {environment}) => Process.start(
                  exe,
                  args,
                  environment: environment,
                  includeParentEnvironment: true,
                )),
        webSocketConnect =
            webSocketConnect ?? ((uri) => WebSocket.connect(uri.toString()));

  final int port;
  final int maxFps;
  final String wayvncPath;
  final Future<Process> Function(String executable, List<String> arguments,
      {Map<String, String>? environment}) processRunner;
  final Future<WebSocket> Function(Uri uri) webSocketConnect;

  Process? _proc;
  var _subscribers = 0;
  var _starting = false;
  String? unavailableHint;

  int get subscribers => _subscribers;
  bool get active => _proc != null;

  Future<bool> checkAvailable() async {
    try {
      final r = await Process.run('which', [wayvncPath]);
      if (r.exitCode != 0) {
        unavailableHint = 'Install wayvnc (apt install wayvnc)';
        return false;
      }
      unavailableHint = null;
      return true;
    } on Object {
      unavailableHint = 'Install wayvnc (apt install wayvnc)';
      return false;
    }
  }

  Map<String, Object?> statusMap() => {
        'backend': 'wayvnc',
        'available': unavailableHint == null
            ? true
            : false, // refined by checkAvailable caller
        'ws': '/admin/api/preview/panel.ws',
        'subscribers': _subscribers,
        'running': active,
        if (unavailableHint != null) 'hint': unavailableHint,
      };

  Future<void> attachWebSocket(HttpRequest request) async {
    if (!await checkAvailable()) {
      throw StateError('wayvnc_unavailable');
    }

    // Start wayvnc and open upstream *before* upgrading the browser socket so
    // a failed start returns HTTP 503 instead of a cryptic WS 1006.
    await _ensureStarted();
    WebSocket upstream;
    try {
      upstream = await _connectUpstream();
    } on Object catch (e) {
      logWarn('preview_panel_error', 'wayvnc upstream connect failed', data: {
        'error': e.toString(),
        'port': port,
      });
      await _forceStop();
      request.response.statusCode = HttpStatus.serviceUnavailable;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        '{"ok":false,"error":"wayvnc_upstream","hint":'
        '"wayvnc failed to accept WebSocket — is labwc running?"}',
      );
      await request.response.close();
      return;
    }

    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      await upstream.close();
      throw StateError('upgrade_required');
    }

    WebSocket client;
    try {
      client = await WebSocketTransformer.upgrade(request);
    } on Object {
      await upstream.close();
      await _maybeStop();
      rethrow;
    }

    _subscribers++;
    StreamSubscription<dynamic>? clientSub;
    StreamSubscription<dynamic>? upSub;
    try {
      clientSub = client.listen(
        (data) {
          try {
            upstream.add(data);
          } on Object {
            // upstream gone
          }
        },
        onDone: () => unawaited(upstream.close()),
        onError: (_) => unawaited(upstream.close()),
        cancelOnError: true,
      );
      upSub = upstream.listen(
        (data) {
          try {
            client.add(data);
          } on Object {
            // client gone
          }
        },
        onDone: () => unawaited(client.close()),
        onError: (_) => unawaited(client.close()),
        cancelOnError: true,
      );
      await client.done;
    } on Object catch (e) {
      logWarn('preview_panel_error', 'wayvnc proxy failed', data: {
        'error': e.toString(),
      });
      try {
        await client.close();
      } on Object {
        // ignore
      }
    } finally {
      await clientSub?.cancel();
      await upSub?.cancel();
      try {
        await upstream.close();
      } on Object {
        // ignore
      }
      _subscribers--;
      await _maybeStop();
    }
  }

  Future<WebSocket> _connectUpstream() async {
    Object? last;
    for (var i = 0; i < 20; i++) {
      try {
        return await webSocketConnect(Uri.parse('ws://127.0.0.1:$port/'));
      } on Object catch (e) {
        last = e;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    throw StateError('wayvnc_upstream_refused: $last');
  }

  Future<void> _ensureStarted() async {
    if (_proc != null) {
      await _waitListening();
      return;
    }
    if (_starting) {
      for (var i = 0; i < 50 && _proc == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (_proc != null) {
        await _waitListening();
        return;
      }
    }
    _starting = true;
    final errBuf = StringBuffer();
    try {
      final env = Map<String, String>.from(Platform.environment);
      env.putIfAbsent('WAYLAND_DISPLAY', () => 'wayland-0');
      env.putIfAbsent(
        'XDG_RUNTIME_DIR',
        () => '/run/user/${_uidHint()}',
      );
      final fps = maxFps.clamp(5, 30);
      logInfo('preview_panel_start', 'wayvnc panel preview starting', data: {
        'port': port,
        'fps': fps,
        'websocket': true,
        'view_only': true,
        'wayland': env['WAYLAND_DISPLAY'],
        'runtime_dir': env['XDG_RUNTIME_DIR'],
      });
      final proc = await processRunner(
        wayvncPath,
        [
          '-w',
          '-d', // disable remote input (view-only)
          '-f',
          '$fps',
          '-v',
          '-S',
          '${env['XDG_RUNTIME_DIR']}/comstar-wayvncctl',
          '127.0.0.1',
          '$port',
        ],
        environment: env,
      );
      _proc = proc;
      proc.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(
        (chunk) {
          errBuf.write(chunk);
          if (errBuf.length > 2000) {
            final s = errBuf.toString();
            errBuf
              ..clear()
              ..write(s.substring(s.length - 1500));
          }
        },
        onError: (_) {},
        cancelOnError: true,
      );
      unawaited(proc.exitCode.then((code) {
        if (identical(_proc, proc)) {
          _proc = null;
          final err = errBuf.toString().trim();
          logInfo('preview_panel_stop', 'wayvnc exited', data: {
            'code': code,
            if (err.isNotEmpty) 'stderr': err,
          });
        }
      }));
      await _waitListening();
      // Confirm process still alive after listen.
      if (_proc == null) {
        unavailableHint =
            'wayvnc exited during start${errBuf.isEmpty ? '' : ': ${errBuf.toString().trim()}'}';
        throw StateError('wayvnc_exited');
      }
      unavailableHint = null;
    } on Object catch (e) {
      unavailableHint =
          'Failed to start wayvnc — is labwc/Wayland ready? ($e)';
      final proc = _proc;
      _proc = null;
      if (proc != null) {
        try {
          proc.kill(ProcessSignal.sigkill);
        } on Object {
          // ignore
        }
      }
      rethrow;
    } finally {
      _starting = false;
    }
  }

  Future<void> _waitListening() async {
    Object? last;
    for (var i = 0; i < 40; i++) {
      try {
        final s = await Socket.connect(
          '127.0.0.1',
          port,
          timeout: const Duration(milliseconds: 200),
        );
        await s.close();
        return;
      } on Object catch (e) {
        last = e;
        // If the process already died, fail fast.
        if (_proc == null) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    throw StateError('wayvnc_not_listening: $last');
  }

  Future<void> _maybeStop() async {
    if (_subscribers > 0) return;
    await _forceStop();
  }

  Future<void> _forceStop() async {
    final proc = _proc;
    _proc = null;
    if (proc == null) return;
    logInfo('preview_panel_stop', 'wayvnc panel preview stopped');
    try {
      proc.kill(ProcessSignal.sigterm);
    } on Object {
      // ignore
    }
    try {
      await proc.exitCode.timeout(const Duration(seconds: 2));
    } on Object {
      try {
        proc.kill(ProcessSignal.sigkill);
      } on Object {
        // ignore
      }
    }
  }

  Future<void> dispose() async {
    _subscribers = 0;
    await _forceStop();
  }

  String _uidHint() {
    // Prefer numeric uid from env; fall back to common Pi user.
    final euid = Platform.environment['UID']?.trim();
    if (euid != null && euid.isNotEmpty) return euid;
    return '1000';
  }
}
