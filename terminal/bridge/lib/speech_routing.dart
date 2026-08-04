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
///
/// Pin better Ada sidecars via [ReachConnectionConfig.speechSttBaseUrlOverride]
/// (see [speechSttOverrideFromEnv]), not by bypassing Reach.
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
        final detailed = await speech.transcribeDetailed(wav);
        final reject = sttConfidenceRejectReason(detailed);
        if (reject != null) {
          logInfo('stt_low_confidence', 'Dropping low-confidence transcript', data: {
            'reason': reject,
            'avg_logprob': detailed.avgLogprob,
            'no_speech_prob': detailed.noSpeechProb,
            'chars': detailed.text.trim().length,
          });
          return '';
        }
        final text = detailed.text.trim();
        logDebug('stt_reach', 'Transcribed via Reach SpeechClient', data: {
          'chars': text.length,
          'avg_logprob': detailed.avgLogprob,
          'no_speech_prob': detailed.noSpeechProb,
          'stt': speech.capabilities.sttBaseUrl,
        });
        return text;
      } finally {
        span.close();
      }
    } catch (e) {
      logWarn('stt_reach_failed', e.toString());
      return fallback.transcribe(pcm, sampleRate: sampleRate);
    }
  }

  void dispose() {
    final fb = fallback;
    if (fb is HttpSttClient) {
      fb.dispose();
    }
  }
}

/// Prefers Reach-advertised TTS when present; otherwise [fallback].
///
/// Pin lessac-high (etc.) via [ReachConnectionConfig.speechTtsBaseUrlOverride]
/// (see [speechTtsOverrideFromEnv]).
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
          'tts': speech.capabilities.ttsBaseUrl,
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

/// When fields are present, reject obvious non-speech / low-quality STT.
/// Missing fields → no confidence signal (do not reject).
String? sttConfidenceRejectReason(TranscriptionResult result) {
  final noSpeech = result.noSpeechProb;
  if (noSpeech != null && noSpeech >= 0.6) {
    return 'no_speech_prob';
  }
  final logprob = result.avgLogprob;
  if (logprob != null && logprob < -1.0) {
    return 'avg_logprob';
  }
  return null;
}

bool _envFlag(String key) {
  final v = Platform.environment[key]?.trim().toLowerCase();
  return v == '1' || v == 'true' || v == 'yes';
}

String? _nonEmptyEnv(String key) {
  final v = Platform.environment[key]?.trim();
  if (v == null || v.isEmpty) return null;
  return v.replaceAll(RegExp(r'/+$'), '');
}

/// `COMSTAR_STT_OVERRIDE`, or `COMSTAR_STT_URL` when `COMSTAR_SPEECH_OVERRIDE=1`.
String? speechSttOverrideFromEnv() {
  final dedicated = _nonEmptyEnv('COMSTAR_STT_OVERRIDE');
  if (dedicated != null) return dedicated;
  if (_envFlag('COMSTAR_SPEECH_OVERRIDE')) {
    return _nonEmptyEnv('COMSTAR_STT_URL');
  }
  return null;
}

/// `COMSTAR_TTS_OVERRIDE`, or `COMSTAR_TTS_URL` when `COMSTAR_SPEECH_OVERRIDE=1`.
String? speechTtsOverrideFromEnv() {
  final dedicated = _nonEmptyEnv('COMSTAR_TTS_OVERRIDE');
  if (dedicated != null) return dedicated;
  if (_envFlag('COMSTAR_SPEECH_OVERRIDE')) {
    return _nonEmptyEnv('COMSTAR_TTS_URL');
  }
  return null;
}

/// Optional bearer for AO speech sidecars (`AGENTIC_SPEECH_TOKEN`).
String? speechTokenFromEnv() {
  final comstar = Platform.environment['COMSTAR_SPEECH_TOKEN']?.trim();
  if (comstar != null && comstar.isNotEmpty) return comstar;
  final agentic = Platform.environment['AGENTIC_SPEECH_TOKEN']?.trim();
  if (agentic != null && agentic.isNotEmpty) return agentic;
  return null;
}
