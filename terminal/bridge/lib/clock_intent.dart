/// Local clock / calendar intents answered from the terminal's own clock.
///
/// Uses [DateTime.now] on the Pi (system timezone). Do not call AO `time` MCP.
enum ClockIntentKind {
  time,
  date,
  day,
  timezone,
  season,
  datetime,
}

class ClockIntent {
  const ClockIntent(this.kind);
  final ClockIntentKind kind;
}

/// Returns a [ClockIntent] when [text] asks about local time, date, season, or TZ.
ClockIntent? parseClockIntent(String text) {
  final t = text
      .toLowerCase()
      .replaceAll(RegExp(r"['\u2019]"), '')
      .replaceAll(RegExp(r'[^\w\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (t.isEmpty) return null;

  // Social smalltalk must not match here ("whats up", "whats shaking").
  if (RegExp(
        r'\b(whats?|what is)\s+(up|shaking|good|new|happening|crackin|crackling)\b|'
        r'\bhows?\s+it\s+(going|hanging)\b',
      ).hasMatch(t)) {
    return null;
  }

  if (RegExp(
        r'\b(what|whats|tell me)\s+(the\s+)?(time\s+)?zone\b|'
        r'\b(which|what)\s+timezone\b|'
        r'\bwhat\s+time\s+zone\b|'
        r'\b(are we in|is this)\s+(eastern|pacific|central|mountain|utc)\b',
      ).hasMatch(t)) {
    return const ClockIntent(ClockIntentKind.timezone);
  }

  if (RegExp(
        r'\b(what|whats|which)\s+(season|time of year)\b|'
        r'\bwhat\s+season\s+(is it|are we in)\b|'
        r'\bare we (in|still in)\s+(spring|summer|fall|autumn|winter)\b',
      ).hasMatch(t)) {
    return const ClockIntent(ClockIntentKind.season);
  }

  if (RegExp(
        r'\b(what|whats|tell me)\s+(the\s+)?(date|day)\b|'
        r'\bwhat\s+is\s+the\s+(date|day)\b|'
        r'\bwhat\s+day\s+(is it|of the week)\b|'
        r'\bwhats?\s+todays?\s+date\b|'
        r'\b(todays?|current)\s+date\b',
      ).hasMatch(t)) {
    if (RegExp(r'\b(day of the week|what day)\b').hasMatch(t) &&
        !RegExp(r'\bdate\b').hasMatch(t)) {
      return const ClockIntent(ClockIntentKind.day);
    }
    return const ClockIntent(ClockIntentKind.date);
  }

  if (RegExp(
        r'\b(what|whats|tell me)\s+(the\s+)?time\b|'
        r'\bwhat\s+time\s+is it\b|'
        r'\bgot the time\b|'
        r'\bcurrent time\b|'
        r'\bdo you (have|know) the time\b',
      ).hasMatch(t)) {
    if (RegExp(r'\b(date|day|season|zone)\b').hasMatch(t)) {
      return const ClockIntent(ClockIntentKind.datetime);
    }
    return const ClockIntent(ClockIntentKind.time);
  }

  if (RegExp(
        r'\b(date and time|time and date|day and time)\b',
      ).hasMatch(t)) {
    return const ClockIntent(ClockIntentKind.datetime);
  }

  return null;
}

/// Spoken answer from the terminal's local clock.
String formatClockAnswer(
  ClockIntent intent, {
  DateTime Function()? now,
  String? timezoneLabel,
}) {
  final dt = (now ?? DateTime.now)();
  final tz = _timezoneSpoken(dt, timezoneLabel);

  switch (intent.kind) {
    case ClockIntentKind.time:
      return "It's ${_formatTime(dt)}.";
    case ClockIntentKind.day:
      return "It's ${_weekday(dt)}.";
    case ClockIntentKind.date:
      return 'Today is ${_weekday(dt)}, ${_month(dt)} ${_ordinal(dt.day)}, ${dt.year}.';
    case ClockIntentKind.timezone:
      return 'This terminal is on $tz.';
    case ClockIntentKind.season:
      return "It's ${_season(dt)} here.";
    case ClockIntentKind.datetime:
      return "It's ${_formatTime(dt)} on ${_weekday(dt)}, "
          '${_month(dt)} ${_ordinal(dt.day)}. We are on $tz.';
  }
}

String _timezoneSpoken(DateTime dt, String? label) {
  final configured = label?.trim() ?? '';
  if (configured.isNotEmpty) {
    final abbr = dt.timeZoneName.trim();
    if (abbr.isNotEmpty && abbr.toLowerCase() != configured.toLowerCase()) {
      return '$configured ($abbr)';
    }
    return configured;
  }
  final abbr = dt.timeZoneName.trim();
  if (abbr.isNotEmpty) return abbr;
  final hours = dt.timeZoneOffset.inHours;
  final mins = dt.timeZoneOffset.inMinutes.remainder(60).abs();
  final sign = hours >= 0 ? '+' : '-';
  final hh = hours.abs().toString().padLeft(2, '0');
  final mm = mins.toString().padLeft(2, '0');
  return 'UTC$sign$hh:$mm';
}

String _formatTime(DateTime dt) {
  final hour24 = dt.hour;
  final minute = dt.minute.toString().padLeft(2, '0');
  final period = hour24 >= 12 ? 'PM' : 'AM';
  var hour12 = hour24 % 12;
  if (hour12 == 0) hour12 = 12;
  return '$hour12:$minute $period';
}

String _weekday(DateTime dt) {
  const names = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  return names[dt.weekday - 1];
}

String _month(DateTime dt) {
  const names = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  return names[dt.month - 1];
}

String _ordinal(int day) {
  if (day >= 11 && day <= 13) return '${day}th';
  return switch (day % 10) {
    1 => '${day}st',
    2 => '${day}nd',
    3 => '${day}rd',
    _ => '${day}th',
  };
}

/// Northern-hemisphere meteorological seasons from the terminal month.
String _season(DateTime dt) {
  return switch (dt.month) {
    12 || 1 || 2 => 'winter',
    3 || 4 || 5 => 'spring',
    6 || 7 || 8 => 'summer',
    _ => 'fall',
  };
}
