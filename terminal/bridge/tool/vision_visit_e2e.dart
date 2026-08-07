/// Live Ada vision MCP `who_visited` — asserts a non-empty spoken_hint in time.
///
/// On the Pi (or any host that can reach Ada):
///   export COMSTAR_VISION_MCP_URL=http://10.0.10.16:8793/mcp
///   cd /opt/comstar/src/terminal/bridge
///   dart run tool/vision_visit_e2e.dart
///
/// Exit 0 only when each case returns a usable spoken line under the deadline.
import 'dart:io';

import 'package:comstar_bridge/vision_mcp_client.dart';
import 'package:comstar_bridge/vision_visit_intent.dart';

Future<void> main() async {
  final url = Platform.environment['COMSTAR_VISION_MCP_URL']?.trim() ??
      'http://10.0.10.16:8793/mcp';
  stdout.writeln('VISION_MCP=$url');

  final client = VisionMcpClient(baseUrlOverride: url);
  var pass = 0;
  var fail = 0;

  const cases = <(String, String, String, Duration)>[
    // label, camera, since, max wall time
    ('today', 'driveway', 'today', Duration(seconds: 45)),
    ('yesterday', 'driveway', 'yesterday', Duration(seconds: 75)),
  ];

  for (final (label, camera, since, budget) in cases) {
    stdout.writeln('--- $label camera=$camera since=$since ---');
    final t0 = DateTime.now();
    try {
      final hint = await client
          .whoVisitedSpoken(
            camera: camera,
            since: since,
            maxUnknown: 3,
            timeout: budget,
          )
          .timeout(budget);
      final ms = DateTime.now().difference(t0).inMilliseconds;
      final spoken = hint == null ? '' : clipSpokenHint(hint);
      if (spoken.isEmpty) {
        stderr.writeln('FAIL $label ${ms}ms empty spoken_hint');
        fail++;
        continue;
      }
      // Empty day is still a valid answer ("I did not see any people…").
      final lower = spoken.toLowerCase();
      final plausible = lower.contains('did not see') ||
          lower.contains('recognized') ||
          lower.contains('unrecognized') ||
          lower.contains('visit') ||
          lower.contains('person') ||
          RegExp(r'\b(am|pm)\b').hasMatch(lower);
      if (!plausible) {
        stderr.writeln('FAIL $label ${ms}ms implausible: $spoken');
        fail++;
        continue;
      }
      stdout.writeln('PASS $label ${ms}ms chars=${spoken.length}');
      stdout.writeln(spoken);
      pass++;
    } catch (e) {
      final ms = DateTime.now().difference(t0).inMilliseconds;
      stderr.writeln('FAIL $label ${ms}ms $e');
      fail++;
    }
  }

  // Named last-seen must come from Frigate labels, not chat memory.
  stdout.writeln('--- last_seen Adna ---');
  final tAdna = DateTime.now();
  try {
    final hint = await client.personLastSeenSpoken(name: 'Adna').timeout(
      const Duration(seconds: 30),
    );
    final ms = DateTime.now().difference(tAdna).inMilliseconds;
    final spoken = hint ?? '';
    final lower = spoken.toLowerCase();
    // Must not claim driveway Zlatko times as Adna.
    final bad = lower.contains('driveway') &&
        (lower.contains('5:13') || lower.contains('5:15'));
    if (spoken.isEmpty) {
      stderr.writeln('FAIL last_seen_adna ${ms}ms empty');
      fail++;
    } else if (bad) {
      stderr.writeln(
        'FAIL last_seen_adna ${ms}ms misattributed driveway: $spoken',
      );
      fail++;
    } else if (!lower.contains('adna')) {
      stderr.writeln('FAIL last_seen_adna ${ms}ms no Adna: $spoken');
      fail++;
    } else {
      stdout.writeln('PASS last_seen_adna ${ms}ms');
      stdout.writeln(spoken);
      pass++;
    }
  } catch (e) {
    stderr.writeln('FAIL last_seen_adna $e');
    fail++;
  }

  // Intent parsing sanity (no network).
  for (final q in [
    'Who was in my driveway today?',
    'Who was in my driveway yesterday?',
    'When was the last time you saw Adna?',
  ]) {
    final i = parseVisionVisitIntent(q);
    if (i == null) {
      stderr.writeln('FAIL parse: $q');
      fail++;
    } else {
      stdout.writeln(
        'PASS parse $q → ${i.kind.name}/${i.camera}/${i.since}/${i.personName}',
      );
      pass++;
    }
  }

  client.close();
  stdout.writeln('summary PASS=$pass FAIL=$fail');
  if (fail > 0) exitCode = 1;
}
