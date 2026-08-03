/// Read-only Google Workspace voice intents (calendar / drive / gmail).
enum GoogleDataIntentKind { calendarToday, calendarList, driveList, gmailToday }

class GoogleDataIntent {
  const GoogleDataIntent(this.kind);
  final GoogleDataIntentKind kind;
}

GoogleDataIntent? parseGoogleDataIntent(String text) {
  final t = text
      .toLowerCase()
      .replaceAll(RegExp(r'[^\w\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (t.isEmpty) return null;

  if (RegExp(
        r'\b(gmail|inbox|e ?mails?|emails?)\b',
      ).hasMatch(t)) {
    return const GoogleDataIntent(GoogleDataIntentKind.gmailToday);
  }

  if (RegExp(
        r'\b(google )?drive\b|\bmy (files|docs)\b',
      ).hasMatch(t)) {
    return const GoogleDataIntent(GoogleDataIntentKind.driveList);
  }

  // Today / schedule before "list calendars" — "what's on my calendar" is today.
  if (RegExp(
        r'\b(calendar|schedule|meetings?|appointments?)\b|'
        r'\bon my (google )?calendar\b|'
        r'\bwhat.*(today|tonight|this (morning|afternoon|evening))\b.*\b'
        r'(calendar|schedule|meetings?)\b|'
        r'\b(calendar|schedule|meetings?).*\b(today|tonight)\b',
      ).hasMatch(t)) {
    // Exception: explicit multi-calendar listing.
    if (RegExp(
          r'\b(list|names? of)\b.*\bcalendars\b|'
          r'\bcalendars\b.*\b(list|names?)\b|'
          r'\bwhat calendars\b|\bwhich calendars\b',
        ).hasMatch(t)) {
      return const GoogleDataIntent(GoogleDataIntentKind.calendarList);
    }
    return const GoogleDataIntent(GoogleDataIntentKind.calendarToday);
  }

  if (RegExp(
        r'\b(list|what|which|show)\b.*\bcalendars\b|'
        r'\bcalendars\b.*\b(list|names?|have)\b',
      ).hasMatch(t)) {
    return const GoogleDataIntent(GoogleDataIntentKind.calendarList);
  }

  return null;
}

String speakCalendarToday(List<String> titles) {
  if (titles.isEmpty) {
    return 'Your primary Google Calendar looks clear for today.';
  }
  if (titles.length == 1) {
    return 'On your calendar today: ${titles.first}.';
  }
  if (titles.length == 2) {
    return 'On your calendar today: ${titles[0]}, and ${titles[1]}.';
  }
  final head = titles.take(titles.length - 1).join(', ');
  return 'On your calendar today: $head, and ${titles.last}.';
}

String speakCalendarList(List<String> names) {
  if (names.isEmpty) {
    return 'I could not find any Google calendars on this account.';
  }
  if (names.length == 1) {
    return 'You have one Google calendar called ${names.first}.';
  }
  if (names.length == 2) {
    return 'Your Google calendars are ${names[0]} and ${names[1]}.';
  }
  final head = names.take(3).join(', ');
  final more = names.length > 3 ? ', and ${names.length - 3} more' : '';
  return 'Your Google calendars include $head$more.';
}

String speakDriveCount(int count) {
  if (count <= 0) {
    return 'I do not see Drive files for this linked account yet. '
        'Voice pairing only allows limited Drive access.';
  }
  return 'I can see $count Drive file${count == 1 ? '' : 's'} with this link.';
}

String speakGmailSubjects(List<String> subjects) {
  if (subjects.isEmpty) {
    return 'I do not see recent Gmail messages for today.';
  }
  if (subjects.length == 1) {
    return 'A recent email subject is ${subjects.first}.';
  }
  return 'Recent email subjects include ${subjects.take(2).join(', ')}.';
}
