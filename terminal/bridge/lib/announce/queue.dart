import 'dart:ffi';
import 'dart:io';

import 'package:comstar_bridge/announce/types.dart';
import 'package:comstar_bridge/log.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

var _sqliteOpenConfigured = false;

void _ensureSqliteOpen() {
  if (_sqliteOpenConfigured) return;
  _sqliteOpenConfigured = true;
  // Debian/Pi ships libsqlite3.so.0 without an unversioned .so unless -dev is installed.
  open.overrideFor(OperatingSystem.linux, () {
    for (final name in const [
      'libsqlite3.so.0',
      'libsqlite3.so',
      '/usr/lib/aarch64-linux-gnu/libsqlite3.so.0',
      '/lib/aarch64-linux-gnu/libsqlite3.so.0',
    ]) {
      try {
        return DynamicLibrary.open(name);
      } catch (_) {}
    }
    return DynamicLibrary.open('libsqlite3.so.0');
  });
}

/// Persistent announcement queue (M10.1). Sources enqueue; gate delivers.
///
/// Expiry is silent (status → expired) and logged. Dedupe collapses pending
/// rows that share [Announcement.dedupeKey].
class AnnouncementQueue {
  AnnouncementQueue({
    required this.dbPath,
    DateTime Function()? clock,
    Uuid? uuid,
  })  : _clock = clock ?? DateTime.now,
        _uuid = uuid ?? const Uuid();

  final String dbPath;
  final DateTime Function() _clock;
  final Uuid _uuid;

  Database? _db;

  void open() {
    if (_db != null) return;
    _ensureSqliteOpen();
    final dir = File(dbPath).parent;
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final db = sqlite3.open(dbPath);
    db.execute('PRAGMA journal_mode=WAL;');
    db.execute('''
CREATE TABLE IF NOT EXISTS announcements (
  id TEXT PRIMARY KEY,
  recipient TEXT NOT NULL,
  source TEXT NOT NULL,
  intent TEXT NOT NULL,
  priority TEXT NOT NULL,
  not_before_ms INTEGER NOT NULL,
  expires_at_ms INTEGER NOT NULL,
  dedupe_key TEXT,
  status TEXT NOT NULL,
  created_at_ms INTEGER NOT NULL,
  delivered_at_ms INTEGER,
  text TEXT
);
''');
    db.execute('''
CREATE INDEX IF NOT EXISTS idx_ann_status_due
  ON announcements(status, not_before_ms, expires_at_ms);
''');
    db.execute('''
CREATE UNIQUE INDEX IF NOT EXISTS idx_ann_dedupe_pending
  ON announcements(dedupe_key) WHERE dedupe_key IS NOT NULL AND status = 'pending';
''');
    _db = db;
    logInfo('announce_queue_open', 'Announcement queue ready', data: {
      'path': dbPath,
    });
  }

  void close() {
    _db?.dispose();
    _db = null;
  }

  Database get _require {
    final db = _db;
    if (db == null) {
      throw StateError('AnnouncementQueue not open');
    }
    return db;
  }

  /// Enqueue. Returns the stored row (existing pending if dedupe hits).
  Announcement enqueue(Announcement draft) {
    open();
    final now = _clock().toUtc();
    final id = draft.id.trim().isEmpty ? _uuid.v4() : draft.id;
    final row = Announcement(
      id: id,
      recipient: draft.recipient,
      source: draft.source,
      intent: draft.intent,
      priority: draft.priority,
      notBefore: draft.notBefore.toUtc(),
      expiresAt: draft.expiresAt.toUtc(),
      dedupeKey: draft.dedupeKey,
      status: AnnouncementStatus.pending,
      createdAt: draft.createdAt?.toUtc() ?? now,
      text: draft.text,
    );

    if (row.isExpiredAt(now)) {
      logInfo('announce_expired', 'Enqueue rejected: already expired', data: {
        'id': row.id,
        'dedupe': row.dedupeKey,
      });
      final expired = row.copyWith(status: AnnouncementStatus.expired);
      _insert(expired);
      return expired;
    }

    final key = row.dedupeKey;
    if (key != null && key.isNotEmpty) {
      final existing = _require.select(
        '''
SELECT * FROM announcements
WHERE dedupe_key = ? AND status = 'pending'
LIMIT 1
''',
        [key],
      );
      if (existing.isNotEmpty) {
        final kept = _fromRow(existing.first);
        logInfo('announce_dedupe', 'Collapsed duplicate enqueue', data: {
          'dedupe': key,
          'kept_id': kept.id,
          'dropped_id': row.id,
        });
        return kept;
      }
    }

    try {
      _insert(row);
    } on SqliteException catch (e) {
      // Race on unique pending dedupe index.
      if (key != null && e.message.contains('UNIQUE')) {
        final existing = _require.select(
          '''
SELECT * FROM announcements
WHERE dedupe_key = ? AND status = 'pending'
LIMIT 1
''',
          [key],
        );
        if (existing.isNotEmpty) {
          return _fromRow(existing.first);
        }
      }
      rethrow;
    }

    logInfo('announce_enqueued', 'Announcement queued', data: {
      'id': row.id,
      'recipient': row.recipient,
      'source': row.source.wire,
      'priority': row.priority.wire,
      'dedupe': row.dedupeKey,
    });
    return row;
  }

  /// Mark due pending rows whose TTL passed as expired. Returns count.
  int expireDue({DateTime? now}) {
    open();
    final t = (now ?? _clock()).toUtc();
    final ms = t.millisecondsSinceEpoch;
    final before = _require.select(
      '''
SELECT id FROM announcements
WHERE status = 'pending' AND expires_at_ms <= ?
''',
      [ms],
    );
    if (before.isEmpty) return 0;
    _require.execute(
      '''
UPDATE announcements
SET status = 'expired'
WHERE status = 'pending' AND expires_at_ms <= ?
''',
      [ms],
    );
    for (final r in before) {
      logInfo('announce_expired', 'Announcement expired unheard', data: {
        'id': '${r['id']}',
      });
    }
    return before.length;
  }

  /// Pending items that are due and not expired, ordered urgent first then age.
  List<Announcement> duePending({
    DateTime? now,
    String? recipient,
    int limit = 50,
  }) {
    open();
    expireDue(now: now);
    final t = (now ?? _clock()).toUtc().millisecondsSinceEpoch;
    final rows = recipient == null
        ? _require.select(
            '''
SELECT * FROM announcements
WHERE status = 'pending'
  AND not_before_ms <= ?
  AND expires_at_ms > ?
ORDER BY CASE priority WHEN 'urgent' THEN 0 ELSE 1 END,
         created_at_ms ASC
LIMIT ?
''',
            [t, t, limit],
          )
        : _require.select(
            '''
SELECT * FROM announcements
WHERE status = 'pending'
  AND not_before_ms <= ?
  AND expires_at_ms > ?
  AND (recipient = ? OR recipient = 'any')
ORDER BY CASE priority WHEN 'urgent' THEN 0 ELSE 1 END,
         created_at_ms ASC
LIMIT ?
''',
            [t, t, recipient, limit],
          );
    return rows.map(_fromRow).toList();
  }

  List<Announcement> list({AnnouncementStatus? status, int limit = 100}) {
    open();
    final rows = status == null
        ? _require.select(
            '''
SELECT * FROM announcements
ORDER BY created_at_ms DESC
LIMIT ?
''',
            [limit],
          )
        : _require.select(
            '''
SELECT * FROM announcements
WHERE status = ?
ORDER BY created_at_ms DESC
LIMIT ?
''',
            [status.wire, limit],
          );
    return rows.map(_fromRow).toList();
  }

  Announcement? get(String id) {
    open();
    final rows = _require.select(
      'SELECT * FROM announcements WHERE id = ? LIMIT 1',
      [id],
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  void markDelivered(String id, {DateTime? at, String? text}) {
    open();
    final t = (at ?? _clock()).toUtc();
    _require.execute(
      '''
UPDATE announcements
SET status = 'delivered', delivered_at_ms = ?, text = COALESCE(?, text)
WHERE id = ?
''',
      [t.millisecondsSinceEpoch, text, id],
    );
    logInfo('announce_delivered', 'Announcement delivered', data: {
      'id': id,
    });
  }

  /// CAS: mark delivered only if still `pending`. Returns false if raced/lost.
  bool claimDelivered(String id, {DateTime? at, String? text}) {
    open();
    final t = (at ?? _clock()).toUtc();
    _require.execute(
      '''
UPDATE announcements
SET status = 'delivered', delivered_at_ms = ?, text = COALESCE(?, text)
WHERE id = ? AND status = 'pending'
''',
      [t.millisecondsSinceEpoch, text, id],
    );
    final changed = _require.updatedRows > 0;
    if (changed) {
      logInfo('announce_delivered', 'Announcement delivered', data: {
        'id': id,
        'cas': true,
      });
    }
    return changed;
  }

  /// Undo a failed channel delivery claim so the item can retry or hit terminal.
  void reopenPending(String id) {
    open();
    _require.execute(
      '''
UPDATE announcements
SET status = 'pending', delivered_at_ms = NULL
WHERE id = ? AND status = 'delivered'
''',
      [id],
    );
    if (_require.updatedRows > 0) {
      logWarn('announce_reopened', 'Reopened after failed channel send', data: {
        'id': id,
      });
    }
  }

  void cancel(String id) {
    open();
    _require.execute(
      '''
UPDATE announcements SET status = 'cancelled'
WHERE id = ? AND status = 'pending'
''',
      [id],
    );
    logInfo('announce_cancelled', 'Announcement cancelled', data: {'id': id});
  }

  void _insert(Announcement a) {
    _require.execute(
      '''
INSERT INTO announcements (
  id, recipient, source, intent, priority,
  not_before_ms, expires_at_ms, dedupe_key, status,
  created_at_ms, delivered_at_ms, text
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
''',
      [
        a.id,
        a.recipient,
        a.source.wire,
        a.intent,
        a.priority.wire,
        a.notBefore.toUtc().millisecondsSinceEpoch,
        a.expiresAt.toUtc().millisecondsSinceEpoch,
        a.dedupeKey,
        a.status.wire,
        (a.createdAt ?? _clock()).toUtc().millisecondsSinceEpoch,
        a.deliveredAt?.toUtc().millisecondsSinceEpoch,
        a.text,
      ],
    );
  }

  Announcement _fromRow(Row row) {
    DateTime fromMs(Object? v) {
      final n = v is int ? v : int.tryParse('$v') ?? 0;
      return DateTime.fromMillisecondsSinceEpoch(n, isUtc: true);
    }

    DateTime? fromMsOpt(Object? v) {
      if (v == null) return null;
      return fromMs(v);
    }

    return Announcement(
      id: '${row['id']}',
      recipient: '${row['recipient']}',
      source: AnnouncementSource.parse('${row['source']}'),
      intent: '${row['intent']}',
      priority: AnnouncementPriority.parse('${row['priority']}'),
      notBefore: fromMs(row['not_before_ms']),
      expiresAt: fromMs(row['expires_at_ms']),
      dedupeKey: row['dedupe_key']?.toString(),
      status: AnnouncementStatus.parse('${row['status']}'),
      createdAt: fromMsOpt(row['created_at_ms']),
      deliveredAt: fromMsOpt(row['delivered_at_ms']),
      text: row['text']?.toString(),
    );
  }
}
