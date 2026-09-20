// Pure helpers for spoken AO Reach status / failure lines.

import 'package:ao_reach/ao_reach.dart' show ReachRunException, ReachRunStatus;

const kAoFailureSpeakMaxChars = 120;

/// User-facing progress line from a Reach status frame, or null if nothing to say.
///
/// Skips terminal/done phases and empty frames. Heartbeats with an empty message
/// return null (deadline extension stays in the coordinator).
String? aoStatusSpeakLine(ReachRunStatus status) {
  final phase = status.phase.trim().toLowerCase();
  if (phase == 'done' || phase == 'error') return null;
  if (!status.processing && !status.isQueued) return null;

  final message = status.message.trim();
  if (message.isNotEmpty) {
    if (_isInternalAoStatusMessage(message)) return null;
    return _trimSpoken(_humanizeStatusMessage(message));
  }

  if (status.isQueued) {
    final pos = status.queuePosition;
    final len = status.queueLength;
    if (pos != null && len != null && len > 0) {
      return 'Queued, position $pos of $len.';
    }
    return 'Queued.';
  }

  final phaseLabel = status.phase.trim();
  if (phaseLabel.isNotEmpty && phaseLabel.toLowerCase() != 'info') {
    return _trimSpoken(_humanizePhase(phaseLabel));
  }
  return null;
}

/// True when the spoken progress line should be treated as a change.
bool aoStatusChanged(String? previousSpeakLine, String? nextSpeakLine) {
  if (nextSpeakLine == null || nextSpeakLine.isEmpty) return false;
  return previousSpeakLine != nextSpeakLine;
}

/// Periodic re-speak when the same status is still active.
String aoPeriodicStillLine(String message) {
  final m = message.trim();
  if (m.isEmpty) return 'Still working.';
  final lower = m.toLowerCase();
  if (lower.startsWith('still ')) {
    if (m.endsWith('.') ||
        m.endsWith('!') ||
        m.endsWith('?') ||
        m.endsWith('…')) {
      return m;
    }
    return '$m.';
  }
  var body = m;
  if (body.endsWith('.') || body.endsWith('!') || body.endsWith('?')) {
    body = body.substring(0, body.length - 1);
  }
  if (body.endsWith('…')) return 'Still $body';
  return 'Still $body.';
}

/// Short hallway line from a failed AO turn, or null to keep the timeout apology.
String? aoFailureSpeakLine(Object error, {int maxChars = kAoFailureSpeakMaxChars}) {
  String? raw;
  if (error is ReachRunException) {
    raw = error.message.trim();
    if (raw.isEmpty && error.detail != null) {
      raw = error.detail!.trim();
    }
  } else {
    final s = error.toString().trim();
    // ReachRunException.toString() embeds message=… when not typed.
    final m = RegExp(r'message=([^,\)]+)').firstMatch(s);
    if (m != null) {
      raw = m.group(1)!.trim();
    }
  }
  if (raw == null || raw.isEmpty) return null;

  var line = raw
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^ReachRunException\([^)]*\)\s*'), '')
      .trim();
  if (line.isEmpty) return null;

  // Soften catalog / RAG miss phrasing for speech without hiding the cause.
  line = line
      .replaceFirst(
        RegExp(r'^Unknown rag_id\(s\) in task [^:]+:\s*', caseSensitive: false),
        'Knowledge base missing: ',
      )
      .replaceFirst(
        RegExp(r'^workflow\.mcp_providers\[\d+\]\s+', caseSensitive: false),
        '',
      );

  // AO often remaps worker RAG/catalog hard-fails to this generic line.
  if (RegExp(
    r'agent returned a response in an unexpected format',
    caseSensitive: false,
  ).hasMatch(line)) {
    line =
        'the research step failed (bad plan or missing knowledge base on Ada)';
  }

  line = _trimSpoken(line, maxChars: maxChars);
  if (!line.endsWith('.') && !line.endsWith('!') && !line.endsWith('?')) {
    line = '$line.';
  }
  if (!line.toLowerCase().startsWith('sorry')) {
    line = 'Sorry — $line';
  }
  return line;
}

String _humanizePhase(String phase) {
  final p = phase.replaceAll('_', ' ').trim();
  if (p.isEmpty) return 'Working.';
  return '${p[0].toUpperCase()}${p.substring(1)}.';
}

/// Drop internal AO progress dumps that must not be spoken in the hallway.
bool _isInternalAoStatusMessage(String message) {
  final m = message.trim();
  if (m.isEmpty) return true;
  final lower = m.toLowerCase();
  if (lower.startsWith('completed ')) return true;
  if (lower.startsWith('starting direct-')) return true;
  if (lower.contains('## question')) return true;
  if (RegExp(r'\bdirect-[a-z0-9_.-]+:', caseSensitive: false).hasMatch(m)) {
    return true;
  }
  // Raw markdown / XML / CSS dumps.
  if (m.startsWith('##') || m.startsWith('<?xml') || m.contains('{text-decoration')) {
    return true;
  }
  return false;
}

/// Soften model-id progress into hallway English.
String _humanizeStatusMessage(String message) {
  final m = message.trim();
  // Full plan summaries recycle into memory and derail the next turn.
  if (RegExp(r'^plan ready\b', caseSensitive: false).hasMatch(m)) {
    return 'Plan ready…';
  }
  if (RegExp(r'^working through\s+\d+\s+steps?\b', caseSensitive: false)
      .hasMatch(m)) {
    return 'Working through the steps…';
  }
  final consulting = RegExp(
    r'^consulting\s+([^\s…]+)…?$',
    caseSensitive: false,
  ).firstMatch(m);
  if (consulting != null) {
    final model = consulting.group(1)!;
    if (model.contains(':') || model.contains('_')) {
      return 'Looking that up…';
    }
  }
  final still = RegExp(
    r'^still working with\s+([^\s…]+)…?$',
    caseSensitive: false,
  ).firstMatch(m);
  if (still != null) {
    final model = still.group(1)!;
    if (model.contains(':') || model.contains('_')) {
      return 'Still working…';
    }
  }
  return m;
}

String _trimSpoken(String text, {int maxChars = kAoFailureSpeakMaxChars}) {
  final t = text.trim();
  if (t.length <= maxChars) return t;
  final cut = t.substring(0, maxChars - 1).trimRight();
  final lastSpace = cut.lastIndexOf(' ');
  final base = lastSpace > 40 ? cut.substring(0, lastSpace) : cut;
  return '$base…';
}
