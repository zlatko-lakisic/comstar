import 'package:comstar_bridge/announce/gate.dart';
import 'package:comstar_bridge/announce/types.dart';
import 'package:comstar_bridge/attention/states.dart';
import 'package:test/test.dart';

Announcement _ann({
  String recipient = 'zlatko',
  AnnouncementPriority priority = AnnouncementPriority.normal,
  String intent = 'ping',
}) {
  final now = DateTime.utc(2026, 8, 7, 15);
  return Announcement(
    id: 'a1',
    recipient: recipient,
    source: AnnouncementSource.schedule,
    intent: intent,
    priority: priority,
    notBefore: now,
    expiresAt: now.add(const Duration(hours: 1)),
  );
}

void main() {
  final gate = AnnouncementGate.fromQuietStrings(
    start: '22:00',
    end: '07:00',
  );
  final afternoon = DateTime(2026, 8, 7, 15, 0);
  final night = DateTime(2026, 8, 7, 23, 0);

  GateDecision eval({
    required AttentionState state,
    String? userid = 'zlatko',
    bool guest = false,
    bool playing = false,
    bool announced = false,
    List<Announcement>? due,
    DateTime? now,
  }) {
    return gate.evaluate(
      state: state,
      userid: userid,
      guest: guest,
      playing: playing,
      announcedThisEngage: announced,
      due: due ?? [_ann()],
      localNow: now ?? afternoon,
      logHolds: false,
    );
  }

  test('ambient holds both priorities', () {
    expect(eval(state: const Ambient()).reason, GateHoldReason.ambient);
    expect(
      eval(
        state: const Ambient(),
        due: [_ann(priority: AnnouncementPriority.urgent)],
      ).reason,
      GateHoldReason.ambient,
    );
  });

  test('noticed holds both priorities — security boundary', () {
    expect(eval(state: const Noticed(), userid: null).reason, GateHoldReason.noticed);
    expect(
      eval(
        state: const Noticed(),
        userid: null,
        due: [_ann(priority: AnnouncementPriority.urgent)],
      ).reason,
      GateHoldReason.noticed,
    );
  });

  test('listening and responding hold', () {
    expect(eval(state: const Listening()).reason, GateHoldReason.listening);
    expect(eval(state: const Responding()).reason, GateHoldReason.responding);
  });

  test('engaged matching identity delivers', () {
    final d = eval(state: const Engaged());
    expect(d.deliver, isTrue);
    expect(d.items, hasLength(1));
  });

  test('engaged identity mismatch holds — security boundary', () {
    expect(
      eval(state: const Engaged(), userid: 'alice', due: [_ann(recipient: 'bob')])
          .reason,
      GateHoldReason.identityMismatch,
    );
  });

  test('engaged recipient any delivers', () {
    expect(
      eval(state: const Engaged(), due: [_ann(recipient: 'any')]).deliver,
      isTrue,
    );
  });

  test('quiet hours hold normal deliver urgent', () {
    expect(
      eval(state: const Engaged(), now: night).reason,
      GateHoldReason.quietHours,
    );
    expect(
      eval(
        state: const Engaged(),
        now: night,
        due: [_ann(priority: AnnouncementPriority.urgent)],
      ).deliver,
      isTrue,
    );
  });

  test('invariant 8 — already announced this engage holds', () {
    expect(
      eval(state: const Engaged(), announced: true).reason,
      GateHoldReason.alreadyAnnouncedThisEngage,
    );
  });

  test('coalesce three vs four', () {
    final items = [
      _ann(intent: 'One'),
      _ann(intent: 'Two'),
      _ann(intent: 'Three'),
      _ann(intent: 'Four'),
    ];
    final three = coalesceAnnouncementText(items.take(3).toList());
    expect(three.contains('Four'), isFalse);
    final four = coalesceAnnouncementText(items);
    expect(four, contains('a few other things'));
  });
}
