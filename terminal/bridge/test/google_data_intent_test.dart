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

  test('spoken summaries', () {
    expect(speakCalendarToday(const []), contains('clear'));
    expect(
      speakCalendarToday(const ['Continua Health call']),
      contains('Continua Health call'),
    );
    expect(speakDriveCount(0), contains('limited Drive'));
    expect(speakGmailSubjects(const ['Hello']), contains('Hello'));
  });
}
