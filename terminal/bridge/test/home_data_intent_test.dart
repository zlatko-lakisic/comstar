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
}
