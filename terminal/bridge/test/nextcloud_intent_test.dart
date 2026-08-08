import 'package:comstar_bridge/nextcloud_intent.dart';
import 'package:test/test.dart';

void main() {
  group('parseNextcloudIntent', () {
    test('connect', () {
      expect(
        parseNextcloudIntent('connect my Nextcloud')?.kind,
        NextcloudIntentKind.connect,
      );
      expect(
        parseNextcloudIntent('link my cloud')?.kind,
        NextcloudIntentKind.connect,
      );
    });

    test('status', () {
      expect(
        parseNextcloudIntent('is nextcloud connected')?.kind,
        NextcloudIntentKind.status,
      );
    });

    test('unlink', () {
      expect(
        parseNextcloudIntent('disconnect nextcloud')?.kind,
        NextcloudIntentKind.unlink,
      );
    });

    test('ignores google-only', () {
      expect(parseNextcloudIntent('connect my google'), isNull);
      expect(parseNextcloudIntent('what is on my calendar'), isNull);
    });
  });
}
