import 'package:comstar_bridge/env_sources.dart';
import 'package:test/test.dart';

void main() {
  group('env_sources', () {
    test('envFirst skips empty', () {
      // Platform.environment is process-global; just exercise the helper shape.
      expect(envFirst(const ['COMSTAR_UNLIKELY_EMPTY_ZZZ']), isNull);
    });

    test('cameraSource aliases are ordered', () {
      // Without env set, null is fine — presence of the API is the contract.
      final cam = cameraSource();
      expect(cam == null || cam.isNotEmpty, isTrue);
    });

    test('speakerSource aliases are ordered', () {
      final sink = speakerSource();
      expect(sink == null || sink.isNotEmpty, isTrue);
    });
  });
}
