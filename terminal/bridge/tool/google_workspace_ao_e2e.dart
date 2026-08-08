/// Live AO + Google Workspace tunnel E2E (read-only prompts).
///
/// On the Pi:
///   cd /opt/comstar/src/terminal/bridge
///   set -a && source ~/.config/comstar/google.env && set +a
///   export GOOGLE_REFRESH_TOKEN="$(python3 -c "import json;print(json.load(open('$HOME/.local/share/comstar/google/zlatko.json'))['refresh_token'])")"
///   dart run tool/google_workspace_ao_e2e.dart
import 'dart:io';

import 'package:ao_reach/ao_reach.dart';
import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/google/token_store.dart';
import 'package:comstar_bridge/session.dart';
import 'package:path/path.dart' as p;

Future<void> main() async {
  final userid = Platform.environment['COMSTAR_USER'] ?? 'zlatko';
  final repoRoot = _repoRoot();
  final overlayRoot = p.join(repoRoot, 'overlays', 'comstar');
  final configPath = p.join(repoRoot, 'config', 'comstar.yaml');
  final examplePath = p.join(repoRoot, 'config', 'comstar.example.yaml');
  final config = File(configPath).existsSync()
      ? ComstarConfig.loadFile(configPath)
      : ComstarConfig.loadFile(examplePath);

  if ((Platform.environment['GOOGLE_CLIENT_ID'] ?? '').isEmpty ||
      (Platform.environment['GOOGLE_REFRESH_TOKEN'] ?? '').isEmpty) {
    stderr.writeln(
      'Need GOOGLE_CLIENT_ID/SECRET + GOOGLE_REFRESH_TOKEN in env',
    );
    exitCode = 2;
    return;
  }

  final tokenStore = GoogleTokenStore();
  await tokenStore.writeRefreshToken(
    userid,
    Platform.environment['GOOGLE_REFRESH_TOKEN']!,
  );

  final bootstrap = ComstarMcpBootstrap(config, tokenStore: tokenStore)
    ..guest = false
    ..userid = userid;

  final bridge = SessionBridge();
  final headers = <String, String>{
    'x-agentic-user-name': userid,
    'x-agentic-session-id':
        'comstar-$userid-google-e2e-${DateTime.now().millisecondsSinceEpoch}',
  };
  final token = config.orchestration.token;
  if (token.isNotEmpty) headers['x-warpgate-token'] = token;

  stdout.writeln('AO=${config.orchestration.baseUrl} user=$userid');
  var pass = 0;
  var fail = 0;

  try {
    await bridge.start(
      config: ReachConnectionConfig(
        appId: 'ComStar',
        baseUrl: config.orchestration.baseUrl,
        headers: headers,
        ttlSeconds: 600,
      ),
      overlayRoot: overlayRoot,
      mcpBootstrap: bootstrap,
    );
    stdout.writeln(
      'registered agents=${bridge.registeredAgentIds} '
      'mcps=${bridge.registeredMcpIds}',
    );
    if (!bridge.registeredMcpIds.contains('client.google_workspace')) {
      stderr.writeln('FAIL client.google_workspace not registered');
      exitCode = 1;
      return;
    }
    stdout.writeln('PASS google MCP registered');
    pass++;

    const prompts = <(String, String)>[
      (
        'cal_today',
        'What is on my Google Calendar today? '
            'You must call calendar_list_events for calendarId primary before answering. '
            'Reply with event titles only in one short spoken sentence.',
      ),
      (
        'cal_list',
        'List the names of my Google calendars using calendar_list_calendars. '
            'Reply in one short spoken sentence.',
      ),
      (
        'drive_list',
        'Using drive_list_files, say whether any Drive files are visible. '
            'One short spoken sentence. Empty is OK.',
      ),
      (
        'gmail_today',
        'Using gmail_list_emails for the last 24 hours, summarize inbox or '
            'say if Gmail is unauthorized. One short spoken sentence.',
      ),
    ];

    for (final (name, text) in prompts) {
      stdout.writeln('--- $name ---');
      stdout.writeln('Q: $text');
      try {
        final result = await bridge.directAgent(
          agentProviderId: 'client.voice_responder',
          text: text,
          mcpProviderIds: const ['client.google_workspace'],
          timeout: const Duration(seconds: 120),
        );
        final body = '${result['text'] ?? ''}'.trim();
        stdout.writeln('A: $body');
        final lower = body.toLowerCase();
        final denied = lower.contains("don't have access") ||
            lower.contains('do not have access') ||
            lower.contains("can't access") ||
            lower.contains('cannot access') ||
            lower.contains('no access to your google calendar');
        if (name.startsWith('cal_') && denied) {
          stderr.writeln('FAIL $name: model denied calendar access');
          fail++;
        } else if (body.isEmpty) {
          stderr.writeln('FAIL $name: empty reply');
          fail++;
        } else {
          stdout.writeln('PASS $name');
          pass++;
        }
      } catch (e) {
        stderr.writeln('FAIL $name: $e');
        fail++;
      }
    }
  } finally {
    await bridge.stop();
  }

  stdout.writeln('summary PASS=$pass FAIL=$fail');
  if (fail > 0) exitCode = 1;
}

String _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (Directory(p.join(dir.path, 'overlays', 'comstar')).existsSync() &&
        Directory(p.join(dir.path, 'terminal', 'bridge')).existsSync()) {
      return dir.path;
    }
    dir = dir.parent;
  }
  return p.normalize(p.join(Directory.current.path, '..', '..'));
}
