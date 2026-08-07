import 'package:comstar_bridge/home_data_intent.dart';
import 'package:test/test.dart';

void main() {
  test('detects torrent / download questions', () {
    expect(
      parseHomeDataIntent('What torrents am I currently downloading?')?.kind,
      HomeDataIntentKind.torrentsDownloading,
    );
    expect(
      parseHomeDataIntent('What torrents do I have downloading?')?.kind,
      HomeDataIntentKind.torrentsDownloading,
    );
    expect(
      parseHomeDataIntent('Any torrents downloading?')?.kind,
      HomeDataIntentKind.torrentsDownloading,
    );
    expect(
      parseHomeDataIntent('how many torrents are active')?.kind,
      HomeDataIntentKind.torrentsDownloading,
    );
  });

  test('ignores unrelated speech', () {
    expect(parseHomeDataIntent('what time is it'), isNull);
    expect(parseHomeDataIntent('turn on the lights'), isNull);
    expect(parseHomeDataIntent('go to sleep'), isNull);
  });

  test('detects irrigation / watering questions', () {
    expect(
      parseHomeDataIntent('How much water did our garden get yesterday?')?.kind,
      HomeDataIntentKind.irrigationSummary,
    );
    expect(
      parseHomeDataIntent('How much irrigation did my home get yesterday?')
          ?.kind,
      HomeDataIntentKind.irrigationSummary,
    );
    expect(
      parseHomeDataIntent('Tell me how much irrigation the east lawn got')?.kind,
      HomeDataIntentKind.irrigationSummary,
    );
  });

  test('detects network / IP / bandwidth questions', () {
    expect(
      parseHomeDataIntent("What's my WAN IP?")?.kind,
      HomeDataIntentKind.networkSummary,
    );
    expect(
      parseHomeDataIntent('What is the public IP address?')?.kind,
      HomeDataIntentKind.networkSummary,
    );
    expect(
      parseHomeDataIntent('What is the Home Assistant local IP?')?.kind,
      HomeDataIntentKind.networkSummary,
    );
    expect(
      parseHomeDataIntent('How is the MikroTik WAN bandwidth?')?.kind,
      HomeDataIntentKind.networkSummary,
    );
    expect(
      parseHomeDataIntent('What was the last speedtest download speed?')?.kind,
      HomeDataIntentKind.networkSummary,
    );
    expect(
      parseHomeDataIntent('What is the Mostar public IP?')?.kind,
      HomeDataIntentKind.networkSummary,
    );
  });

  test('detects who is home / presence questions', () {
    expect(
      parseHomeDataIntent("Who's home?")?.kind,
      HomeDataIntentKind.presenceHome,
    );
    expect(
      parseHomeDataIntent('Is anyone home?')?.kind,
      HomeDataIntentKind.presenceHome,
    );
    expect(
      parseHomeDataIntent('who is in the house')?.kind,
      HomeDataIntentKind.presenceHome,
    );
  });

  test('detects where is person questions', () {
    final where = parseHomeDataIntent('Where is Adna?');
    expect(where?.kind, HomeDataIntentKind.whereIsPerson);
    expect(where?.personName, 'Adna');

    expect(
      parseHomeDataIntent("Where's Zlatko right now?")?.personName,
      'Zlatko',
    );
    expect(
      parseHomeDataIntent('Is Adna home?')?.kind,
      HomeDataIntentKind.whereIsPerson,
    );
    expect(
      parseHomeDataIntent('Is Ibrica at home?')?.personName,
      'Ibrica',
    );
  });

  test('where is does not steal aggregate presence', () {
    expect(parseHomeDataIntent('Where is everyone?'), isNull);
    expect(
      parseHomeDataIntent("Who's home?")?.kind,
      HomeDataIntentKind.presenceHome,
    );
  });

  test('when did leave intents', () {
    final named = parseHomeDataIntent('When did Adna leave?');
    expect(named?.kind, HomeDataIntentKind.whenPersonLeft);
    expect(named?.personName, 'Adna');

    final home = parseHomeDataIntent('When did Adna leave home?');
    expect(home?.kind, HomeDataIntentKind.whenPersonLeft);
    expect(home?.personName, 'Adna');

    final pronoun = parseHomeDataIntent('When did they leave?');
    expect(pronoun?.kind, HomeDataIntentKind.whenPersonLeft);
    expect(pronoun?.personName, isNull);

    final gone = parseHomeDataIntent('How long has she been gone?');
    expect(gone?.kind, HomeDataIntentKind.whenPersonLeft);
    expect(gone?.personName, isNull);
  });

  test('where is they uses pronoun context', () {
    final they = parseHomeDataIntent('Where are they?');
    expect(they?.kind, HomeDataIntentKind.whereIsPerson);
    expect(they?.personName, isNull);

    final she = parseHomeDataIntent('Where is she?');
    expect(she?.kind, HomeDataIntentKind.whereIsPerson);
    expect(she?.personName, isNull);
  });
}
