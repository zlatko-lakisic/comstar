import 'dart:typed_data';

import 'package:comstar_bridge/tts.dart';
import 'package:comstar_bridge/wav_duration.dart';
import 'package:test/test.dart';

void main() {
  test('wavDurationMsFromBytes reads FakeTts silence length', () async {
    final tts = FakeTts(durationMs: 2500, sampleRate: 16000);
    final path = await tts.synthesizeToFile('x');
    final ms = wavDurationMs(path);
    expect(ms, isNotNull);
    expect(ms!, closeTo(2500, 50));
  });

  test('wavDurationMsFromBytes rejects non-wav', () {
    expect(wavDurationMsFromBytes(Uint8List.fromList([1, 2, 3])), isNull);
  });

  test('estimateSpeechMs scales with text', () {
    expect(estimateSpeechMs(''), 1500);
    expect(estimateSpeechMs('a' * 125), 10000);
  });
}
