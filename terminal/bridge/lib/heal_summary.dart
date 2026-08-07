/// Turn `comstar_health.sh` stdout into a short spoken summary.
String summarizeHealOutput(String output) {
  final lines = output
      .split(RegExp(r'[\r\n]+'))
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

  var pass = 0;
  var fail = 0;
  var healed = 0;
  final fails = <String>[];
  final heals = <String>[];

  for (final line in lines) {
    final results = RegExp(
      r'Results:\s*PASS=(\d+)\s+FAIL=(\d+)\s+HEALED=(\d+)',
      caseSensitive: false,
    ).firstMatch(line);
    if (results != null) {
      pass = int.tryParse(results.group(1)!) ?? pass;
      fail = int.tryParse(results.group(2)!) ?? fail;
      healed = int.tryParse(results.group(3)!) ?? healed;
      continue;
    }
    if (line.startsWith('FAIL ')) {
      fails.add(_humanizeHealDetail(line.substring(5)));
    } else if (line.startsWith('HEAL ')) {
      heals.add(_humanizeHealDetail(line.substring(5)));
    }
  }

  if (fail == 0 && healed == 0 && fails.isEmpty && heals.isEmpty) {
    return "I'm perfectly healthy — nothing wrong was detected.";
  }
  if (fail == 0 && healed == 0 && pass > 0) {
    return "I'm perfectly healthy — nothing wrong was detected.";
  }

  final parts = <String>[];
  if (heals.isNotEmpty || healed > 0) {
    final detail = heals.isEmpty
        ? 'I fixed $healed issue${healed == 1 ? '' : 's'}.'
        : 'I fixed: ${_joinSpoken(heals)}.';
    parts.add(detail);
  }
  if (fails.isNotEmpty || fail > 0) {
    final remaining = fails.isEmpty
        ? 'I still see $fail problem${fail == 1 ? '' : 's'}.'
        : 'I still see: ${_joinSpoken(fails)}.';
    parts.add(remaining);
  }

  if (parts.isEmpty) {
    return "I finished the health check, but I could not summarize the results.";
  }
  if (heals.isNotEmpty && fails.isEmpty && fail == 0) {
    return 'I found problems and fixed them. ${parts.first}';
  }
  if ((heals.isEmpty && healed == 0) && (fails.isNotEmpty || fail > 0)) {
    return 'I found problems I could not fully fix. ${parts.last}';
  }
  return parts.join(' ');
}

String _humanizeHealDetail(String raw) {
  var s = raw.trim();
  s = s.replaceAll(RegExp(r'\s+'), ' ');
  s = s.replaceAll('comstar-bridge.service', 'the bridge');
  s = s.replaceAll('comstar-bridge', 'the bridge');
  s = s.replaceAll('comstar-audio.service', 'audio');
  s = s.replaceAll('comstar-audio', 'audio');
  s = s.replaceAll('comstar-kiosk.service', 'the kiosk');
  s = s.replaceAll('comstar-kiosk', 'the kiosk');
  s = s.replaceAll('restarted ', 'restarted ');
  s = s.replaceAll('unit ', '');
  s = s.replaceAll('WS disconnected', 'was disconnected');
  s = s.replaceAll('unreachable', 'was unreachable');
  s = s.replaceAll('inactive', 'was down');
  s = s.replaceAll('not listening', 'was not listening');
  // Keep short for TTS.
  if (s.length > 80) s = '${s.substring(0, 77)}…';
  return s;
}

String _joinSpoken(List<String> items) {
  final unique = <String>[];
  for (final i in items) {
    if (i.isNotEmpty && !unique.contains(i)) unique.add(i);
  }
  if (unique.isEmpty) return 'nothing specific';
  if (unique.length == 1) return unique.first;
  if (unique.length == 2) return '${unique[0]} and ${unique[1]}';
  return '${unique.sublist(0, unique.length - 1).join(', ')}, and ${unique.last}';
}
