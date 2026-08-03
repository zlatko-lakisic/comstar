import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// HTML + plain bodies for the post-TV Desktop OAuth upgrade email.
class GoogleDesktopUpgradeEmail {
  GoogleDesktopUpgradeEmail({
    required this.displayName,
    required this.authUrl,
    required this.expiresMinutes,
    this.heroCid = 'hero@comstar',
  });

  final String displayName;
  final String authUrl;
  final int expiresMinutes;
  final String heroCid;

  String get subject => 'Finish linking Google with COMSTAR';

  String get textBody => '''
Hi $displayName,

COMSTAR linked your Google Calendar from the hallway terminal.

To enable Gmail and full Drive, open this link on your phone or computer
within $expiresMinutes minutes:

$authUrl

If you did not start this, you can ignore this email.

— COMSTAR
''';

  String get htmlBody {
    final safeName = _escape(displayName);
    final safeUrl = _escape(authUrl);
    return '''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>COMSTAR Google</title>
</head>
<body style="margin:0;padding:0;background:#0b1220;font-family:Georgia,'Times New Roman',serif;">
  <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#0b1220;padding:32px 12px;">
    <tr>
      <td align="center">
        <table role="presentation" width="560" cellspacing="0" cellpadding="0" style="max-width:560px;width:100%;background:#121a2b;border:1px solid #24304a;border-radius:4px;overflow:hidden;">
          <tr>
            <td style="padding:0;line-height:0;">
              <img src="cid:$heroCid" width="560" alt="COMSTAR" style="display:block;width:100%;max-width:560px;height:auto;border:0;"/>
            </td>
          </tr>
          <tr>
            <td style="padding:28px 28px 8px 28px;">
              <p style="margin:0;font-size:11px;letter-spacing:0.22em;text-transform:uppercase;color:#8fa3c8;">COMSTAR</p>
              <h1 style="margin:10px 0 0 0;font-size:26px;line-height:1.25;font-weight:normal;color:#f4f1ea;">Finish Google access</h1>
            </td>
          </tr>
          <tr>
            <td style="padding:12px 28px 8px 28px;color:#c9d4e8;font-size:16px;line-height:1.55;">
              <p style="margin:0 0 14px 0;">Hi $safeName,</p>
              <p style="margin:0 0 14px 0;">Your hallway terminal linked <strong style="color:#f4f1ea;">Calendar</strong>. Gmail and full Drive need one more approval on a phone or computer.</p>
              <p style="margin:0 0 22px 0;">This link expires in <strong style="color:#f4f1ea;">$expiresMinutes minutes</strong>.</p>
            </td>
          </tr>
          <tr>
            <td align="center" style="padding:4px 28px 28px 28px;">
              <a href="$safeUrl" style="display:inline-block;background:#d4a017;color:#12100a;text-decoration:none;font-family:Helvetica,Arial,sans-serif;font-size:15px;font-weight:700;letter-spacing:0.04em;padding:14px 28px;border-radius:2px;">Authorize Google Desktop</a>
            </td>
          </tr>
          <tr>
            <td style="padding:0 28px 28px 28px;color:#7f8fad;font-size:13px;line-height:1.5;font-family:Helvetica,Arial,sans-serif;">
              <p style="margin:0 0 10px 0;">If the button does not work, paste this URL into your browser:</p>
              <p style="margin:0;word-break:break-all;color:#a8b7d4;">$safeUrl</p>
            </td>
          </tr>
          <tr>
            <td style="padding:16px 28px 24px 28px;border-top:1px solid #24304a;color:#667790;font-size:12px;font-family:Helvetica,Arial,sans-serif;">
              Sent by COMSTAR after hallway Google pairing. If you did not request this, ignore the email.
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>
''';
  }

  static String _escape(String s) =>
      const HtmlEscape(HtmlEscapeMode.element).convert(s);
}

/// Packaged hero JPEG for inline CID attachment.
File? resolveComstarHeroEmail({String? packageRoot}) {
  final roots = <String>[
    if (packageRoot != null) packageRoot,
    Directory.current.path,
    if (Platform.script.scheme == 'file')
      p.dirname(p.dirname(Platform.script.toFilePath())),
  ];
  for (final root in roots) {
    for (final rel in [
      'assets/comstar-hero-email.jpg',
      'terminal/bridge/assets/comstar-hero-email.jpg',
    ]) {
      final f = File(p.join(root, rel));
      if (f.existsSync()) return f;
    }
  }
  return null;
}
