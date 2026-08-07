import 'dart:io';
import 'dart:math';

import 'package:comstar_bridge/phrase_bank.dart';
import 'package:test/test.dart';

void main() {
  group('PhraseBank', () {
    late Directory tmp;
    late PhraseBank bank;
    var clock = DateTime.utc(2026, 8, 4, 12);

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('phrase-bank-test');
      clock = DateTime.utc(2026, 8, 4, 12);
      bank = PhraseBank(
        cacheDir: tmp,
        random: Random(1),
        now: () => clock,
      );
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('fillName substitutes and anonymous fallback', () {
      expect(PhraseBank.fillName('Hi [[name]]!', 'Zlatko'), 'Hi Zlatko!');
      expect(PhraseBank.fillName('Hi [[name]]!', null), 'Hi there!');
      expect(PhraseBank.fillName('Hi {name}!', 'Zlatko'), 'Hi Zlatko!');
      expect(PhraseBank.fillName('Hello.', 'Zlatko'), 'Hello.');
    });

    test('sanitizeLines strips bullets and noise', () {
      final lines = PhraseBank.sanitizeLines([
        '1. Welcome [[name]].',
        '- Ready when you are.',
        '',
        'Here are some phrases:',
        '"Good evening [[name]]."',
        'x' * 200,
        'Rest peacefully,清晨安睡，有什么需要随时唤醒我。',
        'Спокойной ночи',
        'Good night, sleep well.',
        'Okay, entering sleep mode. Say hey comstar to wake me.',
      ]);
      expect(lines, [
        'Welcome [[name]].',
        'Ready when you are.',
        'Good evening [[name]].',
        'Okay, entering sleep mode. Say hey comstar to wake me.',
      ]);
    });

    test('pick prefers anonymous when name missing', () {
      bank.replaceCategory(PhraseCategory.engage, [
        'Hey [[name]].',
        'Hello there.',
        'Welcome [[name]].',
      ]);
      final line = bank.pick(PhraseCategory.engage);
      expect(line, isNotNull);
      expect(line!.contains(PhraseBank.nameSlot), isFalse);
      expect(line, 'Hello there.');
    });

    test('pick fills name when provided', () {
      bank.replaceCategory(PhraseCategory.engage, [
        'Hey [[name]].',
      ]);
      expect(bank.pick(PhraseCategory.engage, name: 'Ada'), 'Hey Ada.');
    });

    test('persistence round-trip', () {
      bank.replaceCategory(PhraseCategory.sleepEnter, [
        'Nighty night. Say hey comstar later.',
      ]);
      bank.replaceCategory(PhraseCategory.sleepWake, [
        'I am listening [[name]].',
      ]);
      bank.save();

      final loaded = PhraseBank(cacheDir: tmp, now: () => clock);
      loaded.load();
      expect(loaded.count(PhraseCategory.sleepEnter), 1);
      expect(loaded.count(PhraseCategory.sleepWake), 1);
      expect(loaded.updatedAt, isNotNull);
      expect(
        loaded.pick(PhraseCategory.sleepWake, name: 'Zlatko'),
        'I am listening Zlatko.',
      );
    });

    test('needsRefresh on age and empty', () {
      expect(bank.needsRefresh(const Duration(hours: 6)), isTrue);
      bank.replaceAll({
        PhraseCategory.engage: ['Hi.'],
        PhraseCategory.sleepEnter: ['Bye.'],
        PhraseCategory.sleepWake: ['Up.'],
        PhraseCategory.social: ['Sup.'],
        PhraseCategory.working: ['Working.'],
        PhraseCategory.resultReady: ['Ready.'],
      });
      expect(bank.needsRefresh(const Duration(hours: 6)), isFalse);
      clock = clock.add(const Duration(hours: 7));
      expect(bank.needsRefresh(const Duration(hours: 6)), isTrue);
    });

    test('parseAgentText', () {
      const text = '''
1. Morning [[name]].
2. Hello friend.
''';
      expect(PhraseBank.parseAgentText(text), [
        'Morning [[name]].',
        'Hello friend.',
      ]);
    });
  });
}
