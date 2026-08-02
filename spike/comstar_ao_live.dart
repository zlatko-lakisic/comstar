import 'dart:io';
import 'package:ao_reach/ao_reach.dart';
import 'package:path/path.dart' as p;

Future<void> main() async {
  final baseUrl = Platform.environment['AO_BASE_URL'] ?? 'http://10.0.10.16:8765';
  final repoRoot = Directory.current.path.endsWith('spike')
      ? Directory('..').absolute.path
      : Directory.current.absolute.path;
  final overlayRoot = p.normalize(p.join(repoRoot, 'overlays', 'comstar'));
  final userid = Platform.environment['COMSTAR_USER'] ?? 'zlatko';

  final bridge = SessionBridge();
  stdout.writeln('AO=$baseUrl overlay=$overlayRoot user=$userid');
  final sw = Stopwatch()..start();
  try {
    await bridge.start(
      config: ReachConnectionConfig(
        baseUrl: baseUrl,
        headers: {
          'x-agentic-user-name': userid,
          'x-agentic-session-id':
              'comstar-$userid-live-${DateTime.now().millisecondsSinceEpoch}',
        },
        ttlSeconds: 600,
      ),
      overlayRoot: overlayRoot,
    );
    stdout.writeln(
      'CONNECT ${sw.elapsedMilliseconds}ms state=${bridge.state} '
      'overlay=${bridge.sessionOverlay} tunnel=${bridge.mcpTunnel}',
    );
    stdout.writeln('agents=${bridge.registeredAgentIds}');

    Future<Map<String, dynamic>> run(
      String id,
      String text, {
      List<String>? mcps,
    }) async {
      sw.reset();
      final result = await bridge.directAgent(
        agentProviderId: id,
        text: text,
        mcpProviderIds: mcps ?? const [],
        timeout: const Duration(seconds: 90),
      );
      final ms = sw.elapsedMilliseconds;
      final ok = result['ok'] == true;
      final body = '${result['text'] ?? ''}'.trim();
      stdout.writeln('$id ${ms}ms ok=$ok');
      stdout.writeln('  text=$body');
      if (!ok || body.isEmpty) throw StateError('$id failed or empty: $result');
      return result;
    }

    await run(
      'client.greeter',
      'User $userid just walked up this evening. Greet them by name in one short sentence.',
    );
    await run(
      'client.voice_responder',
      'Confirm in one short spoken sentence that COMSTAR is connected to the orchestration engine.',
    );

    await bridge.stop();
    await bridge.start(
      config: ReachConnectionConfig(
        baseUrl: baseUrl,
        headers: {
          'x-agentic-user-name': 'guest',
          'x-agentic-session-id':
              'comstar-guest-${DateTime.now().millisecondsSinceEpoch}',
        },
        ttlSeconds: 300,
      ),
      overlayRoot: overlayRoot,
    );
    await run(
      'client.greeter',
      'An unknown visitor arrived. Give a short polite greeting without personal data.',
    );

    try {
      final probe = await run(
        'client.voice_responder',
        'Say only the words: transcription tool linked.',
        mcps: const ['media_audio_transcribe'],
      );
      stdout.writeln('STT_MCP_PROBE ok => $probe');
    } catch (e) {
      stdout.writeln('STT_MCP_PROBE failed: $e');
    }

    stdout.writeln('PASS');
  } catch (e, st) {
    stderr.writeln('FAIL: $e');
    stderr.writeln(st);
    exitCode = 1;
  } finally {
    await bridge.stop();
    stdout.writeln('stopped');
  }
}
