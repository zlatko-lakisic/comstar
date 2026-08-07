import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// M11.4 — voice and text output constraints stay distinct.
void main() {
  late Directory overlayRoot;

  setUpAll(() {
    final here = Directory.current.path;
    final candidates = [
      p.join(here, 'overlays', 'comstar'),
      p.join(here, '..', 'overlays', 'comstar'),
    ];
    for (final c in candidates) {
      final d = Directory(p.normalize(c));
      if (d.existsSync()) {
        overlayRoot = d;
        return;
      }
    }
    fail('overlays/comstar not found from ${Directory.current.path}');
  });

  Map<String, dynamic> loadYamlMap(String rel) {
    final f = File(p.join(overlayRoot.path, rel));
    expect(f.existsSync(), isTrue, reason: f.path);
    final decoded = loadYaml(f.readAsStringSync());
    expect(decoded, isA<YamlMap>());
    return Map<String, dynamic>.from(decoded as Map);
  }

  test('text_responder uses text_output and not spoken_output', () {
    final agent = loadYamlMap('agent_providers/text_responder.yaml');
    final skills = (agent['skills'] as List).map((e) => '$e').toList();
    expect(skills, contains('text_output'));
    expect(skills, isNot(contains('spoken_output')));
    final prompt = '${agent['system_prompt']}';
    expect(prompt.toLowerCase(), contains('markdown'));
  });

  test('voice_responder uses spoken_output and not text_output', () {
    final agent = loadYamlMap('agent_providers/voice_responder.yaml');
    final skills = (agent['skills'] as List).map((e) => '$e').toList();
    expect(skills, contains('spoken_output'));
    expect(skills, isNot(contains('text_output')));
    final skill = loadYamlMap('agent_skills/spoken_output.yaml');
    final body = '${(skill['content'] as Map)['body']}';
    expect(body.toLowerCase(), contains('no markdown'));
  });

  test('text_output skill allows markdown; spoken forbids it', () {
    final text = loadYamlMap('agent_skills/text_output.yaml');
    final spoken = loadYamlMap('agent_skills/spoken_output.yaml');
    final textBody = '${(text['content'] as Map)['body']}'.toLowerCase();
    final spokenBody = '${(spoken['content'] as Map)['body']}'.toLowerCase();
    expect(textBody, contains('markdown is allowed'));
    expect(spokenBody, contains('no markdown'));
    expect(spokenBody, contains('40 words'));
  });
}
