import 'package:comstar_bridge/clock_intent.dart';
import 'package:test/test.dart';

void main() {
  test('time phrases', () {
    expect(parseClockIntent('What time is it?')?.kind, ClockIntentKind.time);
    expect(parseClockIntent('got the time')?.kind, ClockIntentKind.time);
    expect(parseClockIntent("what's the time")?.kind, ClockIntentKind.time);
  });

  test('date and day', () {
    expect(parseClockIntent('what day is it')?.kind, ClockIntentKind.day);
    expect(parseClockIntent("what's today's date")?.kind, ClockIntentKind.date);
    expect(parseClockIntent('what is the date')?.kind, ClockIntentKind.date);
  });

  test('timezone and season', () {
    expect(parseClockIntent('what timezone are we in')?.kind, ClockIntentKind.timezone);
    expect(parseClockIntent('what season is it')?.kind, ClockIntentKind.season);
  });

  test('social does not match clock', () {
    expect(parseClockIntent("what's up"), isNull);
    expect(parseClockIntent("what's shaking"), isNull);
    expect(parseClockIntent('how are you'), isNull);
  });

  test('formatClockAnswer uses injected now', () {
    final fixed = DateTime(2026, 8, 4, 21, 52); // Tuesday evening summer
    expect(
      formatClockAnswer(
        const ClockIntent(ClockIntentKind.time),
        now: () => fixed,
      ),
      "It's 9:52 PM.",
    );
    expect(
      formatClockAnswer(
        const ClockIntent(ClockIntentKind.date),
        now: () => fixed,
      ),
      'Today is Tuesday, August 4th, 2026.',
    );
    expect(
      formatClockAnswer(
        const ClockIntent(ClockIntentKind.season),
        now: () => fixed,
      ),
      "It's summer here.",
    );
    expect(
      formatClockAnswer(
        const ClockIntent(ClockIntentKind.timezone),
        now: () => fixed,
        timezoneLabel: 'America/New_York',
      ),
      contains('America/New_York'),
    );
  });
}
