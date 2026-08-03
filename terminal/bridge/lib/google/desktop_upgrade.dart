import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:comstar_bridge/google/device_pairing.dart';
import 'package:comstar_bridge/google/token_store.dart';
import 'package:comstar_bridge/log.dart';
import 'package:comstar_bridge/mail/google_desktop_email.dart';
import 'package:comstar_bridge/mail/smtp_mailer.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

/// Pending Desktop OAuth upgrade after TV device pairing.
class GoogleDesktopPending {
  GoogleDesktopPending({
    required this.state,
    required this.userid,
    required this.email,
    required this.expiresAt,
  });

  final String state;
  final String userid;
  final String email;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().toUtc().isAfter(expiresAt);
}

/// Starts Desktop OAuth after TV auth: email link + local callback wait.
class GoogleDesktopUpgrade {
  GoogleDesktopUpgrade({
    GoogleTokenStore? tokens,
    SmtpMailer? mailer,
    http.Client? httpClient,
    this.port = 8781,
    this.ttlMinutes = 30,
  })  : tokens = tokens ?? GoogleTokenStore(),
        mailer = mailer ?? SmtpMailer(),
        _http = httpClient ?? http.Client();

  final GoogleTokenStore tokens;
  final SmtpMailer mailer;
  final http.Client _http;
  final int port;
  final int ttlMinutes;

  HttpServer? _server;
  final _pending = <String, GoogleDesktopPending>{};
  final _completers = <String, Completer<bool>>{};

  static String? get desktopClientId =>
      Platform.environment['GOOGLE_DESKTOP_CLIENT_ID']?.trim().isNotEmpty == true
          ? Platform.environment['GOOGLE_DESKTOP_CLIENT_ID']!.trim()
          : null;

  static String? get desktopClientSecret =>
      Platform.environment['GOOGLE_DESKTOP_CLIENT_SECRET']?.trim().isNotEmpty ==
              true
          ? Platform.environment['GOOGLE_DESKTOP_CLIENT_SECRET']!.trim()
          : null;

  /// Public base for OAuth redirect + email links, e.g. http://10.0.10.50:8781
  static String? get redirectBase {
    final raw = Platform.environment['COMSTAR_OAUTH_REDIRECT_BASE']?.trim();
    if (raw == null || raw.isEmpty) return null;
    return raw.replaceAll(RegExp(r'/$'), '');
  }

  bool get isConfigured =>
      mailer.isConfigured &&
      desktopClientId != null &&
      desktopClientSecret != null &&
      redirectBase != null;

  String get callbackUrl => '${redirectBase!}/oauth/google/callback';

  Future<void> start() async {
    if (_server != null) return;
    if (desktopClientId == null || redirectBase == null) {
      logInfo(
        'google_desktop_oauth_skip',
        'Desktop OAuth callback not started (missing DESKTOP client or REDIRECT_BASE)',
      );
      return;
    }
    final handler = const Pipeline().addHandler(_router);
    // Bind LAN only when redirect base is not loopback — else localhost.
    final host = _bindHost();
    _server = await shelf_io.serve(handler, host, port);
    logInfo('google_desktop_oauth_listen', 'Desktop OAuth callback listening', data: {
      'host': host,
      'port': port,
      'callback': callbackUrl,
    });
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  String _bindHost() {
    final base = redirectBase ?? '';
    if (base.contains('127.0.0.1') || base.contains('localhost')) {
      return '127.0.0.1';
    }
    // Explicit opt-in — separate from WebSocket LAN triple-gate.
    if (Platform.environment['COMSTAR_OAUTH_BIND_LAN'] == '1' ||
        Platform.environment['COMSTAR_ENV'] == 'dev') {
      return '0.0.0.0';
    }
    return '127.0.0.1';
  }

  Future<Response> _router(Request request) async {
    final path = request.url.path;
    if (request.method == 'GET' && path == 'oauth/google/callback') {
      return _handleCallback(request);
    }
    if (request.method == 'GET' && path == 'oauth/google/start') {
      return _handleStart(request);
    }
    if (request.method == 'POST' && path == 'oauth/google/resend') {
      return _handleResend(request);
    }
    return Response.notFound('Not found');
  }

  Future<Response> _handleResend(Request request) async {
    try {
      final raw = await request.readAsString();
      final map = raw.trim().isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final userid = (map['userid']?.toString().trim().isNotEmpty == true)
          ? map['userid'].toString().trim()
          : 'zlatko';
      final offer = await resendForUser(userid);
      return Response.ok(
        jsonEncode({
          'ok': offer.emailed,
          'skipped': offer.skipped,
          'email': offer.email,
          'reason': offer.reason,
        }),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      logWarn('google_desktop_resend', e.toString());
      return Response.internalServerError(
        body: jsonEncode({'ok': false, 'error': e.toString()}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  Future<Response> _handleStart(Request request) async {
    final state = request.url.queryParameters['state']?.trim() ?? '';
    final pending = _pending[state];
    if (pending == null || pending.isExpired) {
      return Response.ok(
        _htmlPage('Link expired', 'This Google upgrade link has expired. '
            'Say connect my Google on COMSTAR to try again.'),
        headers: {'content-type': 'text/html; charset=utf-8'},
      );
    }
    final url = _googleAuthUrl(state);
    return Response.found(url);
  }

  Future<Response> _handleCallback(Request request) async {
    final q = request.url.queryParameters;
    final err = q['error']?.trim();
    final state = q['state']?.trim() ?? '';
    final code = q['code']?.trim() ?? '';
    final pending = _pending[state];

    if (err != null && err.isNotEmpty) {
      _finish(state, false);
      return Response.ok(
        _htmlPage('Not linked', 'Google returned: $err'),
        headers: {'content-type': 'text/html; charset=utf-8'},
      );
    }
    if (pending == null || pending.isExpired || code.isEmpty) {
      _finish(state, false);
      return Response.ok(
        _htmlPage('Link expired', 'Start again from COMSTAR.'),
        headers: {'content-type': 'text/html; charset=utf-8'},
      );
    }

    try {
      final tokens = await _exchangeCode(code);
      await this.tokens.writeRefreshToken(
            pending.userid,
            tokens.refreshToken,
            client: GoogleOAuthClientKind.desktop,
          );
      _pending.remove(state);
      _finish(state, true);
      logInfo('google_desktop_linked', 'Desktop Google token saved', data: {
        'userid': pending.userid,
      });
      return Response.ok(
        _htmlPage(
          'Google linked',
          'Gmail and Drive are ready for COMSTAR. You can close this tab.',
        ),
        headers: {'content-type': 'text/html; charset=utf-8'},
      );
    } catch (e) {
      logWarn('google_desktop_exchange', e.toString());
      _finish(state, false);
      return Response.ok(
        _htmlPage('Something went wrong', e.toString()),
        headers: {'content-type': 'text/html; charset=utf-8'},
      );
    }
  }

  void _finish(String state, bool ok) {
    final c = _completers.remove(state);
    if (c != null && !c.isCompleted) c.complete(ok);
  }

  /// Re-send Desktop upgrade email for an already-paired userid.
  Future<GoogleDesktopUpgradeOffer> resendForUser(String userid) async {
    final refresh = await tokens.readRefreshToken(userid);
    if (refresh == null || refresh.isEmpty) {
      return GoogleDesktopUpgradeOffer.skipped('no_refresh_token');
    }
    final kind = await tokens.readClientKind(userid);
    final clientId = kind == GoogleOAuthClientKind.desktop
        ? (desktopClientId ??
            Platform.environment['GOOGLE_CLIENT_ID']?.trim() ??
            '')
        : (Platform.environment['GOOGLE_CLIENT_ID']?.trim() ?? '');
    final clientSecret = kind == GoogleOAuthClientKind.desktop
        ? (desktopClientSecret ??
            Platform.environment['GOOGLE_CLIENT_SECRET']?.trim() ??
            '')
        : (Platform.environment['GOOGLE_CLIENT_SECRET']?.trim() ?? '');
    if (clientId.isEmpty || clientSecret.isEmpty) {
      return GoogleDesktopUpgradeOffer.skipped('no_client');
    }
    final access = await _refreshAccessToken(
      refreshToken: refresh,
      clientId: clientId,
      clientSecret: clientSecret,
    );
    return offerAfterTvPairing(userid: userid, accessToken: access);
  }

  Future<String> _refreshAccessToken({
    required String refreshToken,
    required String clientId,
    required String clientSecret,
  }) async {
    final resp = await _http.post(
      Uri.parse('https://oauth2.googleapis.com/token'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'client_id': clientId,
        'client_secret': clientSecret,
        'refresh_token': refreshToken,
        'grant_type': 'refresh_token',
      },
    );
    final body = jsonDecode(resp.body);
    if (resp.statusCode < 200 || resp.statusCode >= 300 || body is! Map) {
      throw StateError(
        'refresh failed (${resp.statusCode}): ${resp.body}',
      );
    }
    final access = body['access_token']?.toString() ?? '';
    if (access.isEmpty) {
      throw StateError('refresh missing access_token');
    }
    return access;
  }

  /// After TV pairing: email Desktop link; [done] completes when linked/expired.
  Future<GoogleDesktopUpgradeOffer> offerAfterTvPairing({
    required String userid,
    required String? accessToken,
    String? packageRoot,
  }) async {
    if (!isConfigured) {
      logInfo(
        'google_desktop_upgrade_skip',
        'SMTP/Desktop OAuth not fully configured',
      );
      return GoogleDesktopUpgradeOffer.skipped('not_configured');
    }

    final email = await _fetchEmail(accessToken);
    if (email == null || email.isEmpty) {
      return GoogleDesktopUpgradeOffer.skipped('no_email');
    }

    final state = _newState();
    final expires = DateTime.now().toUtc().add(Duration(minutes: ttlMinutes));
    _pending[state] = GoogleDesktopPending(
      state: state,
      userid: userid,
      email: email,
      expiresAt: expires,
    );
    final completer = Completer<bool>();
    _completers[state] = completer;

    final startUrl =
        '${redirectBase!}/oauth/google/start?state=${Uri.encodeQueryComponent(state)}';
    final mail = GoogleDesktopUpgradeEmail(
      displayName: userid,
      authUrl: startUrl,
      expiresMinutes: ttlMinutes,
    );
    final hero = resolveComstarHeroEmail(packageRoot: packageRoot);
    final send = await mailer.sendHtml(
      to: email,
      subject: mail.subject,
      html: mail.htmlBody,
      text: mail.textBody,
      inlineImages: hero == null ? const [] : [hero],
    );
    if (!send.ok) {
      _pending.remove(state);
      _completers.remove(state);
      logWarn('google_desktop_email_failed', send.error ?? 'send failed');
      return GoogleDesktopUpgradeOffer(
        emailed: false,
        skipped: false,
        reason: send.error ?? 'smtp_failed',
        email: email,
        done: Future.value(false),
      );
    }
    logInfo('google_desktop_email_sent', 'Desktop upgrade email sent', data: {
      'userid': userid,
      'to': email,
    });

    unawaited(_expireLater(state, expires));
    return GoogleDesktopUpgradeOffer(
      emailed: true,
      skipped: false,
      email: email,
      done: completer.future.timeout(
        Duration(minutes: ttlMinutes + 1),
        onTimeout: () => false,
      ),
    );
  }

  Future<void> _expireLater(String state, DateTime expires) async {
    final wait = expires.difference(DateTime.now().toUtc());
    if (wait.isNegative) {
      _finish(state, false);
      _pending.remove(state);
      return;
    }
    await Future<void>.delayed(wait);
    if (_pending.remove(state) != null) {
      _finish(state, false);
    }
  }

  String _googleAuthUrl(String state) {
    final q = {
      'client_id': desktopClientId!,
      'redirect_uri': callbackUrl,
      'response_type': 'code',
      'scope': googleWorkspaceDesktopScopes.join(' '),
      'access_type': 'offline',
      'prompt': 'consent',
      'state': state,
    };
    return Uri.https(
      'accounts.google.com',
      '/o/oauth2/v2/auth',
      q,
    ).toString();
  }

  Future<GoogleOAuthTokens> _exchangeCode(String code) async {
    final resp = await _http.post(
      Uri.parse('https://oauth2.googleapis.com/token'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'code': code,
        'client_id': desktopClientId!,
        'client_secret': desktopClientSecret!,
        'redirect_uri': callbackUrl,
        'grant_type': 'authorization_code',
      },
    );
    final body = jsonDecode(resp.body);
    if (resp.statusCode < 200 ||
        resp.statusCode >= 300 ||
        body is! Map) {
      throw StateError('token exchange failed (${resp.statusCode}): ${resp.body}');
    }
    final map = Map<String, dynamic>.from(body);
    final refresh = map['refresh_token']?.toString() ?? '';
    if (refresh.isEmpty) {
      throw StateError(
        'Google did not return a refresh token (revoke prior grant and retry)',
      );
    }
    return GoogleOAuthTokens(
      refreshToken: refresh,
      accessToken: map['access_token']?.toString(),
    );
  }

  Future<String?> _fetchEmail(String? accessToken) async {
    if (accessToken == null || accessToken.isEmpty) return null;
    final resp = await _http.get(
      Uri.parse('https://www.googleapis.com/oauth2/v3/userinfo'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
    final map = jsonDecode(resp.body);
    if (map is! Map) return null;
    final email = map['email']?.toString().trim();
    return (email == null || email.isEmpty) ? null : email;
  }

  String _newState() {
    final r = Random.secure();
    final bytes = List<int>.generate(24, (_) => r.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static String _htmlPage(String title, String body) => '''
<!DOCTYPE html>
<html><head><meta charset="utf-8"/><title>$title</title></head>
<body style="font-family:system-ui,sans-serif;background:#0b1220;color:#f4f1ea;padding:48px;">
  <h1>$title</h1>
  <p>$body</p>
</body></html>
''';
}

class GoogleDesktopUpgradeOffer {
  GoogleDesktopUpgradeOffer({
    required this.emailed,
    required this.skipped,
    required this.done,
    this.reason,
    this.email,
  });

  factory GoogleDesktopUpgradeOffer.skipped(String reason) =>
      GoogleDesktopUpgradeOffer(
        emailed: false,
        skipped: true,
        reason: reason,
        done: Future.value(false),
      );

  final bool emailed;
  final bool skipped;
  final String? reason;
  final String? email;
  final Future<bool> done;
}
