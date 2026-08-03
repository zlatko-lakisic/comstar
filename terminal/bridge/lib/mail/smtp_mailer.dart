import 'dart:io';

import 'package:comstar_bridge/mail/smtp_config.dart';
import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server.dart';
import 'package:path/path.dart' as p;

class SmtpSendResult {
  const SmtpSendResult({required this.ok, this.messageId, this.error});
  final bool ok;
  final String? messageId;
  final String? error;
}

/// Thin SMTP sender for bridge-owned transactional mail (pairing, etc.).
class SmtpMailer {
  SmtpMailer({SmtpConfig? config, this.heroImagePath})
      : config = config ?? SmtpConfig.fromEnvironment();

  final SmtpConfig? config;
  final String? heroImagePath;

  bool get isConfigured => config != null;

  /// Default hero packaged with the bridge (small JPEG for HTML mail).
  static String defaultHeroPath({String? packageRoot}) {
    final root = packageRoot ??
        p.dirname(p.dirname(Platform.script.toFilePath()));
    final candidates = [
      p.join(root, 'assets', 'comstar-hero-email.jpg'),
      p.join(Directory.current.path, 'assets', 'comstar-hero-email.jpg'),
      p.join(Directory.current.path, 'terminal', 'bridge', 'assets',
          'comstar-hero-email.jpg'),
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return candidates.first;
  }

  Future<SmtpSendResult> sendHtml({
    required String to,
    required String subject,
    required String html,
    String? text,
    List<File>? inlineImages,
  }) async {
    final cfg = config;
    if (cfg == null) {
      return const SmtpSendResult(
        ok: false,
        error: 'SMTP not configured (COMSTAR_SMTP_*)',
      );
    }

    final server = SmtpServer(
      cfg.host,
      port: cfg.port,
      username: cfg.username,
      password: cfg.password,
      ssl: cfg.useSsl,
      allowInsecure: cfg.allowInsecure,
    );

    final message = Message()
      ..from = Address(cfg.fromEmail, cfg.fromName)
      ..recipients.add(to)
      ..subject = subject
      ..html = html;
    if (text != null && text.trim().isNotEmpty) {
      message.text = text;
    }
    for (final file in inlineImages ?? const <File>[]) {
      if (!file.existsSync()) continue;
      final cid = 'hero@comstar';
      message.attachments.add(
        FileAttachment(file)
          ..cid = '<$cid>'
          ..location = Location.inline,
      );
    }

    try {
      final report = await send(message, server);
      return SmtpSendResult(
        ok: true,
        messageId: report.toString(),
      );
    } on MailerException catch (e) {
      return SmtpSendResult(ok: false, error: e.message);
    } catch (e) {
      return SmtpSendResult(ok: false, error: e.toString());
    }
  }
}
