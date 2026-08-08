/// Live AO + Nextcloud tunnel E2E (read-only prompts).
///
/// Prerequisites:
///   - `uv`/`uvx` or `nextcloud-mcp-server` on PATH
///   - Credentials in env or token store
///
///   export NEXTCLOUD_HOST=https://cloud.example
///   export NEXTCLOUD_USERNAME=…
///   export NEXTCLOUD_PASSWORD=…   # app password
///   export COMSTAR_USER=zlatko
///   cd terminal/bridge && dart run tool/nextcloud_ao_e2e.dart
import 'dart:io';

import 'package:ao_reach/ao_reach.dart';
import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/google/token_store.dart';
import 'package:comstar_bridge/nextcloud/token_store.dart';
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

  final host = Platform.environment['NEXTCLOUD_HOST']?.trim() ?? '';
  final username = Platform.environment['NEXTCLOUD_USERNAME']?.trim() ?? '';
  final password = Platform.environment['NEXTCLOUD_PASSWORD']?.trim() ?? '';

  final ncStore = NextcloudTokenStore();
  if (host.isNotEmpty && username.isNotEmpty && password.isNotEmpty) {
    await ncStore.writeCredentials(
      userid,
      username: username,
      appPassword: password,
      host: host,
    );
  } else if (!await ncStore.hasCredentials(userid)) {
    stderr.writeln(
      'Need NEXTCLOUD_HOST + NEXTCLOUD_USERNAME + NEXTCLOUD_PASSWORD '
      'or an existing token at ~/.local/share/comstar/nextcloud/$userid.json',
    );
    exitCode = 2;
    return;
  }

  final bootstrap = ComstarMcpBootstrap(
    config,
    tokenStore: GoogleTokenStore(),
    nextcloudTokenStore: ncStore,
  )
    ..guest = false
    ..userid = userid;

  final bridge = SessionBridge();
  final headers = <String, String>{
    'x-agentic-user-name': userid,
    'x-agentic-session-id':
        'comstar-$userid-nc-e2e-${DateTime.now().millisecondsSinceEpoch}',
  };
  final token = config.orchestration.token;
  if (token.isNotEmpty) headers['x-warpgate-token'] = token;

  stdout.writeln('AO=${config.orchestration.baseUrl} user=$userid');
  var pass = 0;
  var fail = 0;

  try {
    await bridge.start(
      config: ReachConnectionConfig(
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
    if (!bridge.registeredMcpIds.contains('client.nextcloud')) {
      stderr.writeln('FAIL client.nextcloud not registered');
      stderr.writeln(
        'Hint: install uv (https://docs.astral.sh/uv/) or '
        'pip install nextcloud-mcp-server',
      );
      exitCode = 1;
      return;
    }
    stdout.writeln('PASS nextcloud MCP registered');
    pass++;

    const prompts = <(String, String)>[
      (
        'nc_cal',
        'Using Nextcloud tools, what is on my Nextcloud calendar in the next '
            '7 days? Call nc_calendar_get_upcoming_events or '
            'nc_calendar_list_events. One short spoken sentence.',
      ),
      (
        'nc_notes',
        'Using nc_notes_search_notes with an empty or broad query, say whether '
            'any Nextcloud notes are visible. One short spoken sentence.',
      ),
      (
        'nc_files',
        'Using nc_webdav_list_directory on the home folder, say whether any '
            'files or folders are visible. One short spoken sentence.',
      ),
    ];

    for (final (name, text) in prompts) {
      stdout.writeln('--- $name ---');
      stdout.writeln('Q: $text');
      try {
        final result = await bridge.directAgent(
          agentProviderId: 'client.voice_responder',
          text: text,
          mcpProviderIds: const ['client.nextcloud'],
          timeout: const Duration(seconds: 120),
        );
        final body = '${result['text'] ?? ''}'.trim();
        stdout.writeln('A: $body');
        final lower = body.toLowerCase();
        final denied = lower.contains("don't have access") ||
            lower.contains('do not have access') ||
            lower.contains("can't access") ||
            lower.contains('cannot access');
        if (denied) {
          stderr.writeln('FAIL $name: model denied access');
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
