import 'package:comstar_bridge/mail/google_desktop_email.dart';
import 'package:comstar_bridge/mail/smtp_config.dart';
import 'package:test/test.dart';

void main() {
  group('SmtpConfig', () {
    test('null when incomplete', () {
      expect(SmtpConfig.fromEnvironment({}), isNull);
      expect(
        SmtpConfig.fromEnvironment({
          'COMSTAR_SMTP_HOST': 'smtp.example.com',
        }),
        isNull,
      );
    });

    test('parses full env', () {
      final cfg = SmtpConfig.fromEnvironment({
        'COMSTAR_SMTP_HOST': 'smtp.example.com',
        'COMSTAR_SMTP_PORT': '465',
        'COMSTAR_SMTP_USER': 'u',
        'COMSTAR_SMTP_PASSWORD': 'p',
        'COMSTAR_SMTP_FROM': 'comstar@example.com',
        'COMSTAR_SMTP_TLS': 'ssl',
        'COMSTAR_SMTP_FROM_NAME': 'Hallway',
      });
      expect(cfg, isNotNull);
      expect(cfg!.host, 'smtp.example.com');
      expect(cfg.port, 465);
      expect(cfg.useSsl, isTrue);
      expect(cfg.fromName, 'Hallway');
    });
  });

  group('GoogleDesktopUpgradeEmail', () {
    test('html includes hero cid and auth url', () {
      final mail = GoogleDesktopUpgradeEmail(
        displayName: 'zlatko',
        authUrl: 'https://example.test/start?state=abc',
        expiresMinutes: 30,
      );
      expect(mail.subject, contains('COMSTAR'));
      expect(mail.htmlBody, contains('cid:hero@comstar'));
      expect(mail.htmlBody, contains('Authorize Google Desktop'));
      expect(mail.htmlBody, contains('https://example.test/start?state=abc'));
      expect(mail.htmlBody, isNot(contains('<script')));
      expect(mail.textBody, contains('https://example.test/start?state=abc'));
    });

    test('escapes html in name', () {
      final mail = GoogleDesktopUpgradeEmail(
        displayName: 'a<b>&c',
        authUrl: 'https://x.test/',
        expiresMinutes: 10,
      );
      expect(mail.htmlBody, contains('a&lt;b&gt;&amp;c'));
    });
  });
}
