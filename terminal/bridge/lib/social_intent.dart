import 'dart:math';

/// Local social / smalltalk intents when there is no task context.
///
/// Answered on the bridge (phrase bank + templates) so AO is not burned for
/// "how's it going" style turns.
enum SocialIntentKind {
  howAreYou,
  whatsUp,
  greeting,
  thanks,
}

class SocialIntent {
  const SocialIntent(this.kind);
  final SocialIntentKind kind;
}

/// Returns a [SocialIntent] for clear social greetings / check-ins.
SocialIntent? parseSocialIntent(String text) {
  final t = text
      .toLowerCase()
      .replaceAll(RegExp(r"['\u2019]"), '')
      .replaceAll(RegExp(r'[^\w\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (t.isEmpty) return null;

  // Never steal clock / device questions.
  if (RegExp(
        r'\b(time|date|timezone|time zone|season|volume|mute|sleep)\b',
      ).hasMatch(t)) {
    return null;
  }

  if (RegExp(
        r'\b(thanks|thank you|thankyou|appreciate it|much appreciated)\b',
      ).hasMatch(t)) {
    return const SocialIntent(SocialIntentKind.thanks);
  }

  if (RegExp(
        r'\b(how are you|howre you|how r you|how you doing|how you doin|'
        r'hows it going|hows it hangin|hows it hanging|'
        r'how have you been|how ya doing|how are things)\b',
      ).hasMatch(t)) {
    return const SocialIntent(SocialIntentKind.howAreYou);
  }

  if (RegExp(
        r'\b(whats? up|what is up|whats? shaking|whats? good|whats? new|'
        r'whats? happening|whats? crackin|whats? crackling|'
        r'what is shaking|what is good|wassup|wussup)\b',
      ).hasMatch(t) ||
      t == 'sup' ||
      t == 'yo') {
    return const SocialIntent(SocialIntentKind.whatsUp);
  }

  if (RegExp(
        r'^(hi|hello|hey there|hiya|howdy|good morning|good afternoon|'
        r'good evening|good day|morning|afternoon|evening)(\s+comstar)?$',
      ).hasMatch(t) ||
      RegExp(
        r'\b(good morning|good afternoon|good evening|hello there|hi there)\b',
      ).hasMatch(t)) {
    return const SocialIntent(SocialIntentKind.greeting);
  }

  return null;
}

/// Pick a short social reply. Prefer [bankLine] when non-empty.
String formatSocialAnswer(
  SocialIntent intent, {
  String? bankLine,
  String? name,
  Random? random,
}) {
  final fromBank = bankLine?.trim();
  if (fromBank != null && fromBank.isNotEmpty) {
    return fromBank;
  }

  final who = (name != null && name.trim().isNotEmpty) ? name.trim() : null;
  final rng = random ?? Random();
  final pool = _fallbacks(intent.kind, who);
  return pool[rng.nextInt(pool.length)];
}

List<String> _fallbacks(SocialIntentKind kind, String? name) {
  final n = name;
  switch (kind) {
    case SocialIntentKind.howAreYou:
      return [
        if (n != null) "I'm doing well, $n. What can I help with?",
        "I'm doing well — standing by if you need anything.",
        "All good here. What's on your mind?",
        "Feeling useful. How can I help?",
      ];
    case SocialIntentKind.whatsUp:
      return [
        if (n != null) "Not much, $n — just hanging out in the hallway. You?",
        "Just keeping an eye on the hallway. What's up with you?",
        "Same old — lights, chatter, and waiting for a job.",
        "Chillin' at the terminal. What do you need?",
      ];
    case SocialIntentKind.greeting:
      return [
        if (n != null) 'Hey $n.',
        if (n != null) 'Hi $n — good to see you.',
        'Hey there.',
        'Hello.',
        'Hi — what can I do for you?',
      ];
    case SocialIntentKind.thanks:
      return [
        if (n != null) "You're welcome, $n.",
        "You're welcome.",
        'Anytime.',
        'Happy to help.',
      ];
  }
}
