/// Telegram Bot API long-poll implementation of [Channel].
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'channel.dart';

/// Telegram Bot API long-poll channel.
///
/// Requires `TELEGRAM_BOT_TOKEN`. Uses getUpdates long-polling (no public
/// webhook needed on Ada).
class TelegramChannel implements Channel {
  TelegramChannel({
    required this.botToken,
    http.Client? httpClient,
    this.pollTimeoutSeconds = 25,
  }) : _http = httpClient ?? http.Client();

  final String botToken;
  final int pollTimeoutSeconds;
  final http.Client _http;

  final _inbound = StreamController<ChannelInbound>.broadcast();
  int _offset = 0;
  bool _running = false;
  Future<void>? _loop;

  Uri _api(String method) =>
      Uri.parse('https://api.telegram.org/bot$botToken/$method');

  @override
  Stream<ChannelInbound> get inbound => _inbound.stream;

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _loop = _pollLoop();
  }

  @override
  Future<void> stop() async {
    _running = false;
    await _loop;
    // Do not close the broadcast controller if tests reuse the instance;
    // callers that discard the channel can ignore.
  }

  Future<void> _pollLoop() async {
    while (_running) {
      try {
        final uri = _api('getUpdates').replace(queryParameters: {
          'timeout': '$pollTimeoutSeconds',
          'offset': '$_offset',
          'allowed_updates': jsonEncode(['message']),
        });
        final res = await _http.get(uri).timeout(
              Duration(seconds: pollTimeoutSeconds + 10),
            );
        if (res.statusCode != 200) {
          await Future<void>.delayed(const Duration(seconds: 2));
          continue;
        }
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        if (body['ok'] != true) {
          await Future<void>.delayed(const Duration(seconds: 2));
          continue;
        }
        final results = body['result'] as List<dynamic>? ?? const [];
        for (final raw in results) {
          final update = raw as Map<String, dynamic>;
          final updateId = update['update_id'] as int?;
          if (updateId != null) {
            _offset = updateId + 1;
          }
          final msg = update['message'] as Map<String, dynamic>?;
          if (msg == null) continue;
          final from = msg['from'] as Map<String, dynamic>?;
          if (from == null) continue;
          final senderId = '${from['id']}';
          final text = '${msg['text'] ?? ''}'.trim();
          if (text.isEmpty) continue;
          if (!_inbound.isClosed) {
            _inbound.add(ChannelInbound(
              senderId: senderId,
              text: text,
              raw: update,
            ));
          }
        }
      } catch (_) {
        if (!_running) break;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  }

  @override
  Future<void> send(String senderId, String text) async {
    final res = await _http.post(
      _api('sendMessage'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'chat_id': senderId,
        'text': text,
        'parse_mode': 'Markdown',
      }),
    );
    if (res.statusCode != 200) {
      throw StateError('Telegram sendMessage failed: ${res.statusCode} ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (body['ok'] != true) {
      // Retry without Markdown if parse fails.
      final res2 = await _http.post(
        _api('sendMessage'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'chat_id': senderId,
          'text': text,
        }),
      );
      if (res2.statusCode != 200) {
        throw StateError(
            'Telegram sendMessage plain failed: ${res2.statusCode}');
      }
    }
  }

  @override
  Future<void> setTyping(String senderId, ChannelTyping state) async {
    if (state != ChannelTyping.started) return;
    try {
      await _http.post(
        _api('sendChatAction'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'chat_id': senderId,
          'action': 'typing',
        }),
      );
    } catch (_) {}
  }
}
