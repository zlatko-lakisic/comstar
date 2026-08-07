import 'package:comstar_bridge/announce/channel_surface.dart';
import 'package:comstar_bridge/announce/types.dart';
import 'package:test/test.dart';

void main() {
  group('shouldDeliverToChannel', () {
    test('presence at terminal suppresses channel', () {
      expect(
        shouldDeliverToChannel(
          recipientUserid: 'zlatko',
          priority: AnnouncementPriority.urgent,
          recipientPresentAtTerminal: true,
          alreadyDelivered: false,
        ),
        ChannelDeliverDecision.skip,
      );
    });

    test('already delivered skips under concurrent evaluation', () {
      expect(
        shouldDeliverToChannel(
          recipientUserid: 'zlatko',
          priority: AnnouncementPriority.urgent,
          recipientPresentAtTerminal: false,
          alreadyDelivered: true,
        ),
        ChannelDeliverDecision.skip,
      );
    });

    test('absent urgent delivers', () {
      expect(
        shouldDeliverToChannel(
          recipientUserid: 'zlatko',
          priority: AnnouncementPriority.urgent,
          recipientPresentAtTerminal: false,
          alreadyDelivered: false,
        ),
        ChannelDeliverDecision.deliver,
      );
    });

    test('absent normal holds for terminal', () {
      expect(
        shouldDeliverToChannel(
          recipientUserid: 'zlatko',
          priority: AnnouncementPriority.normal,
          recipientPresentAtTerminal: false,
          alreadyDelivered: false,
        ),
        ChannelDeliverDecision.holdForTerminal,
      );
    });
  });

  group('recipientPresentAtTerminal', () {
    test('engaged matching userid is present', () {
      expect(
        recipientPresentAtTerminal(
          cachedUserid: 'zlatko',
          stateName: 'engaged',
          recipient: 'zlatko',
        ),
        isTrue,
      );
    });

    test('ambient is absent', () {
      expect(
        recipientPresentAtTerminal(
          cachedUserid: 'zlatko',
          stateName: 'ambient',
          recipient: 'zlatko',
        ),
        isFalse,
      );
    });

    test('wrong userid is absent', () {
      expect(
        recipientPresentAtTerminal(
          cachedUserid: 'other',
          stateName: 'engaged',
          recipient: 'zlatko',
        ),
        isFalse,
      );
    });

    test('any recipient never counts as present for channel', () {
      expect(
        recipientPresentAtTerminal(
          cachedUserid: 'zlatko',
          stateName: 'engaged',
          recipient: 'any',
        ),
        isFalse,
      );
    });
  });
}
