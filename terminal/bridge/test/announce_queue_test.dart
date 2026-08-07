import 'dart:io';

import 'package:comstar_bridge/announce/queue.dart';
import 'package:comstar_bridge/announce/types.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late DateTime now;
  late AnnouncementQueue queue;

  Announcement draft({
    String id = '',
    String recipient = 'zlatko',
    String intent = 'say hi',
    AnnouncementPriority priority = AnnouncementPriority.normal,
    Duration notBefore = Duration.zero,
    Duration ttl = const Duration(hours: 1),
    String? dedupeKey,
  }) {
    return Announcement(
      id: id,
      recipient: recipient,
      source: AnnouncementSource.schedule,
      intent: intent,
      priority: priority,
      notBefore: now.add(notBefore),
      expiresAt: now.add(ttl),
      dedupeKey: dedupeKey,
    );
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('comstar-announce-');
    now = DateTime.utc(2026, 8, 7, 18, 0, 0);
    queue = AnnouncementQueue(
      dbPath: '${tmp.path}/announce.db',
      clock: () => now,
    );
    queue.open();
  });

  tearDown(() {
    queue.close();
    tmp.deleteSync(recursive: true);
  });

  test('enqueue + duePending respects notBefore under fake clock', () {
    queue.enqueue(draft(intent: 'later', notBefore: const Duration(minutes: 5)));
    expect(queue.duePending(), isEmpty);

    now = now.add(const Duration(minutes: 5));
    final due = queue.duePending();
    expect(due, hasLength(1));
    expect(due.single.intent, 'later');
  });

  test('TTL expiry is silent and removes from duePending', () {
    final a = queue.enqueue(
      draft(intent: 'expiring', ttl: const Duration(minutes: 10)),
    );
    expect(a.status, AnnouncementStatus.pending);

    now = now.add(const Duration(minutes: 11));
    final n = queue.expireDue();
    expect(n, 1);
    expect(queue.duePending(), isEmpty);
    expect(queue.get(a.id)?.status, AnnouncementStatus.expired);
  });

  test('dedupe collapses repeats for pending rows', () {
    final first = queue.enqueue(
      draft(intent: 'v1', dedupeKey: 'cal-2pm'),
    );
    final second = queue.enqueue(
      draft(intent: 'v2', dedupeKey: 'cal-2pm'),
    );
    expect(second.id, first.id);
    expect(queue.list(status: AnnouncementStatus.pending), hasLength(1));
  });

  test('survives reopen (restart)', () {
    final a = queue.enqueue(draft(intent: 'persist-me'));
    queue.close();

    final again = AnnouncementQueue(
      dbPath: '${tmp.path}/announce.db',
      clock: () => now,
    )..open();
    expect(again.get(a.id)?.intent, 'persist-me');
    expect(again.duePending(), hasLength(1));
    again.close();
  });

  test('urgent sorts before normal when both due', () {
    queue.enqueue(draft(intent: 'normal', priority: AnnouncementPriority.normal));
    now = now.add(const Duration(seconds: 1));
    queue.enqueue(draft(intent: 'urgent', priority: AnnouncementPriority.urgent));
    final due = queue.duePending();
    expect(due.map((e) => e.intent).toList(), ['urgent', 'normal']);
  });

  test('markDelivered updates status', () {
    final a = queue.enqueue(draft(intent: 'go'));
    queue.markDelivered(a.id, text: 'Spoken line');
    final got = queue.get(a.id)!;
    expect(got.status, AnnouncementStatus.delivered);
    expect(got.text, 'Spoken line');
    expect(queue.duePending(), isEmpty);
  });

  test('recipient filter includes any', () {
    queue.enqueue(draft(recipient: 'alice', intent: 'for alice'));
    queue.enqueue(draft(recipient: 'any', intent: 'for anyone'));
    final due = queue.duePending(recipient: 'alice');
    expect(due.map((e) => e.intent), containsAll(['for alice', 'for anyone']));
  });
}
