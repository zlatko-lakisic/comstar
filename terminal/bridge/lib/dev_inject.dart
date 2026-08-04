import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:comstar_bridge/attention/coordinator.dart';
import 'package:comstar_bridge/attention/events.dart';
import 'package:comstar_bridge/log.dart';

/// Dev-only HTTP endpoint for injecting attention events (POST /inject on :8779).
class DevInjectServer {
  DevInjectServer({
    required this.coordinator,
    this.port = 8779,
  });

  final AttentionCoordinator coordinator;
  final int port;

  HttpServer? _server;

  static bool get enabled => Platform.environment['COMSTAR_ENV'] == 'dev';

  Future<void> start() async {
    if (!enabled) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    logInfo('dev_inject_started', 'Dev inject server listening', data: {
      'port': port,
    });
    unawaited(_server!.listen(_handleRequest).asFuture());
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.method == 'GET' && request.uri.path == '/health') {
      await _writeJson(request, 200, {'ok': true});
      return;
    }

    if (request.method != 'POST' || request.uri.path != '/inject') {
      await _writeJson(request, 404, {'error': 'not_found'});
      return;
    }

    final body = await utf8.decodeStream(request);
    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(body) as Map<String, dynamic>;
    } on Object {
      await _writeJson(request, 400, {'error': 'invalid_json'});
      return;
    }

    final eventName = payload['event']?.toString();
    if (eventName == null || eventName.isEmpty) {
      await _writeJson(request, 400, {'error': 'missing_event'});
      return;
    }

    final event = parseInjectEvent(eventName, payload);
    if (event == null) {
      await _writeJson(request, 400, {
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

  Future<void> _writeJson(
    HttpRequest request,
    int status,
    Map<String, Object?> body,
  ) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
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
    default:
      return null;
  }
}
