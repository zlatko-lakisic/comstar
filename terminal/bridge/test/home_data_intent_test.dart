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
    expect(
      parseHomeDataIntent('How much water did our garden get yesterday?'),
      isNull,
    );
  });
}
