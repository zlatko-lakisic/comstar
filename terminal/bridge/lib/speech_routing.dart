import 'dart:io';
import 'dart:typed_data';

import 'package:ao_reach/ao_reach.dart';
import 'package:comstar_bridge/log.dart';
import 'package:comstar_bridge/stt.dart';
import 'package:comstar_bridge/tts.dart';
import 'package:path/path.dart' as p;

/// Resolves the active AO [SpeechClient] (null when Reach has no speech).
typedef SpeechClientLookup = SpeechClient? Function();

/// Prefers Reach-advertised STT when present; otherwise [fallback].
class PreferReachSttClient implements SttClient {
  PreferReachSttClient({
    required this.speechClientOf,
    SttClient? fallback,
  }) : fallback = fallback ?? HttpSttClient();

  final SpeechClientLookup speechClientOf;
  final SttClient fallback;

  @override
  Future<String> transcribe(
    Uint8List pcm, {
    int sampleRate = 16000,
  }) async {
    final speech = speechClientOf();
    if (speech == null) {
      return fallback.transcribe(pcm, sampleRate: sampleRate);
    }

    final wav = pcmToWav(pcm, sampleRate: sampleRate);
    try {
      final span = Span('stt');
      try {
        final text = await speech.transcribe(wav);
        logDebug('stt_reach', 'Transcribed via Reach SpeechClient', data: {
          'chars': text.length,
        });
        return text.trim();
      } finally {
        span.close();
      }
    } catch (e) {
      logWarn('stt_reach_failed', e.toString());
      return fallback.transcribe(pcm, sampleRate: sampleRate);
    }
  }
}

/// Prefers Reach-advertised TTS when present; otherwise [fallback].
class PreferReachTts implements TtsEngine {
  PreferReachTts({
    required this.speechClientOf,
    required this.fallback,
    this.outputDir,
  });

  final SpeechClientLookup speechClientOf;
  final TtsEngine fallback;
  final String? outputDir;

  @override
  Stream<TtsChunk> synthesize(String text) async* {
    final path = await synthesizeToFile(text);
    final bytes = await File(path).readAsBytes();
    yield TtsChunk(audio: bytes, isFirst: true, isLast: true, filePath: path);
  }

  @override
  Future<String> synthesizeToFile(String text) async {
    final speech = speechClientOf();
    if (speech == null) {
      return fallback.synthesizeToFile(text);
    }

    try {
      final span = Span('tts_total');
      try {
        final bytes = await speech.synthesize(text);
        final dir =
            outputDir ?? Directory.systemTemp.createTempSync('comstar-tts').path;
        Directory(dir).createSync(recursive: true);
        final safe = text.hashCode.abs().toRadixString(16);
        final path = p.join(dir, 'reach_$safe.wav');
        await File(path).writeAsBytes(bytes);
        logDebug('tts_reach', 'Synthesized via Reach SpeechClient', data: {
          'bytes': bytes.length,
        });
        return path;
      } finally {
        span.close();
      }
    } catch (e) {
      logWarn('tts_reach_failed', e.toString());
      return fallback.synthesizeToFile(text);
    }
  }
}

/// Optional bearer for AO speech sidecars (`AGENTIC_SPEECH_TOKEN`).
String? speechTokenFromEnv() {
  final comstar = Platform.environment['COMSTAR_SPEECH_TOKEN']?.trim();
  if (comstar != null && comstar.isNotEmpty) return comstar;
  final agentic = Platform.environment['AGENTIC_SPEECH_TOKEN']?.trim();
  if (agentic != null && agentic.isNotEmpty) return agentic;
  return null;
}
