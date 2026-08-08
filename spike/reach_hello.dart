// M0.3 — connect to AO, register trivial overlay agent, directAgent("say hello"), stop.
import 'dart:io';

import 'package:ao_reach/ao_reach.dart';

Future<void> main(List<String> args) async {
  final mtlsOn = (Platform.environment['COMSTAR_AO_MTLS'] ?? '') == '1';
  final defaultBase =
      mtlsOn ? 'https://10.0.10.16:8765' : 'http://10.0.10.16:8765';
  final baseUrl = Platform.environment['AO_BASE_URL'] ?? defaultBase;
  final token = Platform.environment['AO_TOKEN'] ?? '';
  final mtlsDir = Platform.environment['COMSTAR_AO_MTLS_DIR'] ??
      '${Platform.environment['HOME']}/.local/share/comstar/ao-mtls';
  final overlay = Directory('overlays/hello');
  Directory('${overlay.path}/agent_providers').createSync(recursive: true);
  File('${overlay.path}/agent_providers/hello.yaml').writeAsStringSync('''
id: hello
type: ollama
name: Hello
description: Trivial probe agent for COMSTAR M0
role: COMSTAR Probe
goal: Reply with a short spoken hello
backstory: You are a brief voice probe agent for COMSTAR bring-up.
model: qwen2.5:14b-instruct
selfcontained: false
verbose: false
allow_delegation: false
system_prompt: |
  Reply with a single short spoken sentence saying hello. No markdown, no lists, no URLs.
''');

  final headers = <String, String>{
    'x-agentic-user-name': 'comstar-probe',
    'x-agentic-session-id':
        'comstar-probe-${DateTime.now().millisecondsSinceEpoch}',
  };
  if (token.isNotEmpty) headers['x-warpgate-token'] = token;

  ReachMtlsConfig? mtls;
  if (mtlsOn || Directory(mtlsDir).existsSync()) {
    mtls = ReachMtlsConfig(materialDir: mtlsDir);
    stdout.writeln('Using mTLS material at $mtlsDir');
  }

  final bridge = SessionBridge();
  stdout.writeln('Connecting to $baseUrl (appId=ComStar) …');
  try {
    await bridge.start(
      config: ReachConnectionConfig(
        appId: 'ComStar',
        baseUrl: baseUrl,
        headers: headers,
        ttlSeconds: 300,
        mtls: mtls,
      ),
      overlayRoot: overlay.path,
    );
    stdout.writeln(
      'state=${bridge.state} overlay=${bridge.sessionOverlay} '
      'tunnel=${bridge.mcpTunnel}',
    );
    stdout.writeln('agents=${bridge.registeredAgentIds}');
    final result = await bridge.directAgent(
      agentProviderId: 'client.hello',
      text: 'say hello',
      timeout: const Duration(seconds: 90),
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
