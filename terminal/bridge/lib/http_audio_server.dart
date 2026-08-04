import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'package:comstar_bridge/log.dart';
import 'package:comstar_bridge/terminal_control.dart';

/// Loopback HTTP server for TTS WAVs, kiosk assets, and terminal control.
class HttpAudioServer {
  HttpAudioServer({
    this.host = '127.0.0.1',
    this.port = 8776,
    this.kioskRoot,
    this.control,
    this.onSleepAction,
  });

  final String host;
  final int port;

  /// Directory containing `index.html` / `avatar.js` / `bridge_client.js`.
  final String? kioskRoot;

  /// Speaker volume + soft soft-state (CONTRACTS §5).
  TerminalControl? control;

  /// Called for sleep enter/exit so the attention machine can transition.
  /// Returns true if the action was accepted.
  Future<bool> Function(String action)? onSleepAction;

  /// Live avatar tuning — push options to the kiosk over WS.
  /// Returns the applied option map (echo) or null on failure.
  Future<Map<String, dynamic>?> Function(Map<String, dynamic> options)?
      onAvatarOptions;

  /// Last options accepted via `/control/avatar` (for GET).
  Map<String, dynamic> _avatarOptions = const {
    'bloom': 3,
    'fps': 12,
    'scale': 0.62,
  };

  HttpServer? _server;
  final _files = <String, String>{};

  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    final handler = Pipeline().addHandler(_handle);

    _server = await shelf_io.serve(
      handler,
      InternetAddress(host),
      port,
      shared: true,
    );
    logInfo('audio_http_started', 'TTS HTTP server listening', data: {
      'host': host,
      'port': port,
      if (kioskRoot != null) 'kiosk_root': kioskRoot,
    });
  }

  Future<Response> _handle(Request request) async {
    final path = request.url.path;

    if (path == 'control/sleep' || path == 'control/volume' || path == 'control/avatar') {
      return _handleControl(request, path);
    }

    if (request.method != 'GET') {
      return Response(405, body: 'Method not allowed');
    }

    if (path == 'kiosk' || path.startsWith('kiosk/')) {
      logDebug('kiosk_http', 'serve', data: {'path': path});
      return _serveKiosk(path);
    }

    final id = p.basename(path);
    if (id.isEmpty || id == '/') {
      return Response(404, body: 'Not found');
    }
    final filePath = _files[id];
    if (filePath == null || !File(filePath).existsSync()) {
      return Response(404, body: 'Not found');
    }
    final bytes = await File(filePath).readAsBytes();
    return Response.ok(
      bytes,
      headers: {
        'Content-Type': 'audio/wav',
        'Cache-Control': 'no-store',
      },
    );
  }

  Future<Response> _handleControl(Request request, String path) async {
    if (path == 'control/avatar') {
      return _handleAvatarControl(request);
    }

    final ctrl = control;
    if (ctrl == null) {
      return _json(503, {'ok': false, 'error': 'control_unavailable'});
    }

    if (path == 'control/sleep') {
      if (request.method == 'GET') {
        return _json(200, ctrl.sleepStatus());
      }
      if (request.method != 'POST') {
        return Response(405, body: 'Method not allowed');
      }
      final body = await _readJson(request);
      final action = (body['action'] ?? 'enter').toString();
      if (action != 'enter' && action != 'exit') {
        return _json(400, {'ok': false, 'error': 'bad_action'});
      }
      final hook = onSleepAction;
      if (hook != null) {
        final ok = await hook(action);
        if (!ok) {
          return _json(500, {'ok': false, 'error': 'sleep_action_failed'});
        }
      } else if (action == 'enter') {
        ctrl.sleepEnter();
      } else {
        ctrl.sleepExit();
      }
      return _json(
        200,
        action == 'enter'
            ? {'ok': true, 'state': 'sleeping'}
            : {'ok': true, 'state': 'awake'},
      );
    }

    // control/volume
    if (request.method == 'GET') {
      return _json(200, ctrl.volumeGet());
    }
    if (request.method != 'POST') {
      return Response(405, body: 'Method not allowed');
    }
    final body = await _readJson(request);
    final action = (body['action'] ?? 'set').toString();
    Map<String, dynamic> result;
    switch (action) {
      case 'get':
        result = ctrl.volumeGet();
      case 'set':
        final percent = body['percent'];
        if (percent is! num) {
          return _json(400, {'ok': false, 'error': 'percent_required'});
        }
        result = ctrl.volumeSet(percent.toInt());
      case 'adjust':
        final delta = body['delta'];
        if (delta is! num) {
          return _json(400, {'ok': false, 'error': 'delta_required'});
        }
        result = ctrl.volumeAdjust(delta.toInt());
      case 'mute':
        final muted = body['muted'];
        if (muted is! bool) {
          return _json(400, {'ok': false, 'error': 'muted_required'});
        }
        result = ctrl.volumeMute(muted);
      default:
        return _json(400, {'ok': false, 'error': 'bad_action'});
    }
    return _json(result['ok'] == true ? 200 : 500, result);
  }

  Future<Response> _handleAvatarControl(Request request) async {
    if (request.method == 'GET') {
      return _json(200, {'ok': true, ..._avatarOptions});
    }
    if (request.method != 'POST') {
      return Response(405, body: 'Method not allowed');
    }
    final body = await _readJson(request);
    final next = Map<String, dynamic>.from(_avatarOptions);
    void takeNum(String key, {String? alias, double? min, double? max}) {
      final raw = body[key] ?? (alias != null ? body[alias] : null);
      if (raw is! num) return;
      var v = raw.toDouble();
      if (min != null) v = v < min ? min : v;
      if (max != null) v = v > max ? max : v;
      next[key] = v;
    }

    takeNum('bloom', min: 0, max: 24);
    takeNum('fps', alias: 'maxFps', min: 8, max: 60);
    takeNum('scale', alias: 'emblemScale', min: 0.2, max: 1.2);
    final emblem = body['emblem'];
    if (emblem != null && emblem.toString().trim().isNotEmpty) {
      next['emblem'] = emblem.toString().trim();
    }

    final hook = onAvatarOptions;
    if (hook != null) {
      final applied = await hook(next);
      if (applied == null) {
        return _json(503, {'ok': false, 'error': 'kiosk_unavailable'});
      }
      _avatarOptions = Map<String, dynamic>.from(applied);
    } else {
      _avatarOptions = next;
    }
    logInfo('avatar_options', 'Avatar options updated', data: _avatarOptions);
    return _json(200, {'ok': true, ..._avatarOptions});
  }

  Future<Map<String, dynamic>> _readJson(Request request) async {
    try {
      final raw = await request.readAsString();
      if (raw.trim().isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (_) {}
    return {};
  }

  Response _json(int status, Map<String, dynamic> body) => Response(
        status,
        body: jsonEncode(body),
        headers: {'Content-Type': 'application/json'},
      );

  Future<Response> _serveKiosk(String urlPath) async {
    final root = kioskRoot;
    if (root == null) {
      return Response(404, body: 'kiosk root not configured');
    }
    var rel = urlPath == 'kiosk' || urlPath == 'kiosk/'
        ? 'index.html'
        : urlPath.substring('kiosk/'.length);
    if (rel.isEmpty) rel = 'index.html';
    // Prevent path escape.
    if (rel.contains('..')) {
      return Response(400, body: 'bad path');
    }
    final file = File(p.join(root, rel));
    if (!file.existsSync()) {
      return Response(404, body: 'Not found');
    }
    final bytes = await file.readAsBytes();
    return Response.ok(
      bytes,
      headers: {
        'Content-Type': _contentType(rel),
        'Cache-Control': 'no-cache',
      },
    );
  }

  String _contentType(String name) {
    if (name.endsWith('.html')) return 'text/html; charset=utf-8';
    if (name.endsWith('.js')) return 'text/javascript; charset=utf-8';
    if (name.endsWith('.css')) return 'text/css; charset=utf-8';
    if (name.endsWith('.json')) return 'application/json';
    if (name.endsWith('.svg')) return 'image/svg+xml';
    return 'application/octet-stream';
  }

  /// Registers [filePath] and returns the loopback URL for the kiosk.
  String registerFile(String filePath) {
    final id = p.basename(filePath);
    _files[id] = filePath;
    return 'http://$host:$port/$id';
  }

  /// Looks up a registered file by basename or full URL path segment.
  String? filePathForUrl(String audioUrl) {
    final id = p.basename(Uri.parse(audioUrl).path);
    return _files[id];
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }
}
