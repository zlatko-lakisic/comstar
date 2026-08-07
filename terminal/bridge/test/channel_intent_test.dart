import 'package:comstar_bridge/channel_intent.dart';
import 'package:test/test.dart';

void main() {
  test('link telegram', () {
    final i = parseChannelIntent('link my telegram');
    expect(i?.kind, ChannelIntentKind.connect);
    expect(i?.provider, 'telegram');
  });

  test('connect whatsapp', () {
    final i = parseChannelIntent('connect WhatsApp');
    expect(i?.kind, ChannelIntentKind.connect);
    expect(i?.provider, 'whatsapp');
  });

  test('signal status', () {
    final i = parseChannelIntent('is my signal linked');
    expect(i?.kind, ChannelIntentKind.status);
    expect(i?.provider, 'signal');
  });

  test('unlink telegram', () {
    final i = parseChannelIntent('unlink telegram');
    expect(i?.kind, ChannelIntentKind.unlink);
    expect(i?.provider, 'telegram');
  });

  test('ignores google-only phrases', () {
    expect(parseChannelIntent('connect my google'), isNull);
  });
}
