import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'package:comstar_bridge/log.dart';

/// Loopback HTTP server for TTS WAV files consumed by the kiosk.
class HttpAudioServer {
  HttpAudioServer({
    this.host = '127.0.0.1',
    this.port = 8776,
  });

  final String host;
  final int port;

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
    });
  }

  Future<Response> _handle(Request request) async {
    if (request.method != 'GET') {
      return Response(405, body: 'Method not allowed');
    }
    final id = p.basename(request.url.path);
    if (id.isEmpty || id == '/') {
      return Response(404, body: 'Not found');
    }
    final path = _files[id];
    if (path == null || !File(path).existsSync()) {
      return Response(404, body: 'Not found');
    }
    final bytes = await File(path).readAsBytes();
    return Response.ok(
      bytes,
      headers: {
        'Content-Type': 'audio/wav',
        'Cache-Control': 'no-store',
      },
    );
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
