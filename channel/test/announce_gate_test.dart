import 'package:comstar_channel/announce_gate.dart';
import 'package:test/test.dart';

void main() {
  ChannelAnnounceContext ctx({
    bool present = false,
    bool delivered = false,
    AnnouncePriority priority = AnnouncePriority.urgent,
  }) {
    return ChannelAnnounceContext(
      recipientUserid: 'zlatko',
      priority: priority,
      recipientPresentAtTerminal: present,
      alreadyDelivered: delivered,
    );
  }

  test('present at terminal suppresses channel', () {
    expect(
      shouldDeliverToChannel(ctx(present: true)),
      ChannelDeliverDecision.skip,
    );
  });

  test('already delivered skips', () {
    expect(
      shouldDeliverToChannel(ctx(delivered: true)),
      ChannelDeliverDecision.skip,
    );
  });

  test('absent urgent delivers', () {
    expect(
      shouldDeliverToChannel(ctx()),
      ChannelDeliverDecision.deliver,
    );
  });

  test('absent normal holds for terminal', () {
    expect(
      shouldDeliverToChannel(ctx(priority: AnnouncePriority.normal)),
      ChannelDeliverDecision.holdForTerminal,
    );
  });
}
