import 'package:comstar_bridge/terminal_intent.dart';
import 'package:test/test.dart';

void main() {
  test('sleep phrases', () {
    expect(parseTerminalIntent('Go to sleep.')?.kind, TerminalIntentKind.sleepEnter);
    expect(
      parseTerminalIntent('Put yourself to sleep.')?.kind,
      TerminalIntentKind.sleepEnter,
    );
  });

  test('mute / unmute', () {
    expect(parseTerminalIntent('mute yourself')?.kind, TerminalIntentKind.volumeMute);
    expect(parseTerminalIntent('unmute')?.kind, TerminalIntentKind.volumeUnmute);
  });

  test('volume adjust', () {
    expect(parseTerminalIntent('volume up')?.delta, 10);
    expect(parseTerminalIntent('turn it down')?.delta, -10);
  });

  test('non-control returns null', () {
    expect(parseTerminalIntent('what time is it'), isNull);
    expect(parseTerminalIntent('how are you'), isNull);
  });
}
