import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Categories for pre-generated spoken lines (AO phrase bank).
abstract final class PhraseCategory {
  static const engage = 'engage';
  static const sleepEnter = 'sleep_enter';
  static const sleepWake = 'sleep_wake';
  static const social = 'social';
  static const working = 'working';
  static const resultReady = 'result_ready';

  static const all = <String>[
    engage,
    sleepEnter,
    sleepWake,
    social,
    working,
    resultReady,
  ];
}

/// On-disk + in-memory banks of short spoken lines with optional `{name}` slots.
class PhraseBank {
  PhraseBank({
    Directory? cacheDir,
    Random? random,
    DateTime Function()? now,
  })  : _random = random ?? Random(),
        _now = now ?? DateTime.now,
        _path = File(
          '${(cacheDir ?? _defaultCacheDir()).path}/phrase_banks.json',
        );

  final Random _random;
  final DateTime Function() _now;
  final File _path;

  final Map<String, List<String>> _lines = {
    for (final c in PhraseCategory.all) c: <String>[],
  };
  DateTime? _updatedAt;
  final List<String> _recent = [];
  static const _recentCap = 12;

  DateTime? get updatedAt => _updatedAt;
  File get path => _path;

  int count(String category) => List<String>.from(_lines[category] ?? const []).length;

  List<String> lines(String category) =>
      List<String>.unmodifiable(_lines[category] ?? const []);

  static Directory _defaultCacheDir() {
    final home = Platform.environment['HOME']?.trim();
    if (home != null && home.isNotEmpty) {
      return Directory('$home/.cache/comstar');
    }
    return Directory('${Directory.systemTemp.path}/comstar-phrase-bank');
  }

  /// Load from disk if present. Missing file is fine (empty banks).
  void load() {
    if (!_path.existsSync()) return;
    try {
      final raw = jsonDecode(_path.readAsStringSync());
      if (raw is! Map) return;
      final map = Map<String, dynamic>.from(raw);
      final updated = map['updated_at']?.toString();
      if (updated != null && updated.isNotEmpty) {
        _updatedAt = DateTime.tryParse(updated);
      }
      for (final c in PhraseCategory.all) {
        final list = map[c];
        if (list is List) {
          _lines[c] = list
              .map((e) => e.toString().trim())
              .where((s) => s.isNotEmpty)
              .toList();
        }
      }
    } catch (_) {
      // Corrupt cache — keep empty and overwrite on next save.
    }
  }

  void save() {
    _path.parent.createSync(recursive: true);
    final payload = <String, dynamic>{
      if (_updatedAt != null) 'updated_at': _updatedAt!.toUtc().toIso8601String(),
      for (final c in PhraseCategory.all) c: _lines[c],
    };
    _path.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(payload)}\n');
  }

  bool needsRefresh(Duration maxAge) {
    if (_updatedAt == null) return true;
    for (final c in PhraseCategory.all) {
      if ((_lines[c] ?? const []).isEmpty) return true;
    }
    return _now().difference(_updatedAt!) >= maxAge;
  }

  void replaceCategory(String category, List<String> lines) {
    final cleaned = sanitizeLines(lines);
    if (cleaned.isEmpty) return;
    _lines[category] = cleaned;
    _updatedAt = _now();
  }

  void replaceAll(Map<String, List<String>> byCategory) {
    var any = false;
    for (final c in PhraseCategory.all) {
      final next = sanitizeLines(byCategory[c] ?? const []);
      if (next.isEmpty) continue;
      _lines[c] = next;
      any = true;
    }
    if (any) _updatedAt = _now();
  }

  /// Pick a line for [category], filling `[[name]]` when provided.
  ///
  /// When [name] is null/empty, prefers lines without `[[name]]`; otherwise
  /// substitutes "there". Avoids immediate repeats via a small recent ring.
  String? pick(String category, {String? name}) {
    final pool = (_lines[category] ?? const <String>[])
        .where(_isSpeakableEnglish)
        .toList();
    if (pool.isEmpty) return null;

    final hasName = name != null && name.trim().isNotEmpty;
    final display = hasName ? name!.trim() : null;

    List<String> candidates;
    if (hasName) {
      candidates = List<String>.from(pool);
    } else {
      candidates = pool.where((l) => !l.contains(nameSlot)).toList();
      if (candidates.isEmpty) candidates = List<String>.from(pool);
    }

    final fresh = candidates.where((l) => !_recent.contains(l)).toList();
    final pickFrom = fresh.isNotEmpty ? fresh : candidates;
    final template = pickFrom[_random.nextInt(pickFrom.length)];
    _remember(template);

    return fillName(template, display);
  }

  void _remember(String template) {
    _recent.remove(template);
    _recent.add(template);
    while (_recent.length > _recentCap) {
      _recent.removeAt(0);
    }
  }

  /// Name slot token. Avoids `{name}` which AO/CrewAI treats as a template var.
  static const nameSlot = '[[name]]';

  /// Replace `[[name]]` (and legacy `{name}`) or, if [name] is null, use `there`.
  static String fillName(String template, String? name) {
    final n = (name == null || name.trim().isEmpty) ? 'there' : name.trim();
    return template
        .replaceAll(nameSlot, n)
        .replaceAll('{name}', n)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Parse AO newline output into clean phrase lines.
  static List<String> sanitizeLines(Iterable<String> raw) {
    final out = <String>[];
    for (final line in raw) {
      var s = line.trim();
      if (s.isEmpty) continue;
      s = s.replaceFirst(RegExp(r'^[-*•]\s+'), '');
      s = s.replaceFirst(RegExp(r'^\d+[.)]\s+'), '');
      s = s.replaceAll(RegExp(r'^["“]|["”]$'), '');
      s = s.trim();
      if (s.isEmpty) continue;
      if (s.toLowerCase().startsWith('here are')) continue;
      if (s.length > 160) continue;
      // Piper / household TTS is English-only — drop CJK and other scripts.
      if (!_isSpeakableEnglish(s)) continue;
      out.add(s);
    }
    return out;
  }

  /// True when [s] is safe for English TTS (allows [[name]], basic punctuation).
  static bool _isSpeakableEnglish(String s) {
    // CJK, Hangul, Hiragana/Katakana, Cyrillic — never speak these.
    if (RegExp(
      r'[\u0400-\u04FF\u3040-\u30FF\u3400-\u9FFF\uAC00-\uD7AF\uF900-\uFAFF]',
    ).hasMatch(s)) {
      return false;
    }
    // sleep_enter must not tuck the *user* in — reject bedtime farewells.
    final lower = s.toLowerCase();
    if (RegExp(
      r'\b(good\s*night|goodnight|sweet dreams|sleep (well|tight)|'
      r'rest (easy|peacefully)|see you in the morning)\b',
    ).hasMatch(lower)) {
      return false;
    }
    // Mostly Latin / digits / punctuation / spaces / name slot.
    var stripped = s
        .replaceAll(nameSlot, 'name')
        .replaceAll('{name}', 'name')
        .replaceAll(RegExp(r'[“”‘’…]'), "'");
    if (!RegExp(r"^[\w\s.,!?'\-—–:;/()]+$", unicode: true).hasMatch(stripped)) {
      return false;
    }
    // Require at least one Latin letter so we don't keep punctuation-only junk.
    return RegExp(r'[A-Za-z]').hasMatch(s);
  }

  /// Split AO freeform text into lines for [sanitizeLines].
  static List<String> parseAgentText(String text) {
    return sanitizeLines(text.split(RegExp(r'[\r\n]+')));
  }
}
