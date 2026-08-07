/// M10.1 — Proactive announcement model (CONTRACTS / ADR 0009).
library;

enum AnnouncementPriority {
  normal,
  urgent;

  static AnnouncementPriority parse(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case 'urgent':
        return AnnouncementPriority.urgent;
      default:
        return AnnouncementPriority.normal;
    }
  }

  String get wire => name;
}

enum AnnouncementSource {
  schedule,
  event,
  agent,
  injected;

  static AnnouncementSource parse(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case 'event':
        return AnnouncementSource.event;
      case 'agent':
        return AnnouncementSource.agent;
      case 'injected':
        return AnnouncementSource.injected;
      default:
        return AnnouncementSource.schedule;
    }
  }

  String get wire => name;
}

enum AnnouncementStatus {
  pending,
  delivered,
  expired,
  cancelled;

  static AnnouncementStatus parse(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case 'delivered':
        return AnnouncementStatus.delivered;
      case 'expired':
        return AnnouncementStatus.expired;
      case 'cancelled':
        return AnnouncementStatus.cancelled;
      default:
        return AnnouncementStatus.pending;
    }
  }

  String get wire => name;
}

/// Queued announcement. Sources enqueue; the delivery gate speaks.
class Announcement {
  Announcement({
    required this.id,
    required this.recipient,
    required this.source,
    required this.intent,
    required this.priority,
    required this.notBefore,
    required this.expiresAt,
    this.dedupeKey,
    this.status = AnnouncementStatus.pending,
    this.createdAt,
    this.deliveredAt,
    this.text,
  });

  /// ULID / UUID string.
  final String id;

  /// FreeIPA uid, face id pass-through, or the literal `any`.
  final String recipient;

  final AnnouncementSource source;

  /// What to say, or the prompt that generates spoken text.
  final String intent;

  final AnnouncementPriority priority;
  final DateTime notBefore;
  final DateTime expiresAt;
  final String? dedupeKey;
  final AnnouncementStatus status;
  final DateTime? createdAt;
  final DateTime? deliveredAt;

  /// Pre-generated spoken text (optional; filled by announcer session).
  final String? text;

  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);

  bool isDueAt(DateTime now) =>
      !now.isBefore(notBefore) && !isExpiredAt(now);

  Announcement copyWith({
    AnnouncementStatus? status,
    DateTime? deliveredAt,
    String? text,
  }) {
    return Announcement(
      id: id,
      recipient: recipient,
      source: source,
      intent: intent,
      priority: priority,
      notBefore: notBefore,
      expiresAt: expiresAt,
      dedupeKey: dedupeKey,
      status: status ?? this.status,
      createdAt: createdAt,
      deliveredAt: deliveredAt ?? this.deliveredAt,
      text: text ?? this.text,
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'recipient': recipient,
        'source': source.wire,
        'intent': intent,
        'priority': priority.wire,
        'notBefore': notBefore.toUtc().toIso8601String(),
        'expiresAt': expiresAt.toUtc().toIso8601String(),
        'dedupeKey': dedupeKey,
        'status': status.wire,
        'createdAt': createdAt?.toUtc().toIso8601String(),
        'deliveredAt': deliveredAt?.toUtc().toIso8601String(),
        'text': text,
      };

  factory Announcement.fromJson(Map<String, Object?> json) {
    DateTime? parseTs(Object? v) {
      if (v == null) return null;
      if (v is DateTime) return v.toUtc();
      return DateTime.tryParse('$v')?.toUtc();
    }

    return Announcement(
      id: '${json['id']}',
      recipient: '${json['recipient']}',
      source: AnnouncementSource.parse('${json['source']}'),
      intent: '${json['intent']}',
      priority: AnnouncementPriority.parse('${json['priority']}'),
      notBefore: parseTs(json['notBefore']) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      expiresAt: parseTs(json['expiresAt']) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      dedupeKey: json['dedupeKey']?.toString(),
      status: AnnouncementStatus.parse('${json['status']}'),
      createdAt: parseTs(json['createdAt']),
      deliveredAt: parseTs(json['deliveredAt']),
      text: json['text']?.toString(),
    );
  }
}
