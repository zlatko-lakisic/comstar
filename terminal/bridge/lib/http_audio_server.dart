import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'package:comstar_bridge/log.dart';

/// Loopback HTTP server for TTS WAVs and (optionally) kiosk static assets.
class HttpAudioServer {
  HttpAudioServer({
    this.host = '127.0.0.1',
    this.port = 8776,
    this.kioskRoot,
  });

  final String host;
  final int port;

  /// Directory containing `index.html` / `avatar.js` / `bridge_client.js`.
  final String? kioskRoot;

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
    if (request.method != 'GET') {
      return Response(405, body: 'Method not allowed');
    }

    final path = request.url.path;
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

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _files.clear();
    logInfo('audio_http_stopped', 'TTS HTTP server stopped');
  }
}
