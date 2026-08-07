/// Short-lived channel pairing attempts (QR / deep-link), Google-style.
library;

import 'dart:convert';
import 'dart:math';

import 'package:comstar_channel/bindings.dart';

enum PairingStatus { pending, approved, expired, cancelled }

class PairingAttempt {
  PairingAttempt({
    required this.id,
    required this.userid,
    required this.provider,
    required this.token,
    required this.url,
    required this.userCode,
    required this.expiresAt,
    this.status = PairingStatus.pending,
    this.senderId,
  });

  final String id;
  final String userid;
  final String provider;
  final String token;
  final String url;
  final String userCode;
  final DateTime expiresAt;
  PairingStatus status;
  String? senderId;

  bool get isExpired => DateTime.now().toUtc().isAfter(expiresAt);

  Map<String, Object?> toPublicJson() => {
        'id': id,
        'userid': userid,
        'provider': provider,
        'url': url,
        'user_code': userCode,
        'expires_at': expiresAt.toUtc().toIso8601String(),
        'status': status.name,
        if (senderId != null) 'sender_id': senderId,
      };
}

/// Creates and completes pairing tokens; persists approved bindings.
class PairingManager {
  PairingManager({
    required this.bindings,
    this.ttl = const Duration(minutes: 10),
    Random? random,
  }) : _random = random ?? Random.secure();

  final BindingStore bindings;
  final Duration ttl;
  final Random _random;
  final _pending = <String, PairingAttempt>{};
  final _byToken = <String, String>{}; // token → id

  /// Build a Telegram deep-link pairing URL.
  static String telegramPairUrl({
    required String botUsername,
    required String token,
  }) {
    final user = botUsername.replaceFirst(RegExp(r'^@'), '');
    return 'https://t.me/$user?start=pair_$token';
  }

  /// Spoken / on-screen code (same spirit as Google user codes).
  static String speakableUserCode(String code) {
    final chars = code.toUpperCase().split('');
    return chars.join(' ');
  }

  String _token() {
    const alphabet = 'abcdefghijkmnopqrstuvwxyz23456789';
    final buf = StringBuffer();
    for (var i = 0; i < 8; i++) {
      buf.write(alphabet[_random.nextInt(alphabet.length)]);
    }
    return buf.toString();
  }

  String _id() {
    final ms = DateTime.now().toUtc().millisecondsSinceEpoch;
    return 'pair_${ms.toRadixString(36)}_${_token()}';
  }

  String _userCode() {
    // Short display code distinct from the opaque deep-link token.
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final buf = StringBuffer();
    for (var i = 0; i < 6; i++) {
      buf.write(alphabet[_random.nextInt(alphabet.length)]);
      if (i == 2) buf.write('-');
    }
    return buf.toString();
  }

  void _purgeExpired() {
    final dead = <String>[];
    for (final e in _pending.entries) {
      if (e.value.isExpired && e.value.status == PairingStatus.pending) {
        e.value.status = PairingStatus.expired;
        dead.add(e.key);
      }
    }
    for (final id in dead) {
      final a = _pending.remove(id);
      if (a != null) _byToken.remove(a.token);
    }
  }

  /// Start pairing. [urlBuilder] supplies the scan URL for [provider].
  Future<PairingAttempt> begin({
    required String userid,
    required String provider,
    required String Function(String token) urlBuilder,
  }) async {
    final uid = userid.trim().toLowerCase();
    if (uid.isEmpty || uid == 'guest' || uid == 'unknown') {
      throw ArgumentError('invalid pairing userid');
    }
    final prov = provider.trim().toLowerCase();
    if (prov.isEmpty) throw ArgumentError('provider required');

    _purgeExpired();
    // Cancel prior pending for same userid+provider.
    for (final a in _pending.values.toList()) {
      if (a.userid == uid &&
          a.provider == prov &&
          a.status == PairingStatus.pending) {
        a.status = PairingStatus.cancelled;
        _pending.remove(a.id);
        _byToken.remove(a.token);
      }
    }

    final token = _token();
    final attempt = PairingAttempt(
      id: _id(),
      userid: uid,
      provider: prov,
      token: token,
      url: urlBuilder(token),
      userCode: _userCode(),
      expiresAt: DateTime.now().toUtc().add(ttl),
    );
    _pending[attempt.id] = attempt;
    _byToken[token] = attempt.id;
    return attempt;
  }

  PairingAttempt? get(String id) {
    _purgeExpired();
    return _pending[id];
  }

  Future<bool> cancel(String id) async {
    final a = _pending[id];
    if (a == null) return false;
    if (a.status != PairingStatus.pending) return false;
    a.status = PairingStatus.cancelled;
    _pending.remove(id);
    _byToken.remove(a.token);
    return true;
  }

  /// Complete from an inbound `/start pair_<token>` (or bare token).
  ///
  /// Returns the userid when a pending attempt matches; null otherwise.
  Future<String?> completeFromStartPayload({
    required String provider,
    required String senderId,
    required String payload,
  }) async {
    _purgeExpired();
    var raw = payload.trim();
    if (raw.toLowerCase().startsWith('pair_')) {
      raw = raw.substring(5);
    }
    final id = _byToken[raw];
    if (id == null) return null;
    final a = _pending[id];
    if (a == null || a.status != PairingStatus.pending) return null;
    if (a.provider != provider) return null;
    if (a.isExpired) {
      a.status = PairingStatus.expired;
      _pending.remove(id);
      _byToken.remove(a.token);
      return null;
    }

    await bindings.upsert(
      ChannelBinding(
        provider: provider,
        senderId: senderId,
        userid: a.userid,
        linkedAt: DateTime.now().toUtc(),
      ),
    );
    a.status = PairingStatus.approved;
    a.senderId = senderId;
    _byToken.remove(a.token);
    // Keep briefly so status polls can see approved.
    return a.userid;
  }

  /// Parse Telegram `/start …` text → payload after /start, or null.
  static String? telegramStartPayload(String text) {
    final t = text.trim();
    final m = RegExp(r'^/start(?:@\w+)?(?:\s+(.+))?$', caseSensitive: false)
        .firstMatch(t);
    if (m == null) return null;
    final payload = (m.group(1) ?? '').trim();
    return payload.isEmpty ? '' : payload;
  }

  /// Debug / tests.
  Map<String, dynamic> debugDump() => {
        'pending': _pending.length,
        'tokens': jsonEncode(_byToken.keys.toList()),
      };
}
