import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:comstar_bridge/log.dart';
import 'package:path/path.dart' as p;

/// First-chunk streaming TTS output.
class TtsChunk {
  const TtsChunk({
    required this.audio,
    this.isFirst = false,
    this.isLast = false,
    this.filePath,
  });

  final Uint8List audio;
  final bool isFirst;
  final bool isLast;
  final String? filePath;
}

abstract class TtsEngine {
  Stream<TtsChunk> synthesize(String text);

  Future<String> synthesizeToFile(String text);
}

/// Writes silence WAV / canned path when Piper is unavailable.
class FakeTts implements TtsEngine {
  FakeTts({
    this.outputDir,
    this.sampleRate = 22050,
    this.durationMs = 800,
  });

  final String? outputDir;
  final int sampleRate;
  final int durationMs;

  @override
  Stream<TtsChunk> synthesize(String text) async* {
    final file = await synthesizeToFile(text);
    final bytes = await File(file).readAsBytes();
    yield TtsChunk(audio: bytes, isFirst: true, isLast: true, filePath: file);
  }

  @override
  Future<String> synthesizeToFile(String text) async {
    final dir = outputDir ?? Directory.systemTemp.createTempSync('comstar-tts').path;
    Directory(dir).createSync(recursive: true);
    final safe = text.hashCode.abs().toRadixString(16);
    final path = p.join(dir, 'fake_$safe.wav');
    final file = File(path);
    if (!file.existsSync()) {
      await file.writeAsBytes(_silenceWav(sampleRate: sampleRate, durationMs: durationMs));
    }
    return path;
  }

  static Uint8List _silenceWav({
    required int sampleRate,
    required int durationMs,
  }) {
    final samples = sampleRate * durationMs ~/ 1000;
    final pcm = Uint8List(samples * 2);
    final dataSize = pcm.length;
    final buffer = BytesBuilder();
    buffer.add('RIFF'.codeUnits);
    buffer.add(_le32(36 + dataSize));
    buffer.add('WAVE'.codeUnits);
    buffer.add('fmt '.codeUnits);
    buffer.add(_le32(16));
    buffer.add(_le16(1));
    buffer.add(_le16(1));
    buffer.add(_le32(sampleRate));
    buffer.add(_le32(sampleRate * 2));
    buffer.add(_le16(2));
    buffer.add(_le16(16));
    buffer.add('data'.codeUnits);
    buffer.add(_le32(dataSize));
    buffer.add(pcm);
    return buffer.toBytes();
  }
}

List<int> _le16(int value) => [value & 0xff, (value >> 8) & 0xff];

List<int> _le32(int value) => [
      value & 0xff,
      (value >> 8) & 0xff,
      (value >> 16) & 0xff,
      (value >> 24) & 0xff,
    ];

/// Piper subprocess TTS with FakeTts fallback.
class PiperTts implements TtsEngine {
  PiperTts({
    required this.voice,
    this.piperBinary = 'piper',
    this.outputDir,
    FakeTts? fallback,
  }) : _fallback = fallback ?? FakeTts(outputDir: outputDir);

  final String voice;
  final String piperBinary;
  final String? outputDir;
  final FakeTts _fallback;

  bool? _piperAvailable;

  Future<bool> _ensurePiper() async {
    if (_piperAvailable != null) return _piperAvailable!;
    try {
      final result = await Process.run(
        piperBinary,
        ['--version'],
        environment: {
          ...Platform.environment,
          'LD_LIBRARY_PATH':
              '/opt/comstar/bin${Platform.environment['LD_LIBRARY_PATH'] != null ? ':${Platform.environment['LD_LIBRARY_PATH']}' : ''}',
          'PATH':
              '/opt/comstar/bin:/usr/local/bin:/usr/bin:/bin${Platform.environment['PATH'] != null ? ':${Platform.environment['PATH']}' : ''}',
        },
      );
      _piperAvailable = result.exitCode == 0;
    } on Object {
      _piperAvailable = false;
    }
    if (_piperAvailable != true) {
      logWarn('tts_piper_missing', 'Piper not found; using FakeTts');
    }
    return _piperAvailable!;
  }

  @override
  Stream<TtsChunk> synthesize(String text) async* {
    final path = await synthesizeToFile(text);
    final bytes = await File(path).readAsBytes();
    yield TtsChunk(audio: bytes, isFirst: true, isLast: true, filePath: path);
  }

  @override
  Future<String> synthesizeToFile(String text) async {
    if (!await _ensurePiper()) {
      return _fallback.synthesizeToFile(text);
    }

    final dir = outputDir ?? Directory.systemTemp.createTempSync('comstar-tts').path;
    Directory(dir).createSync(recursive: true);
    final safe = text.hashCode.abs().toRadixString(16);
    final outPath = p.join(dir, 'piper_$safe.wav');

    final span = Span('tts_total');
    try {
      final process = await Process.start(
        piperBinary,
        [
          '--model',
          voice,
          '--output_file',
          outPath,
        ],
        environment: {
          ...Platform.environment,
          'LD_LIBRARY_PATH':
              '/opt/comstar/bin${Platform.environment['LD_LIBRARY_PATH'] != null ? ':${Platform.environment['LD_LIBRARY_PATH']}' : ''}',
          'PATH':
              '/opt/comstar/bin:/usr/local/bin:/usr/bin:/bin${Platform.environment['PATH'] != null ? ':${Platform.environment['PATH']}' : ''}',
        },
      );
      process.stdin.write(text);
      await process.stdin.close();
      final exitCode = await process.exitCode;
      if (exitCode != 0 || !File(outPath).existsSync()) {
        logWarn('tts_piper_failed', 'piper exit $exitCode');
        return _fallback.synthesizeToFile(text);
      }
      return outPath;
    } catch (e) {
      logWarn('tts_piper_failed', e.toString());
      return _fallback.synthesizeToFile(text);
    } finally {
      span.close();
    }
  }
}

TtsEngine createTtsEngine({
  required String engine,
  required String piperVoice,
  String? outputDir,
}) {
  if (engine == 'piper') {
    return PiperTts(voice: piperVoice, outputDir: outputDir);
  }
  return FakeTts(outputDir: outputDir);
}
