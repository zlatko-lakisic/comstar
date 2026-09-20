import 'dart:io';

import 'package:comstar_bridge/clock_intent.dart';
import 'package:comstar_bridge/google_data_intent.dart';
import 'package:comstar_bridge/google_intent.dart';
import 'package:comstar_bridge/home_data_intent.dart';
import 'package:comstar_bridge/identity_intent.dart';
import 'package:comstar_bridge/social_intent.dart';
import 'package:comstar_bridge/terminal_intent.dart';
import 'package:comstar_bridge/vision_visit_intent.dart';
import 'package:comstar_bridge/working_ack.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// Split-mode closed-form membership (mirrors coordinator order, without AO).
String classifyClosedForm(String text) {
  if (parseTerminalIntent(text) != null) return 'terminal';
  if (parseGoogleIntent(text) != null) return 'pairing_google';
  if (parseIdentityIntent(text) != null) return 'identity';
  if (parseClockIntent(text) != null) return 'clock';
  if (parseSocialIntent(text) != null) return 'social';
  if (parseGoogleDataIntent(text) != null) return 'google_data';
  if (parseHomeDataIntent(text) != null) return 'home_data';
  if (parseVisionVisitIntent(text) != null) return 'vision_visit';
  if (looksLikeNewsResearch(text)) return 'news';
  if (looksLikeWeatherResearch(text)) return 'weather';
  return 'none';
}

void main() {
  final path =
      '${Directory.current.path}/test/fixtures/closed_form_utterances.yaml';
  final doc = loadYaml(File(path).readAsStringSync()) as YamlList;

  test('fixture has at least 80 utterances', () {
    expect(doc.length, greaterThanOrEqualTo(80));
  });

  for (final raw in doc) {
    final row = Map<String, dynamic>.from(raw as Map);
    final utterance = row['utterance']?.toString() ?? '';
    final expectFamily = row['expect']?.toString() ?? '';
    test('split: "$utterance" → $expectFamily', () {
      expect(classifyClosedForm(utterance), expectFamily);
    });
  }
}
