import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/log.dart';
import 'package:comstar_bridge/vision/models.dart';
import 'package:http/http.dart' as http;

/// HTTP client for CodeProject.AI vision endpoints (CONTRACTS §3).
class CpaiClient {
  CpaiClient({
    required this.config,
    http.Client? httpClient,
    this.detectionTimeout = const Duration(milliseconds: 2000),
    this.recognizeTimeout = const Duration(milliseconds: 3000),
  }) : _http = httpClient ?? http.Client();

  final VisionConfig config;
  final http.Client _http;
  final Duration detectionTimeout;
  final Duration recognizeTimeout;

  int _consecutiveFailures = 0;
  bool _degraded = false;

  final _degradedController = StreamController<bool>.broadcast();

  Stream<bool> get degradedStream => _degradedController.stream;
  bool get isDegraded => _degraded;
  int get consecutiveFailures => _consecutiveFailures;

  Uri get _baseUri => Uri.parse(config.codeprojectUrl);

  Future<List<Detection>> detectPerson(Uint8List frame) async {
    try {
      final uri = _baseUri.replace(path: config.detectionEndpoint);
      final request = http.MultipartRequest('POST', uri)
        ..fields['min_confidence'] = config.personConfidence.toString()
        ..files.add(http.MultipartFile.fromBytes('image', frame, filename: 'frame.jpg'));

      final streamed = await _http.send(request).timeout(detectionTimeout);
      final body = await streamed.stream.bytesToString();
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        _recordFailure('detect_http_${streamed.statusCode}');
        return const [];
      }

      final json = jsonDecode(body);
      if (json is! Map<String, dynamic> || json['success'] != true) {
        _recordFailure('detect_unsuccessful');
        return const [];
      }

      _recordSuccess();
      return _parseDetections(json);
    } catch (e) {
      _recordFailure('detect_error');
      return const [];
    }
  }

  Future<List<FaceMatch>> recognizeFace(Uint8List frame) async {
    try {
      final uri = _baseUri.replace(path: config.recognizeEndpoint);
      final request = http.MultipartRequest('POST', uri)
        ..fields['min_confidence'] = config.faceConfidence.toString()
        ..files.add(http.MultipartFile.fromBytes('image', frame, filename: 'frame.jpg'));

      final streamed = await _http.send(request).timeout(recognizeTimeout);
      final body = await streamed.stream.bytesToString();
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        _recordFailure('recognize_http_${streamed.statusCode}');
        return const [];
      }

      final json = jsonDecode(body);
      if (json is! Map<String, dynamic> || json['success'] != true) {
        _recordFailure('recognize_unsuccessful');
        return const [];
      }

      _recordSuccess();
      return _parseFaceMatches(json);
    } catch (e) {
      _recordFailure('recognize_error');
      return const [];
    }
  }

  List<Detection> parseDetectionResponse(Map<String, dynamic> json) =>
      _parseDetections(json);

  List<FaceMatch> parseRecognizeResponse(Map<String, dynamic> json) =>
      _parseFaceMatches(json);

  void _recordFailure(String reason) {
    _consecutiveFailures++;
    logWarn('cpai_failure', 'CPAI request failed', data: {
      'reason': reason,
      'consecutive': _consecutiveFailures,
    });
    if (_consecutiveFailures >= 3 && !_degraded) {
      _degraded = true;
      _degradedController.add(true);
      logWarn('vision.degraded', 'Vision degraded after consecutive failures');
    }
  }

  void _recordSuccess() {
    final wasDegraded = _degraded;
    _consecutiveFailures = 0;
    _degraded = false;
    if (wasDegraded) {
      _degradedController.add(false);
      logInfo('vision.recovered', 'Vision recovered');
    }
  }

  List<Detection> _parseDetections(Map<String, dynamic> json) {
    final predictions = json['predictions'];
    if (predictions is! List) return const [];

    final out = <Detection>[];
    for (final raw in predictions) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final label = map['label']?.toString() ?? '';
      final confidence = _asDouble(map['confidence']);
      out.add(
        Detection(
          label: label,
          confidence: confidence,
          xMin: _asInt(map['x_min']),
          yMin: _asInt(map['y_min']),
          xMax: _asInt(map['x_max']),
          yMax: _asInt(map['y_max']),
        ),
      );
    }
    return out;
  }

  List<FaceMatch> _parseFaceMatches(Map<String, dynamic> json) {
    final predictions = json['predictions'];
    if (predictions is! List || predictions.isEmpty) return const [];

    final out = <FaceMatch>[];
    for (final raw in predictions) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      out.add(
        FaceMatch(
          userid: map['userid']?.toString() ?? '',
          confidence: _asDouble(map['confidence']),
          xMin: _asInt(map['x_min']),
          yMin: _asInt(map['y_min']),
          xMax: _asInt(map['x_max']),
          yMax: _asInt(map['y_max']),
        ),
      );
    }
    return out;
  }

  double _asDouble(Object? value) {
    if (value is num) return value.toDouble();
    return 0;
  }

  int _asInt(Object? value) {
    if (value is num) return value.toInt();
    return 0;
  }

  void dispose() {
    _degradedController.close();
    _http.close();
  }
}
