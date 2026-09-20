import 'package:comstar_bridge/google_data_intent.dart';
import 'package:test/test.dart';

void main() {
  test('calendar today phrases', () {
    expect(
      parseGoogleDataIntent("What's on my Google Calendar today?")?.kind,
      GoogleDataIntentKind.calendarToday,
    );
    expect(
      parseGoogleDataIntent('What meetings do I have today?')?.kind,
      GoogleDataIntentKind.calendarToday,
    );
    expect(
      parseGoogleDataIntent('What do we have planned for today?')?.kind,
      GoogleDataIntentKind.calendarToday,
    );
  });

  test('calendar list phrases', () {
    expect(
      parseGoogleDataIntent('List my Google calendars')?.kind,
      GoogleDataIntentKind.calendarList,
    );
  });

  test('drive and gmail', () {
    expect(
      parseGoogleDataIntent('What is in my Google Drive?')?.kind,
      GoogleDataIntentKind.driveList,
    );
    expect(
      parseGoogleDataIntent("What's in my Gmail today?")?.kind,
      GoogleDataIntentKind.gmailToday,
    );
  });

  test('calendar tomorrow and next', () {
    expect(
      parseGoogleDataIntent("What's on my calendar tomorrow?")?.kind,
      GoogleDataIntentKind.calendarTomorrow,
    );
    expect(
      parseGoogleDataIntent('What meetings do I have tomorrow?')?.kind,
      GoogleDataIntentKind.calendarTomorrow,
    );
    expect(
      parseGoogleDataIntent("What's my next meeting?")?.kind,
      GoogleDataIntentKind.calendarNext,
    );
    expect(
      parseGoogleDataIntent('When is my next appointment?')?.kind,
      GoogleDataIntentKind.calendarNext,
    );
  });

  test('spoken summaries', () {
    expect(speakCalendarToday(const []), contains('clear'));
    expect(
      speakCalendarToday(const ['Continua Health call']),
      contains('Continua Health call'),
    );
    expect(speakCalendarTomorrow(const []), contains('tomorrow'));
    expect(speakCalendarNext(null), contains('upcoming'));
    expect(speakCalendarNext('Dentist'), contains('Dentist'));
    expect(speakDriveCount(0), contains('limited Drive'));
    expect(speakGmailSubjects(const ['Hello']), contains('Hello'));
  });
}
