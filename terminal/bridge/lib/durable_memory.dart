import 'dart:convert';

/// A durable resident fact (prefs, identity notes) — Phase 2 memory.
class DurableFact {
  const DurableFact({
    required this.id,
    required this.kind,
    required this.text,
    this.source,
    this.createdMs,
    this.updatedMs,
  });

  final String id;
  final String kind;
  final String text;
  final String? source;
  final int? createdMs;
  final int? updatedMs;

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'text': text,
        if (source != null) 'source': source,
        if (createdMs != null) 'created_ms': createdMs,
        if (updatedMs != null) 'updated_ms': updatedMs,
      };

  static DurableFact? fromJson(Map<String, dynamic> map) {
    final text = map['text']?.toString().trim() ?? '';
    if (text.isEmpty) return null;
    final kind = (map['kind']?.toString() ?? 'note').trim().toLowerCase();
    final id = (map['id']?.toString() ?? '').trim();
    return DurableFact(
      id: id.isEmpty ? _stableId(kind, text) : id,
      kind: kind.isEmpty ? 'note' : kind,
      text: text,
      source: map['source']?.toString(),
      createdMs: (map['created_ms'] as num?)?.toInt(),
      updatedMs: (map['updated_ms'] as num?)?.toInt(),
    );
  }
}

String _stableId(String kind, String text) {
  final norm = text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  final h = norm.hashCode & 0xFFFFFFFF;
  return '$kind-${h.toRadixString(16).padLeft(8, '0')}';
}

/// Pull durable facts from a resident utterance (heuristic; no AO required).
List<DurableFact> extractDurableFacts(String userText, {String? source}) {
  final raw = userText.trim();
  if (raw.isEmpty) return const [];
  final t = raw
      .toLowerCase()
      .replaceAll(RegExp(r"['\u2019]"), '')
      .replaceAll(RegExp(r'[^\w\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (t.isEmpty) return const [];

  final out = <DurableFact>[];
  void add(String kind, String text) {
    final cleaned = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (cleaned.length < 3 || cleaned.length > 400) return;
    out.add(
      DurableFact(
        id: _stableId(kind, cleaned),
        kind: kind,
        text: cleaned,
        source: source,
      ),
    );
  }

  // Explicit remember …
  final remember = RegExp(
    r'\b(?:please\s+)?remember(?:\s+that|\s+this)?\s+(.+)$',
  ).firstMatch(t);
  if (remember != null) {
    var body = remember.group(1)!.trim();
    body = body.replaceFirst(RegExp(r'^(that|this)\s+'), '');
    if (body.isNotEmpty) add('note', _sentenceCase(body));
  }

  final callMe = RegExp(r'\b(?:call me|my name is|i am called)\s+([a-z][\w -]{1,40})\b')
      .firstMatch(t);
  if (callMe != null) {
    add('identity', 'Prefers to be called ${_title(callMe.group(1)!)}');
  }

  final prefer = RegExp(
    r'\bi\s+(prefer|like|love|hate|dislike)\s+(.+)$',
  ).firstMatch(t);
  if (prefer != null) {
    final verb = prefer.group(1)!;
    final obj = prefer.group(2)!.trim();
    if (!_looksLikeEphemeral(obj)) {
      add('preference', 'Resident ${verb}s $obj');
    }
  }

  final dontLike = RegExp(r"\bi\s+(don t|dont|do not)\s+(like|want)\s+(.+)$")
      .firstMatch(t);
  if (dontLike != null) {
    final obj = dontLike.group(3)!.trim();
    if (!_looksLikeEphemeral(obj)) {
      add('preference', 'Resident does not ${dontLike.group(2)} $obj');
    }
  }

  final live = RegExp(
    r'\bi\s+(live|work)\s+(in|at|from)\s+(.+)$',
  ).firstMatch(t);
  if (live != null) {
    add(
      'identity',
      'Resident ${live.group(1)}s ${live.group(2)} ${live.group(3)!.trim()}',
    );
  }

  final office = RegExp(r'\bmy\s+(office|desk|room|lab)\s+is\s+(.+)$')
      .firstMatch(t);
  if (office != null) {
    add(
      'identity',
      'Resident ${office.group(1)} is ${office.group(2)!.trim()}',
    );
  }

  final never = RegExp(
    r'\b(?:please\s+)?(?:never|dont|don t|do not)\s+(.+)$',
  ).firstMatch(t);
  if (never != null && t.contains(RegExp(r'\b(remember|always|never|dont|don t)\b'))) {
    final body = never.group(1)!.trim();
    if (body.length >= 8 && !_looksLikeEphemeral(body)) {
      add('preference', 'Do not $body');
    }
  }

  // Dedupe by id
  final seen = <String>{};
  return [
    for (final f in out)
      if (seen.add(f.id)) f,
  ];
}

bool _looksLikeEphemeral(String s) {
  final t = s.toLowerCase();
  if (t.length < 3) return true;
  // Pure device commands / clock / social — not prefs.
  if (RegExp(
        r'^(the time|what time|to sleep|sleep mode|volume|the lights?\b)',
      ).hasMatch(t)) {
    return true;
  }
  return false;
}

String _sentenceCase(String s) {
  if (s.isEmpty) return s;
  return '${s[0].toUpperCase()}${s.substring(1)}';
}

String _title(String s) {
  return s
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');
}

/// Format facts for prompt injection.
String formatFactsBlock(List<DurableFact> facts, {required int maxChars}) {
  if (facts.isEmpty || maxChars <= 0) return '';
  final lines = <String>[
    for (final f in facts) '- (${f.kind}) ${f.text}',
  ];
  var joined = lines.join('\n');
  while (joined.length > maxChars && lines.isNotEmpty) {
    lines.removeLast();
    joined = lines.join('\n');
  }
  return joined;
}

/// Parse facts list from HTTP/file JSON.
List<DurableFact> parseFactsPayload(Object? raw) {
  if (raw is Map && raw['facts'] is List) {
    return parseFactsPayload(raw['facts']);
  }
  if (raw is! List) return const [];
  final out = <DurableFact>[];
  for (final item in raw) {
    if (item is Map) {
      final f = DurableFact.fromJson(Map<String, dynamic>.from(item));
      if (f != null) out.add(f);
    }
  }
  return out;
}

String encodeFactsFile(List<DurableFact> facts) =>
    '${const JsonEncoder.withIndent('  ').convert({
      'facts': facts.map((f) => f.toJson()).toList(),
    })}\n';
