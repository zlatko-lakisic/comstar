import 'dart:io';

/// SMTP settings from env (optional — soft-skip when incomplete).
class SmtpConfig {
  const SmtpConfig({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    required this.fromEmail,
    this.fromName = 'COMSTAR',
    this.useSsl = false,
    this.allowInsecure = false,
  });

  final String host;
  final int port;
  final String username;
  final String password;
  final String fromEmail;
  final String fromName;
  final bool useSsl;
  final bool allowInsecure;

  /// Returns null when SMTP is not configured (pairing continues without mail).
  static SmtpConfig? fromEnvironment([Map<String, String>? env]) {
    final e = env ?? Platform.environment;
    final host = e['COMSTAR_SMTP_HOST']?.trim() ?? '';
    final user = e['COMSTAR_SMTP_USER']?.trim() ?? '';
    final pass = e['COMSTAR_SMTP_PASSWORD']?.trim() ?? '';
    final from = e['COMSTAR_SMTP_FROM']?.trim() ?? '';
    if (host.isEmpty || user.isEmpty || pass.isEmpty || from.isEmpty) {
      return null;
    }
    final port = int.tryParse(e['COMSTAR_SMTP_PORT']?.trim() ?? '') ?? 587;
    final mode = (e['COMSTAR_SMTP_TLS']?.trim() ?? 'starttls').toLowerCase();
    return SmtpConfig(
      host: host,
      port: port,
      username: user,
      password: pass,
      fromEmail: from,
      fromName: e['COMSTAR_SMTP_FROM_NAME']?.trim().isNotEmpty == true
          ? e['COMSTAR_SMTP_FROM_NAME']!.trim()
          : 'COMSTAR',
      useSsl: mode == 'ssl' || mode == 'smtps',
      allowInsecure: e['COMSTAR_SMTP_ALLOW_INSECURE'] == '1',
    );
  }

  bool get isStartTls => !useSsl;
}
