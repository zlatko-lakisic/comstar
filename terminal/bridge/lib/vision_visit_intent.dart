/// Frigate visitor-history voice intents (driveway / door cameras / last seen).
enum VisionVisitIntentKind { whoVisited, personLastSeen }

class VisionVisitIntent {
  const VisionVisitIntent({
    required this.kind,
    this.camera = 'driveway',
    this.since = 'today',
    this.personName,
  });

  final VisionVisitIntentKind kind;

  /// Frigate camera name (`driveway`, `front_door`, …). Unused for all-cam last seen.
  final String camera;

  /// MCP `since` token: `today`, `yesterday`, `30d`, …
  final String since;

  /// Spoken name for [VisionVisitIntentKind.personLastSeen].
  final String? personName;
}

/// Parse historical visitor / last-seen questions. Live presence stays on AO.
VisionVisitIntent? parseVisionVisitIntent(String text) {
  final t = text
      .toLowerCase()
      .replaceAll(RegExp(r"['\u2019]"), '')
      .replaceAll(RegExp(r'[^\w\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (t.isEmpty) return null;

  // "Who's home" is HA presence — never Frigate history.
  if (RegExp(r'\b(whos home|who is home|anyone home)\b').hasMatch(t)) {
    return null;
  }

  final lastSeen = _parsePersonLastSeen(t);
  if (lastSeen != null) return lastSeen;

  // History only — live "who is at the door" stays on AO vision tools.
  final historical = RegExp(
    r'\bwho (was|were) (in|at|on) (the |my )?(driveway|front door|door|camera)\b|'
    r'\bvisitors?( today| yesterday| this (morning|afternoon|evening))?\b|'
    r'\bwho came (by|over)\b|'
    r'\bwho (visited|came to) (the |my )?(driveway|front door|house)\b',
  ).hasMatch(t);
  if (!historical) return null;

  final camera = RegExp(r'\bfront door\b|\bfront_door\b').hasMatch(t)
      ? 'front_door'
      : 'driveway';

  var since = 'today';
  if (RegExp(r'\byesterday\b').hasMatch(t)) {
    since = 'yesterday';
  } else if (RegExp(r'\bthis morning\b').hasMatch(t)) {
    since = 'today';
  } else if (RegExp(r'\blast (night|evening)\b').hasMatch(t)) {
    since = 'yesterday';
  }

  return VisionVisitIntent(
    kind: VisionVisitIntentKind.whoVisited,
    camera: camera,
    since: since,
  );
}

VisionVisitIntent? _parsePersonLastSeen(String t) {
  // Prefer explicit last-seen patterns so we never invent from chat memory.
  final patterns = <RegExp>[
    RegExp(
      r"\b(?:when was|when's|whats?) the last time (?:that )?you (?:saw|seen) (.+)$",
    ),
    RegExp(r'\bwhen did you last (?:time )?(?:see|saw) (.+)$'),
    RegExp(r'\bwhen was (.+?) last seen\b'),
    RegExp(r'\blast time you (?:saw|seen) (.+)$'),
    RegExp(r'\bhave you (?:seen|saw) (.+?)(?: lately| recently| today| yesterday)?$'),
    RegExp(r'\bwhere (?:was it that |did )?you (?:saw|see) (.+)$'),
  ];

  String? rawName;
  for (final re in patterns) {
    final m = re.firstMatch(t);
    if (m != null) {
      rawName = m.group(1);
      break;
    }
  }
  if (rawName == null) return null;

  var name = rawName
      .replaceAll(
        RegExp(
          r'\b(on (the |my )?(driveway|front door|camera|cameras?)|'
          r'lately|recently|today|yesterday|this (morning|afternoon|evening)|'
          r'around here|outside)\b',
        ),
        ' ',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  // Drop leading articles / fillers.
  name = name.replaceFirst(RegExp(r'^(the |a |an |my |our )'), '').trim();
  if (name.isEmpty || name.length < 2) return null;
  // Reject questions without a person token.
  if (RegExp(r'^(anyone|anybody|someone|somebody|them|him|her|it)$').hasMatch(name)) {
    return null;
  }

  String? camera;
  if (RegExp(r'\bfront door\b|\bfront_door\b').hasMatch(t)) {
    camera = 'front_door';
  } else if (RegExp(r'\bdriveway\b').hasMatch(t)) {
    camera = 'driveway';
  }

  // Title-case lightly for Frigate matching / speech.
  final spoken = name.split(' ').map((w) {
    if (w.isEmpty) return w;
    return '${w[0].toUpperCase()}${w.substring(1)}';
  }).join(' ');

  return VisionVisitIntent(
    kind: VisionVisitIntentKind.personLastSeen,
    camera: camera ?? '',
    since: '30d',
    personName: spoken,
  );
}

/// Keep Frigate/LLM prose short enough for TTS.
String clipSpokenHint(String hint, {int maxChars = 420}) {
  final t = hint.trim();
  if (t.length <= maxChars) return t;
  final cut = t.substring(0, maxChars);
  final lastStop = cut.lastIndexOf(RegExp(r'[.!?]'));
  if (lastStop >= 80) {
    return cut.substring(0, lastStop + 1).trim();
  }
  return '$cut…';
}
