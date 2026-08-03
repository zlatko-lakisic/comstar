import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Default Workspace scopes for the off-the-shelf MCP package.
const googleWorkspaceScopes = <String>[
  'https://www.googleapis.com/auth/gmail.readonly',
  'https://www.googleapis.com/auth/gmail.send',
  'https://www.googleapis.com/auth/calendar',
  'https://www.googleapis.com/auth/drive',
];

class GoogleDeviceCode {
  const GoogleDeviceCode({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUrl,
    required this.verificationUrlComplete,
    required this.expiresIn,
    required this.intervalSeconds,
  });

  final String deviceCode;
  final String userCode;
  final String verificationUrl;
  final String verificationUrlComplete;
  final int expiresIn;
  final int intervalSeconds;
}

class GoogleOAuthTokens {
  const GoogleOAuthTokens({
    required this.refreshToken,
    this.accessToken,
  });

  final String refreshToken;
  final String? accessToken;
}

enum GooglePairingOutcome { success, timeout, denied, cancelled, error }

class GooglePairingResult {
  const GooglePairingResult({
    required this.outcome,
    this.tokens,
    this.message,
  });

  final GooglePairingOutcome outcome;
  final GoogleOAuthTokens? tokens;
  final String? message;
}

/// OAuth 2.0 device-code flow for headless / voice + QR pairing.
class GoogleDevicePairing {
  GoogleDevicePairing({
    http.Client? httpClient,
    this.clientId,
    this.clientSecret,
    this.scopes = googleWorkspaceScopes,
  }) : _http = httpClient ?? http.Client();

  final http.Client _http;
  final String? clientId;
  final String? clientSecret;
  final List<String> scopes;

  String? get resolvedClientId {
    final fromCtor = clientId?.trim();
    if (fromCtor != null && fromCtor.isNotEmpty) return fromCtor;
    final env = Platform.environment['GOOGLE_CLIENT_ID']?.trim();
    return (env == null || env.isEmpty) ? null : env;
  }

  String? get resolvedClientSecret {
    final fromCtor = clientSecret?.trim();
    if (fromCtor != null && fromCtor.isNotEmpty) return fromCtor;
    final env = Platform.environment['GOOGLE_CLIENT_SECRET']?.trim();
    return (env == null || env.isEmpty) ? null : env;
  }

  bool get isConfigured =>
      (resolvedClientId?.isNotEmpty ?? false) &&
      (resolvedClientSecret?.isNotEmpty ?? false);

  Future<GoogleDeviceCode> begin() async {
    final id = resolvedClientId;
    if (id == null || id.isEmpty) {
      throw StateError('GOOGLE_CLIENT_ID is not set');
    }
    final uri = Uri.parse('https://oauth2.googleapis.com/device/code');
    final resp = await _http.post(
      uri,
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'client_id': id,
        'scope': scopes.join(' '),
      },
    );
    final body = _decodeJson(resp.body);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw StateError(
        'device code failed (${resp.statusCode}): ${body['error'] ?? resp.body}',
      );
    }
    final userCode = body['user_code']?.toString() ?? '';
    final deviceCode = body['device_code']?.toString() ?? '';
    final verificationUrl = (body['verification_uri'] ??
            body['verification_url'] ??
            'https://www.google.com/device')
        .toString();
    final complete = body['verification_uri_complete']?.toString() ??
        '$verificationUrl?user_code=$userCode';
    if (userCode.isEmpty || deviceCode.isEmpty) {
      throw StateError('device code response missing fields');
    }
    return GoogleDeviceCode(
      deviceCode: deviceCode,
      userCode: userCode,
      verificationUrl: verificationUrl,
      verificationUrlComplete: complete,
      expiresIn: _asInt(body['expires_in'], 1800),
      intervalSeconds: _asInt(body['interval'], 5),
    );
  }

  /// Poll until the user approves, times out, or [cancel] completes.
  Future<GooglePairingResult> waitForApproval(
    GoogleDeviceCode code, {
    Future<void>? cancel,
  }) async {
    final id = resolvedClientId;
    final secret = resolvedClientSecret;
    if (id == null || secret == null) {
      return const GooglePairingResult(
        outcome: GooglePairingOutcome.error,
        message: 'Google OAuth client is not configured',
      );
    }

    final deadline = DateTime.now().add(Duration(seconds: code.expiresIn));
    var interval = Duration(seconds: code.intervalSeconds.clamp(1, 30));
    final cancelCompleter = Completer<void>();
    if (cancel != null) {
      unawaited(cancel.then((_) {
        if (!cancelCompleter.isCompleted) cancelCompleter.complete();
      }));
    }

    while (DateTime.now().isBefore(deadline)) {
      if (cancelCompleter.isCompleted) {
        return const GooglePairingResult(
          outcome: GooglePairingOutcome.cancelled,
        );
      }
      await Future.any([
        Future<void>.delayed(interval),
        cancelCompleter.future,
      ]);
      if (cancelCompleter.isCompleted) {
        return const GooglePairingResult(
          outcome: GooglePairingOutcome.cancelled,
        );
      }

      final resp = await _http.post(
        Uri.parse('https://oauth2.googleapis.com/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
          'device_code': code.deviceCode,
          'client_id': id,
          'client_secret': secret,
        },
      );
      final body = _decodeJson(resp.body);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final refresh = body['refresh_token']?.toString() ?? '';
        if (refresh.isEmpty) {
          return const GooglePairingResult(
            outcome: GooglePairingOutcome.error,
            message: 'Google did not return a refresh token',
          );
        }
        return GooglePairingResult(
          outcome: GooglePairingOutcome.success,
          tokens: GoogleOAuthTokens(
            refreshToken: refresh,
            accessToken: body['access_token']?.toString(),
          ),
        );
      }

      final err = body['error']?.toString() ?? '';
      if (err == 'authorization_pending') {
        continue;
      }
      if (err == 'slow_down') {
        interval += const Duration(seconds: 5);
        continue;
      }
      if (err == 'access_denied') {
        return const GooglePairingResult(
          outcome: GooglePairingOutcome.denied,
          message: 'Access denied',
        );
      }
      if (err == 'expired_token') {
        return const GooglePairingResult(
          outcome: GooglePairingOutcome.timeout,
          message: 'Device code expired',
        );
      }
      return GooglePairingResult(
        outcome: GooglePairingOutcome.error,
        message: err.isEmpty ? 'token poll failed (${resp.statusCode})' : err,
      );
    }

    return const GooglePairingResult(
      outcome: GooglePairingOutcome.timeout,
      message: 'Pairing timed out',
    );
  }

  static Map<String, dynamic> _decodeJson(String raw) {
    try {
      final v = jsonDecode(raw);
      if (v is Map<String, dynamic>) return v;
      if (v is Map) return Map<String, dynamic>.from(v);
    } catch (_) {}
    return {};
  }

  static int _asInt(Object? v, int fallback) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? fallback;
  }

  /// Speak-friendly spelling of a Google user code (e.g. `ABCD-EFGH`).
  static String speakableUserCode(String userCode) {
    final buf = StringBuffer();
    for (final rune in userCode.runes) {
      final ch = String.fromCharCode(rune);
      if (ch == '-') {
        buf.write(' dash ');
      } else if (RegExp(r'[A-Za-z0-9]').hasMatch(ch)) {
        buf.write('${ch.toUpperCase()} ');
      }
    }
    return buf.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
