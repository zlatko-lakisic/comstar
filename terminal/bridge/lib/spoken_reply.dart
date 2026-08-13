/// Unwrap AO replies that arrive as JSON so TTS never reads braces aloud.
library;

import 'dart:convert';

const _spokenKeys = <String>[
  'spoken',
  'spoken_hint',
  'speech',
  'say',
  'utterance',
  'answer',
  'reply',
  'message',
  'text',
  'content',
  'response',
  'output',
  'final_answer',
  'Final Answer',
  'result',
  'summary',
];

String _stripFence(String text) {
  var t = text.trim();
  if (!t.startsWith('```')) return t;
  final lines = t.split('\n');
  if (lines.length < 2) return t;
  var body = lines.sublist(1);
  if (body.isNotEmpty && body.last.trim().startsWith('```')) {
    body = body.sublist(0, body.length - 1);
  }
  return body.join('\n').trim();
}

String _fromValue(Object? value, {int depth = 0}) {
  if (depth > 6 || value == null) return '';
  if (value is String) return value.trim();
  if (value is num) return value.toString();
  if (value is List) {
    final parts = <String>[];
    for (final item in value) {
      final s = _fromValue(item, depth: depth + 1);
      if (s.isNotEmpty) parts.add(s);
    }
    return parts.join(' ');
  }
  if (value is! Map) return '';
  final map = value.map((k, v) => MapEntry(k.toString(), v));
  final lower = <String, String>{
    for (final k in map.keys) k.toLowerCase(): k,
  };
  for (final want in _spokenKeys) {
    final key = lower[want.toLowerCase()];
    if (key == null) continue;
    final got = _fromValue(map[key], depth: depth + 1);
    if (got.isNotEmpty) return got;
  }
  // Presence of these keys usually means machine / HA dumps, not a speakable wrapper.
  final machineKeys = {
    'entity_id',
    'attributes',
    'context',
    'last_changed',
    'last_updated',
    'unique_id',
    'device_id',
    'parameters',
    'arguments',
    'tool_calls',
    'function_call',
  };
  final lowerKeys = map.keys.map((k) => k.toLowerCase()).toSet();
  final machineish = lowerKeys.any(machineKeys.contains);
  final hasSpokenKey = lowerKeys.any(
    (k) => _spokenKeys.map((s) => s.toLowerCase()).contains(k),
  );
  if (machineish && !hasSpokenKey) return '';

  final strVals = map.values
      .whereType<String>()
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty && !s.startsWith('{'))
      .toList();
  if (strVals.length == 1) return strVals.first;
  if (strVals.isNotEmpty && !machineish) {
    strVals.sort((a, b) => b.length.compareTo(a.length));
    return strVals.first;
  }
  for (final nested in map.values) {
    if (nested is Map || nested is List) {
      final got = _fromValue(nested, depth: depth + 1);
      if (got.isNotEmpty) return got;
    }
  }
  return '';
}

bool _isToolStub(Map map) {
  final keys = map.keys.map((k) => k.toString().toLowerCase()).toSet();
  final hasName = keys.contains('name') ||
      keys.contains('tool') ||
      keys.contains('tool_name');
  final hasArgs = keys.contains('parameters') ||
      keys.contains('arguments') ||
      keys.contains('args') ||
      keys.contains('input');
  return hasName && hasArgs;
}

/// Prefer speakable fields when [raw] is a JSON object/array; else return [raw].
///
/// Opaque machine JSON (no speakable field) becomes empty so callers can fall
/// back instead of synthesizing braces.
String unwrapSpokenReply(String raw) {
  final original = raw.trim();
  if (original.isEmpty) return original;
  final t = _stripFence(original);
  if (!(t.startsWith('{') && t.endsWith('}')) &&
      !(t.startsWith('[') && t.endsWith(']'))) {
    return original;
  }
  try {
    final decoded = jsonDecode(t);
    if (decoded is Map && _isToolStub(decoded)) {
      return '';
    }
    final spoken = _fromValue(decoded);
    return spoken;
  } catch (_) {
    return original;
  }
}
