/// Closed phrase banks for AO spoken progress narration.
///
/// Nothing from AO is spoken verbatim — banks select wording only.
library;

import 'dart:io';
import 'dart:math';

import 'package:yaml/yaml.dart';

/// Bank ids matching [assets/phrases/narration.yaml].
abstract final class NarrationBank {
  static const stage0Ack = 'stage0_ack';
  static const stage1Planning = 'stage1_planning';
  static const stage2Generic = 'stage2_generic';
  static const stage2Web = 'stage2_web';
  static const stage2Knowledge = 'stage2_knowledge';
  static const stage2House = 'stage2_house';
  static const stage3Composing = 'stage3_composing';
  static const heartbeatTier1 = 'heartbeat_tier1';
  static const heartbeatTier2 = 'heartbeat_tier2';
  static const heartbeatTier3 = 'heartbeat_tier3';
  static const resultPreface = 'result_preface';
  static const queuePositionTwo = 'queue_position_two';
  static const queuePositionMany = 'queue_position_many';

  static const all = <String>[
    stage0Ack,
    stage1Planning,
    stage2Generic,
    stage2Web,
    stage2Knowledge,
    stage2House,
    stage3Composing,
    heartbeatTier1,
    heartbeatTier2,
    heartbeatTier3,
    resultPreface,
    queuePositionTwo,
    queuePositionMany,
  ];

  static String stage2ForCategory(String category) {
    switch (category) {
      case NarrationCategory.web:
        return stage2Web;
      case NarrationCategory.knowledge:
        return stage2Knowledge;
      case NarrationCategory.house:
        return stage2House;
      default:
        return stage2Generic;
    }
  }

  static String stageBank(int stage, {String category = NarrationCategory.generic}) {
    switch (stage) {
      case 0:
        return stage0Ack;
      case 1:
        return stage1Planning;
      case 2:
        return stage2ForCategory(category);
      case 3:
        return stage3Composing;
      default:
        return stage2Generic;
    }
  }

  static String heartbeatBank(int tier) {
    switch (tier) {
      case 2:
        return heartbeatTier2;
      case 3:
        return heartbeatTier3;
      default:
        return heartbeatTier1;
    }
  }
}

/// Tool-category labels for stage-2 bank selection.
abstract final class NarrationCategory {
  static const web = 'web';
  static const knowledge = 'knowledge';
  static const house = 'house';
  static const generic = 'generic';
}

/// Seeded, ring-buffered picker over closed narration banks.
class NarrationPhraseBank {
  NarrationPhraseBank({
    Map<String, List<String>>? banks,
    this.recentRingSize = 3,
    Random? random,
  })  : _banks = {
          for (final id in NarrationBank.all)
            id: List<String>.from(banks?[id] ?? const []),
        },
        _random = random ?? Random();

  /// Load from yaml file; falls back to [embeddedDefaults] when missing/corrupt.
  factory NarrationPhraseBank.load({
    String? yamlPath,
    int recentRingSize = 3,
    Random? random,
  }) {
    final path = yamlPath ?? defaultYamlPath();
    final file = File(path);
    if (file.existsSync()) {
      try {
        return NarrationPhraseBank.fromYaml(
          file.readAsStringSync(),
          recentRingSize: recentRingSize,
          random: random,
        );
      } catch (_) {
        // Fall through to embedded defaults.
      }
    }
    return NarrationPhraseBank(
      banks: embeddedDefaults(),
      recentRingSize: recentRingSize,
      random: random,
    );
  }

  factory NarrationPhraseBank.fromYaml(
    String yamlText, {
    int recentRingSize = 3,
    Random? random,
  }) {
    final raw = loadYaml(yamlText);
    if (raw is! YamlMap) {
      return NarrationPhraseBank(
        banks: embeddedDefaults(),
        recentRingSize: recentRingSize,
        random: random,
      );
    }
    final banks = <String, List<String>>{};
    for (final id in NarrationBank.all) {
      final list = raw[id];
      if (list is YamlList) {
        banks[id] = list
            .map((e) => e.toString().trim())
            .where((s) => s.isNotEmpty)
            .toList();
      }
    }
    // Fill any missing banks from embedded defaults.
    final defaults = embeddedDefaults();
    for (final id in NarrationBank.all) {
      if ((banks[id] ?? const []).isEmpty) {
        banks[id] = List<String>.from(defaults[id] ?? const []);
      }
    }
    return NarrationPhraseBank(
      banks: banks,
      recentRingSize: recentRingSize,
      random: random,
    );
  }

  final Map<String, List<String>> _banks;
  final int recentRingSize;
  Random _random;

  final Map<String, List<String>> _recentByBank = {};
  final Set<String> _turnUsed = {};

  /// Resolve default yaml next to the package assets tree.
  static String defaultYamlPath() {
    // Prefer package-relative path when running from terminal/bridge.
    final candidates = <String>[
      'assets/phrases/narration.yaml',
      'terminal/bridge/assets/phrases/narration.yaml',
    ];
    final scriptDir = File(Platform.script.toFilePath()).parent.path;
    candidates.addAll([
      '$scriptDir/../assets/phrases/narration.yaml',
      '$scriptDir/../../assets/phrases/narration.yaml',
    ]);
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return candidates.first;
  }

  Map<String, List<String>> snapshot() => {
        for (final e in _banks.entries) e.key: List<String>.from(e.value),
      };

  List<String> lines(String bank) =>
      List<String>.unmodifiable(_banks[bank] ?? const []);

  int count(String bank) => (_banks[bank] ?? const []).length;

  /// Seed the RNG once per turn from [turnId] for replayable golden transcripts.
  void beginTurn(String turnId) {
    _turnUsed.clear();
    _random = Random(_seedFromTurnId(turnId));
  }

  void endTurn() {
    _turnUsed.clear();
  }

  /// Pick a line from [bank], excluding turn-used lines and the recent ring.
  ///
  /// For [NarrationBank.queuePositionMany], replace `{n}` with a spoken word.
  String pick(String bank, {int? queueAhead}) {
    final pool = List<String>.from(_banks[bank] ?? const []);
    if (pool.isEmpty) {
      throw StateError('Narration bank "$bank" is empty');
    }

    final recent = _recentByBank.putIfAbsent(bank, () => <String>[]);
    var candidates = pool
        .where((l) => !_turnUsed.contains(l) && !recent.contains(l))
        .toList();
    if (candidates.isEmpty) {
      candidates = pool.where((l) => !_turnUsed.contains(l)).toList();
    }
    if (candidates.isEmpty) {
      candidates = pool;
    }

    final template = candidates[_random.nextInt(candidates.length)];
    _remember(bank, template);
    _turnUsed.add(template);

    if (bank == NarrationBank.queuePositionMany) {
      final n = queueAhead ?? 2;
      return template.replaceAll('{n}', spokenNumber(n));
    }
    return template;
  }

  void _remember(String bank, String template) {
    final recent = _recentByBank.putIfAbsent(bank, () => <String>[]);
    recent.remove(template);
    recent.add(template);
    while (recent.length > recentRingSize) {
      recent.removeAt(0);
    }
  }

  static int _seedFromTurnId(String turnId) {
    var h = 0x811c9dc5;
    for (final c in turnId.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0x7fffffff;
    }
    return h == 0 ? 1 : h;
  }

  /// Small cardinals for queue backlog speech (no digits in TTS).
  static String spokenNumber(int n) {
    const words = <String>[
      'zero',
      'one',
      'two',
      'three',
      'four',
      'five',
      'six',
      'seven',
      'eight',
      'nine',
      'ten',
      'eleven',
      'twelve',
      'thirteen',
      'fourteen',
      'fifteen',
      'sixteen',
      'seventeen',
      'eighteen',
      'nineteen',
      'twenty',
    ];
    if (n >= 0 && n < words.length) return words[n];
    if (n < 100) {
      const tens = [
        '',
        '',
        'twenty',
        'thirty',
        'forty',
        'fifty',
        'sixty',
        'seventy',
        'eighty',
        'ninety',
      ];
      final t = n ~/ 10;
      final u = n % 10;
      if (u == 0) return tens[t];
      return '${tens[t]}-${words[u]}';
    }
    return 'many';
  }

  /// Built-in defaults (same content as narration.yaml) for offline tests.
  static Map<String, List<String>> embeddedDefaults() => {
        NarrationBank.stage0Ack: const [
          'Okay, on it.',
          'Got it, working on that now.',
          'Sure, give me a second.',
          'Alright, let me get into that.',
          'On it now.',
          'Okay, starting on that.',
          'Got it, one moment.',
          'Sure thing, working on it.',
          'Alright, give me a moment.',
          'Okay, let me get that going.',
        ],
        NarrationBank.stage1Planning: const [
          'Let me work out how to do that.',
          'Figuring out the best way to get that.',
          'Working out the approach now.',
          'Let me figure out where to look.',
          'Sorting out how to handle that.',
          'Thinking through the best way to do this.',
          'Working out what I need for that.',
          'Let me plan this one out.',
          'Deciding how best to get that for you.',
          'Working out the steps now.',
        ],
        NarrationBank.stage2Generic: const [
          'Working on it now.',
          'Pulling that together.',
          'Off getting that for you.',
          'Getting into it now.',
          'Running through that now.',
          'Gathering what I need.',
          'Working through it.',
          'Digging into that now.',
          'Getting that sorted.',
          'On it, collecting what I need.',
        ],
        NarrationBank.stage2Web: const [
          'Checking the news now.',
          'Having a look at the headlines.',
          'Pulling up the latest.',
          "Checking what's out there now.",
          'Going out to look that up.',
          'Reading through the latest coverage.',
          'Looking that up online now.',
          'Fetching the current headlines.',
          'Checking the latest reports.',
          'Out looking that up for you.',
        ],
        NarrationBank.stage2Knowledge: const [
          'Looking through what I know.',
          'Checking what I have on that.',
          'Going through my notes.',
          "Searching what's stored here.",
          "Looking back through what I've got.",
          'Checking my own records first.',
          'Digging through what I know about that.',
          "Having a look through what I've saved.",
          'Checking what I already have.',
          "Going through what's on file here.",
        ],
        NarrationBank.stage2House: const [
          'Checking the house now.',
          'Having a look at the house.',
          'Checking in with the house.',
          "Looking at what's going on at home.",
          'Checking the system now.',
          'Asking the house for that.',
          'Having a look at the sensors.',
          'Checking the house systems.',
          'Getting that from the house now.',
          'Looking at the house status.',
        ],
        NarrationBank.stage3Composing: const [
          'Putting that together now.',
          'Almost there, writing it up.',
          'Pulling the answer together.',
          'Just about ready.',
          'Wrapping this up now.',
          'Getting the answer together for you.',
          'Nearly done.',
          'Putting the last of it together.',
          'Finishing up now.',
          'Just pulling it together.',
        ],
        NarrationBank.heartbeatTier1: const [
          'Still working on it.',
          'Still going.',
          'Still at it.',
          'Give me a little longer.',
          'Still on it.',
          'Working through it still.',
          'Bear with me.',
          'Still pulling that together.',
          'Not done yet, still going.',
          'Hang with me a second.',
        ],
        NarrationBank.heartbeatTier2: const [
          'This one is taking a bit longer.',
          "Still going, this one's bigger than usual.",
          'Taking a little more time than usual.',
          'This one needs a bit more work.',
          'Still going, thanks for waiting.',
          'Bit of a slow one, still on it.',
          "This is taking longer than I'd like.",
          "Still working, this one's involved.",
          "Taking a bit, but I'm getting there.",
          'More to this one than usual, still going.',
        ],
        NarrationBank.heartbeatTier3: const [
          'Still going, longer than I expected.',
          'This is really taking a while, still trying.',
          "Still working, but this one's slow.",
          'Hanging in there, still no answer yet.',
          'Still at it, sorry about the wait.',
          "This one's dragging, still going.",
          'Still trying, thanks for your patience.',
          "Longer than I'd want, but still working.",
          "Still nothing yet, I'm still on it.",
          'Taking much longer than usual, still going.',
        ],
        NarrationBank.resultPreface: const [
          "Here's what I found.",
          'Alright, here it is.',
          'Got it.',
          "Okay, here's what I've got.",
          "That's done.",
          'Here you go.',
          'All set.',
          'Got something for you.',
          "Here's what came back.",
          'Okay, ready.',
        ],
        NarrationBank.queuePositionTwo: const [
          "There's one ahead of you, give me a moment.",
          "Something else is running first, won't be long.",
          "I'm finishing something else, you're next.",
          'Just wrapping up another request first.',
          'One thing ahead of yours, hang tight.',
          'Busy with another request, yours is next.',
          "Give me a moment, something's ahead of yours.",
          'Finishing something first, then yours.',
          "There's a queue right now, you're next up.",
          "One ahead of you, I'll get to it shortly.",
        ],
        NarrationBank.queuePositionMany: const [
          'There are {n} ahead of you, this will take a moment.',
          '{n} requests ahead of yours, hang tight.',
          "I've got {n} others going first.",
          'There are {n} in front of you right now.',
          "{n} ahead of you, I'll get there.",
          'Bit of a backlog, {n} ahead of yours.',
          '{n} others first, then yours.',
          'There are {n} queued before yours.',
          'Working through {n} others first.',
          '{n} ahead of you, give me a few minutes.',
        ],
      };
}
