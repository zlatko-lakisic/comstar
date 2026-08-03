import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:comstar_bridge/log.dart';

/// Speech-to-text client (OpenAI-compatible /v1/audio/transcriptions).
abstract class SttClient {
  Future<String> transcribe(
    Uint8List pcm, {
    int sampleRate = 16000,
  });
}

class HttpSttClient implements SttClient {
  HttpSttClient({
    String? baseUrl,
    http.Client? client,
    this.model = 'whisper-1',
  })  : baseUrl = _normalizeBase(baseUrl ?? Platform.environment['COMSTAR_STT_URL']),
        _client = client ?? http.Client();

  final String? baseUrl;
  final http.Client _client;
  final String model;

  static String? _normalizeBase(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    return raw.replaceAll(RegExp(r'/+$'), '');
  }

  @override
  Future<String> transcribe(
    Uint8List pcm, {
    int sampleRate = 16000,
  }) async {
    if (baseUrl == null) {
      logWarn('stt_unconfigured', 'COMSTAR_STT_URL not set; returning empty');
      return '';
    }

    final uri = Uri.parse('$baseUrl/v1/audio/transcriptions');
    final wav = pcmToWav(pcm, sampleRate: sampleRate);
    final request = http.MultipartRequest('POST', uri)
      ..fields['model'] = model
      ..files.add(
        http.MultipartFile.fromBytes(
          'file',
          wav,
          filename: 'utterance.wav',
        ),
      );

    final span = Span('stt');
    try {
      final streamed = await _client.send(request);
      final body = await streamed.stream.bytesToString();
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        logWarn('stt_error', 'STT HTTP ${streamed.statusCode}', data: {
          'body': body.length > 200 ? '${body.substring(0, 200)}…' : body,
        });
        return '';
      }
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['text'] != null) {
        return decoded['text'].toString().trim();
      }
      return body.trim();
    } catch (e) {
      logWarn('stt_error', e.toString());
      return '';
    } finally {
      span.close();
    }
  }

  void dispose() => _client.close();
}

/// Writes mono s16le PCM into a minimal WAV container for STT upload.
Uint8List pcmToWav(Uint8List pcm, {required int sampleRate}) {
  const channels = 1;
  const bitsPerSample = 16;
  final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
  final blockAlign = channels * bitsPerSample ~/ 8;
  final dataSize = pcm.length;
  final buffer = BytesBuilder();
  buffer.add('RIFF'.codeUnits);
  buffer.add(_le32(36 + dataSize));
  buffer.add('WAVE'.codeUnits);
  buffer.add('fmt '.codeUnits);
  buffer.add(_le32(16));
  buffer.add(_le16(1));
  buffer.add(_le16(channels));
  buffer.add(_le32(sampleRate));
  buffer.add(_le32(byteRate));
  buffer.add(_le16(blockAlign));
  buffer.add(_le16(bitsPerSample));
  buffer.add('data'.codeUnits);
  buffer.add(_le32(dataSize));
  buffer.add(pcm);
  return buffer.toBytes();
}

List<int> _le16(int value) => [value & 0xff, (value >> 8) & 0xff];

List<int> _le32(int value) => [
      value & 0xff,
      (value >> 8) & 0xff,
      (value >> 16) & 0xff,
      (value >> 24) & 0xff,
    ];
