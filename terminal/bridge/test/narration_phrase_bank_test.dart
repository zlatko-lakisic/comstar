import 'dart:io';

import 'package:comstar_bridge/voice/phrase_bank.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  group('NarrationPhraseBank', () {
    late Map<String, List<String>> banks;

    setUp(() {
      banks = NarrationPhraseBank.embeddedDefaults();
    });

    test('every bank has at least ten entries', () {
      for (final id in NarrationBank.all) {
        expect(banks[id]!.length, greaterThanOrEqualTo(10), reason: id);
      }
    });

    test('yaml asset matches embedded defaults', () {
      final path = NarrationPhraseBank.defaultYamlPath();
      expect(File(path).existsSync(), isTrue, reason: path);
      final fromYaml = NarrationPhraseBank.fromYaml(
        File(path).readAsStringSync(),
      ).snapshot();
      for (final id in NarrationBank.all) {
        expect(fromYaml[id], banks[id], reason: id);
      }
    });

    test('no markdown, urls, colons, digits (except queue many), model names', () {
      const modelBits = [
        'qwen',
        'llama',
        'gpt',
        'claude',
        'ollama',
        'instruct',
      ];
      final seen = <String>{};
      for (final id in NarrationBank.all) {
        for (final line in banks[id]!) {
          expect(line.contains('##'), isFalse, reason: line);
          expect(line.contains('http'), isFalse, reason: line);
          expect(line.contains('www.'), isFalse, reason: line);
          if (id != NarrationBank.queuePositionMany) {
            expect(line.contains(':'), isFalse, reason: '$id: $line');
            expect(RegExp(r'\d').hasMatch(line), isFalse, reason: line);
          }
          for (final bit in modelBits) {
            expect(
              line.toLowerCase().contains(bit),
              isFalse,
              reason: '$line contains $bit',
            );
          }
          final words = line
              .replaceAll('{n}', 'two')
              .split(RegExp(r'\s+'))
              .where((w) => w.isNotEmpty)
              .length;
          expect(words, lessThanOrEqualTo(12), reason: line);
          expect(seen.contains(line), isFalse, reason: 'duplicate: $line');
          seen.add(line);
        }
      }
    });

    test('okay/alright only in stage0, stage1, result_preface', () {
      const allowed = {
        NarrationBank.stage0Ack,
        NarrationBank.stage1Planning,
        NarrationBank.resultPreface,
      };
      for (final id in NarrationBank.all) {
        for (final line in banks[id]!) {
          final lower = line.toLowerCase();
          if (lower.startsWith('okay') || lower.startsWith('alright')) {
            expect(allowed.contains(id), isTrue, reason: '$id: $line');
          }
        }
      }
    });

    test('ring buffer excludes recent picks', () {
      final bank = NarrationPhraseBank(
        banks: {
          NarrationBank.stage0Ack: List<String>.generate(
            10,
            (i) => 'Line number ${[
              'alpha',
              'bravo',
              'charlie',
              'delta',
              'echo',
              'foxtrot',
              'golf',
              'hotel',
              'india',
              'juliet',
            ][i]}.',
          ),
          for (final id in NarrationBank.all)
            if (id != NarrationBank.stage0Ack) id: banks[id]!,
        },
        recentRingSize: 3,
      );
      bank.beginTurn('ring-1');
      final firstThree = [
        bank.pick(NarrationBank.stage0Ack),
        bank.pick(NarrationBank.stage0Ack),
        bank.pick(NarrationBank.stage0Ack),
      ];
      // Next pick must not be any of the first three templates... but we track
      // templates before fill. With unique lines and turn-used, fourth differs.
      final fourth = bank.pick(NarrationBank.stage0Ack);
      expect(firstThree.contains(fourth), isFalse);
    });

    test('same turn id seed yields same sequence', () {
      List<String> seq(String turnId) {
        final bank = NarrationPhraseBank(
          banks: NarrationPhraseBank.embeddedDefaults(),
        );
        bank.beginTurn(turnId);
        return [
          bank.pick(NarrationBank.stage0Ack),
          bank.pick(NarrationBank.stage1Planning),
          bank.pick(NarrationBank.stage2Web),
          bank.pick(NarrationBank.heartbeatTier1),
          bank.pick(NarrationBank.resultPreface),
        ];
      }

      expect(seq('followup-123'), seq('followup-123'));
      expect(seq('followup-123'), isNot(seq('followup-999')));
    });

    test('spokenNumber for queue many', () {
      expect(NarrationPhraseBank.spokenNumber(3), 'three');
      expect(NarrationPhraseBank.spokenNumber(21), 'twenty-one');
    });

    test('yaml file parses without unknown keys', () {
      final path = NarrationPhraseBank.defaultYamlPath();
      final raw = loadYaml(File(path).readAsStringSync()) as YamlMap;
      for (final key in raw.keys) {
        expect(NarrationBank.all.contains(key.toString()), isTrue);
      }
    });
  });
}
