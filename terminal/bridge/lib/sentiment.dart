/// LAN-local reply sentiment → avatar mood enum (CONTRACTS §9 Phase 2).
///
/// Never phones home. Heuristic only; AO may later tag replies explicitly.
library;

const kMoodNeutral = 'neutral';
const kMoodHappy = 'happy';
const kMoodConcerned = 'concerned';
const kMoodThinking = 'thinking';
const kMoodCelebratory = 'celebratory';

const kMoods = {
  kMoodNeutral,
  kMoodHappy,
  kMoodConcerned,
  kMoodThinking,
  kMoodCelebratory,
};

/// Map reply text to a mood for `speak.mood` / emblem gesture.
String inferMoodFromText(String text) {
  final t = text.toLowerCase();
  if (t.trim().isEmpty) return kMoodNeutral;

  if (RegExp(
        r'\b(congratulations|congratulation|celebrate|celebrating|'
        r'awesome|wonderful|fantastic|hooray)\b',
      ).hasMatch(t)) {
    return kMoodCelebratory;
  }
  if (RegExp(
        r'\b(sorry|unfortunately|error|fail|unable|can.?t|cannot|problem|'
        r'issue|worried|concern|alert|warning|offline|down)\b',
      ).hasMatch(t)) {
    return kMoodConcerned;
  }
  if (RegExp(
        r'\b(let me (check|see|think|look)|one (moment|sec)|working on|'
        r'thinking|searching|looking up)\b',
      ).hasMatch(t)) {
    return kMoodThinking;
  }
  if (RegExp(
        r'\b(great|glad|happy|pleasure|welcome|nice|'
        r'good morning|good afternoon|good evening|good news|'
        r'hello|hi there)\b',
      ).hasMatch(t)) {
    return kMoodHappy;
  }
  return kMoodNeutral;
}

/// Normalize an optional AO / config mood tag; fall back to [inferMoodFromText].
String resolveSpeakMood(String text, {String? explicit}) {
  final tag = explicit?.trim().toLowerCase();
  if (tag != null && kMoods.contains(tag)) return tag;
  return inferMoodFromText(text);
}
