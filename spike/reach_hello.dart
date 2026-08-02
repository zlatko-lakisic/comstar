// M0.3 — connect to AO, register trivial overlay agent, directAgent("say hello"), stop.
import 'dart:io';
import 'package:ao_reach/ao_reach.dart';

Future<void> main(List<String> args) async {
  final baseUrl = Platform.environment['AO_BASE_URL'] ?? 'http://10.0.10.16:8765';
  final token = Platform.environment['AO_TOKEN'] ?? '';
  final overlay = Directory('overlays/hello');
  overlay.createSync(recursive: true);
  Directory('${overlay.path}/agent_providers').createSync(recursive: true);
  File('${overlay.path}/agent_providers/hello.yaml').writeAsStringSync('''
id: hello
name: Hello
description: Trivial probe agent
system_prompt: |
  Reply with a single short spoken sentence saying hello. No markdown.
model: qwen2.5:14b-instruct
''');

  final headers = <String, String>{
    'x-agentic-user-name': 'comstar-probe',
    'x-agentic-session-id': 'comstar-probe-${DateTime.now().millisecondsSinceEpoch}',
  };
  if (token.isNotEmpty) headers['x-warpgate-token'] = token;

  final bridge = SessionBridge();
  stdout.writeln('Connecting to $baseUrl …');
  try {
    await bridge.start(
      config: ReachConnectionConfig(
        baseUrl: baseUrl,
        headers: headers,
        ttlSeconds: 300,
      ),
      overlayRoot: overlay.path,
    );
    stdout.writeln('state=${bridge.state} overlay=${bridge.sessionOverlay} tunnel=${bridge.mcpTunnel}');
    stdout.writeln('agents=${bridge.registeredAgentIds}');
    final result = await bridge.directAgent(
      agentProviderId: 'client.hello',
      text: 'say hello',
      timeout: const Duration(seconds: 60),
    );
    stdout.writeln('RESULT: $result');
  } catch (e, st) {
    stderr.writeln('FAIL: $e');
    stderr.writeln(st);
    exitCode = 1;
  } finally {
    await bridge.stop();
    stdout.writeln('stopped');
  }
}
