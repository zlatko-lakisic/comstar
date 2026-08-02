import 'dart:convert';

import 'package:uuid/uuid.dart';

const envelopeVersion = 1;
const _uuid = Uuid();

/// CONTRACTS §1/§2 message envelope.
class Envelope {
  Envelope({
    required this.id,
    required this.type,
    required this.ts,
    this.turnId,
    this.data = const {},
    this.v = envelopeVersion,
  });

  final int v;
  final String id;
  final String type;
  final int ts;
  final String? turnId;
  final Map<String, dynamic> data;

  Map<String, dynamic> toJson() => {
        'v': v,
        'id': id,
        'type': type,
        'ts': ts,
        'turn_id': turnId,
        'data': data,
      };

  String encode() => jsonEncode(toJson());

  static Envelope create({
    required String type,
    String? turnId,
    Map<String, dynamic> data = const {},
    String? id,
    int? ts,
  }) {
    return Envelope(
      id: id ?? newMessageId(),
      type: type,
      ts: ts ?? DateTime.now().millisecondsSinceEpoch,
      turnId: turnId,
      data: data,
    );
  }

  static Envelope? decode(String raw) {
    try {
      final parsed = jsonDecode(raw);
      if (parsed is! Map) return null;
      final map = Map<String, dynamic>.from(parsed);
      final type = map['type'];
      if (type is! String || type.isEmpty) return null;
      return Envelope(
        v: map['v'] is int ? map['v'] as int : envelopeVersion,
        id: map['id'] is String ? map['id'] as String : newMessageId(),
        type: type,
        ts: map['ts'] is int
            ? map['ts'] as int
            : DateTime.now().millisecondsSinceEpoch,
        turnId: map['turn_id'] as String?,
        data: map['data'] is Map
            ? Map<String, dynamic>.from(map['data'] as Map)
            : const {},
      );
    } on Object {
      return null;
    }
  }
}

String newMessageId() => 'msg_${_uuid.v4()}';

String newTurnId() => 't_${_uuid.v4()}';
