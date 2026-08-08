import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Outcome of a Login Flow v2 poll.
enum NextcloudPairingOutcome {
  success,
  pending,
  timeout,
  denied,
  error,
}

class NextcloudLoginSession {
  const NextcloudLoginSession({
    required this.loginUrl,
    required this.pollToken,
    required this.pollEndpoint,
    required this.expiresAt,
  });

  final String loginUrl;
  final String pollToken;
  final String pollEndpoint;
  final DateTime expiresAt;
}

class NextcloudPairingResult {
  const NextcloudPairingResult({
    required this.outcome,
    this.server,
    this.loginName,
    this.appPassword,
    this.message,
  });

  final NextcloudPairingOutcome outcome;
  final String? server;
  final String? loginName;
  final String? appPassword;
  final String? message;
}

/// Nextcloud Login Flow v2 for hallway QR pairing.
///
/// See https://docs.nextcloud.com/server/latest/developer_manual/client_apis/LoginFlow/index.html#login-flow-v2
class NextcloudLoginFlow {
  NextcloudLoginFlow({
    http.Client? httpClient,
    this.host,
  }) : _client = httpClient ?? http.Client();

  final http.Client _client;

  /// Override instance URL; otherwise `NEXTCLOUD_HOST` env.
  final String? host;

  bool get isConfigured {
    final h = resolvedHost();
    return h != null && h.isNotEmpty;
  }

  String? resolvedHost() {
    final fromCtor = host?.trim() ?? '';
    if (fromCtor.isNotEmpty) return _stripSlash(fromCtor);
    final env = Platform.environment['NEXTCLOUD_HOST']?.trim() ?? '';
    if (env.isEmpty) return null;
    return _stripSlash(env);
  }

  Future<NextcloudLoginSession> begin() async {
    final base = resolvedHost();
    if (base == null || base.isEmpty) {
      throw StateError('NEXTCLOUD_HOST not set');
    }
    final uri = Uri.parse('$base/index.php/login/v2');
    final resp = await _client.post(
      uri,
      headers: {
        'Accept': 'application/json',
        'User-Agent': 'COMSTAR-bridge/0.1',
      },
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw StateError(
        'login/v2 failed HTTP ${resp.statusCode}: ${resp.body}',
      );
    }
    final map = jsonDecode(resp.body);
    if (map is! Map) {
      throw StateError('login/v2: unexpected body');
    }
    final login = map['login']?.toString() ?? '';
    final poll = map['poll'];
    if (login.isEmpty || poll is! Map) {
      throw StateError('login/v2: missing login/poll');
    }
    final token = poll['token']?.toString() ?? '';
    final endpoint = poll['endpoint']?.toString() ?? '';
    if (token.isEmpty || endpoint.isEmpty) {
      throw StateError('login/v2: missing poll token/endpoint');
    }
    return NextcloudLoginSession(
      loginUrl: login,
      pollToken: token,
      pollEndpoint: endpoint,
      expiresAt: DateTime.now().add(const Duration(minutes: 20)),
    );
  }

  Future<NextcloudPairingResult> waitForApproval(
    NextcloudLoginSession session, {
    Duration pollInterval = const Duration(seconds: 2),
    Completer<void>? cancel,
  }) async {
    while (DateTime.now().isBefore(session.expiresAt)) {
      if (cancel != null && cancel.isCompleted) {
        return const NextcloudPairingResult(
          outcome: NextcloudPairingOutcome.denied,
          message: 'cancelled',
        );
      }
      try {
        final resp = await _client.post(
          Uri.parse(session.pollEndpoint),
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/x-www-form-urlencoded',
            'User-Agent': 'COMSTAR-bridge/0.1',
          },
          body: {'token': session.pollToken},
        );
        if (resp.statusCode == 404) {
          await Future<void>.delayed(pollInterval);
          continue;
        }
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          final map = jsonDecode(resp.body);
          if (map is! Map) {
            return const NextcloudPairingResult(
              outcome: NextcloudPairingOutcome.error,
              message: 'bad poll body',
            );
          }
          final server = map['server']?.toString() ?? '';
          final loginName = map['loginName']?.toString() ?? '';
          final appPassword = map['appPassword']?.toString() ?? '';
          if (loginName.isEmpty || appPassword.isEmpty) {
            return const NextcloudPairingResult(
              outcome: NextcloudPairingOutcome.error,
              message: 'missing credentials in poll response',
            );
          }
          return NextcloudPairingResult(
            outcome: NextcloudPairingOutcome.success,
            server: server.isEmpty ? resolvedHost() : _stripSlash(server),
            loginName: loginName,
            appPassword: appPassword,
          );
        }
        return NextcloudPairingResult(
          outcome: NextcloudPairingOutcome.error,
          message: 'poll HTTP ${resp.statusCode}',
        );
      } catch (e) {
        return NextcloudPairingResult(
          outcome: NextcloudPairingOutcome.error,
          message: e.toString(),
        );
      }
    }
    return const NextcloudPairingResult(
      outcome: NextcloudPairingOutcome.timeout,
      message: 'pairing timed out',
    );
  }

  static String _stripSlash(String host) {
    var h = host.trim();
    if (h.endsWith('/')) h = h.substring(0, h.length - 1);
    return h;
  }
}
