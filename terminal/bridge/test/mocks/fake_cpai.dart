import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// In-process HTTP server serving CPAI fixture JSON for tests.
class FakeCpaiServer {
  FakeCpaiServer({
    this.detectionFixture,
    this.recognizeFixture,
    this.detectionLatency = Duration.zero,
    this.recognizeLatency = Duration.zero,
    this.detectionErrorRate = 0,
    this.recognizeErrorRate = 0,
    this.detectionStatusCode = 200,
    this.recognizeStatusCode = 200,
  });

  final Map<String, dynamic>? detectionFixture;
  final Map<String, dynamic>? recognizeFixture;
  final Duration detectionLatency;
  final Duration recognizeLatency;
  final int detectionErrorRate;
  final int recognizeErrorRate;
  final int detectionStatusCode;
  final int recognizeStatusCode;

  HttpServer? _server;
  late Uri baseUri;
  int _detectionCalls = 0;
  int _recognizeCalls = 0;

  int get detectionCalls => _detectionCalls;
  int get recognizeCalls => _recognizeCalls;

  Future<void> start({String host = '127.0.0.1', int port = 0}) async {
    _server = await HttpServer.bind(host, port);
    final effectivePort = _server!.port;
    baseUri = Uri.parse('http://$host:$effectivePort');

    _server!.listen((request) async {
      if (detectionLatency > Duration.zero) {
        await Future<void>.delayed(detectionLatency);
      }
      if (recognizeLatency > Duration.zero) {
        await Future<void>.delayed(recognizeLatency);
      }

      if (request.uri.path.endsWith('/v1/vision/detection')) {
        _detectionCalls++;
        if (detectionErrorRate > 0 &&
            _detectionCalls % detectionErrorRate == 0) {
          request.response.statusCode = 500;
          request.response.write('error');
        } else {
          request.response.statusCode = detectionStatusCode;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(detectionFixture ?? {}));
        }
      } else if (request.uri.path.endsWith('/v1/vision/face/recognize')) {
        _recognizeCalls++;
        if (recognizeErrorRate > 0 &&
            _recognizeCalls % recognizeErrorRate == 0) {
          request.response.statusCode = 500;
          request.response.write('error');
        } else {
          request.response.statusCode = recognizeStatusCode;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(recognizeFixture ?? {}));
        }
      } else {
        request.response.statusCode = 404;
        request.response.write('not found');
      }
      await request.response.close();
    });
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  void setDetectionFixture(Map<String, dynamic> fixture) {
    // ignore: prefer_final_fields - test helper mutability
    // coverage for scripted sequences handled via constructor re-start
  }
}

/// Minimal JPEG header bytes for fake camera frames.
Uint8List fakeJpegFrame([int seed = 0]) {
  return Uint8List.fromList([
    0xFF,
    0xD8,
    0xFF,
    0xE0,
    seed & 0xFF,
    0xFF,
    0xD9,
  ]);
}

Map<String, dynamic> loadFixture(String relativeFromBridge) {
  final path = relativeFromBridge.startsWith('/')
      ? relativeFromBridge
      : '${Directory.current.path}/$relativeFromBridge';
  final raw = File(path).readAsStringSync();
  return jsonDecode(raw) as Map<String, dynamic>;
}
