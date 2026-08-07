/// M10.0.1 — Session ownership probe for proactive announcements.
///
/// Empirically answers: can a short-lived announcer SessionBridge generate text
/// under the same userid as a concurrent "terminal" bridge without disturbing
/// that terminal or leaking overlays after stop()?
///
/// Usage (from repo root or spike/):
///   cd spike && dart run announce_session_probe.dart
///
/// Env:
///   AO_BASE_URL   default http://10.0.10.16:8765
///   AO_TOKEN      optional Warpgate token
///   COMSTAR_USER  default zlatko
///
/// Prints one JSON object per line. Save stdout to
/// docs/fixtures/announce_session_probe_<stamp>.log
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ao_reach/ao_reach.dart';
import 'package:path/path.dart' as p;

void _emit(String evt, Map<String, Object?> data) {
  stdout.writeln(jsonEncode({
    'ts': DateTime.now().toUtc().toIso8601String(),
    'evt': evt,
    ...data,
  }));
}

Future<void> main() async {
  final baseUrl = Platform.environment['AO_BASE_URL'] ?? 'http://10.0.10.16:8765';
  final token = Platform.environment['AO_TOKEN'] ?? '';
  final userid = Platform.environment['COMSTAR_USER'] ?? 'zlatko';
  final stamp = DateTime.now().millisecondsSinceEpoch;

  final repoRoot = Directory.current.path.endsWith('spike')
      ? Directory('..').absolute.path
      : Directory.current.absolute.path;
  final overlayRoot = p.normalize(p.join(repoRoot, 'overlays', 'comstar'));
  if (!Directory(overlayRoot).existsSync()) {
    stderr.writeln('Missing overlay: $overlayRoot');
    exit(2);
  }

  _emit('probe_start', {
    'baseUrl': baseUrl,
    'userid': userid,
    'overlayRoot': overlayRoot,
    'stamp': stamp,
  });

  final results = <String, Object?>{};

  try {
    results['alone'] = await _caseAlone(
      baseUrl: baseUrl,
      token: token,
      overlayRoot: overlayRoot,
      userid: userid,
      stamp: stamp,
    );

    results['same_session_id_term_first'] = await _caseConcurrent(
      baseUrl: baseUrl,
      token: token,
      overlayRoot: overlayRoot,
      userid: userid,
      stamp: stamp,
      label: 'same_session_id_term_first',
      sameSessionId: true,
      terminalFirst: true,
    );

    results['same_session_id_ann_first'] = await _caseConcurrent(
      baseUrl: baseUrl,
      token: token,
      overlayRoot: overlayRoot,
      userid: userid,
      stamp: stamp + 1,
      label: 'same_session_id_ann_first',
      sameSessionId: true,
      terminalFirst: false,
    );

    results['diff_session_id_term_first'] = await _caseConcurrent(
      baseUrl: baseUrl,
      token: token,
      overlayRoot: overlayRoot,
      userid: userid,
      stamp: stamp + 2,
      label: 'diff_session_id_term_first',
      sameSessionId: false,
      terminalFirst: true,
    );

    results['diff_session_id_ann_first'] = await _caseConcurrent(
      baseUrl: baseUrl,
      token: token,
      overlayRoot: overlayRoot,
      userid: userid,
      stamp: stamp + 3,
      label: 'diff_session_id_ann_first',
      sameSessionId: false,
      terminalFirst: false,
    );

    results['leak_cycles'] = await _caseLeakCycles(
      baseUrl: baseUrl,
      token: token,
      overlayRoot: overlayRoot,
      userid: userid,
      stamp: stamp + 4,
    );
  } catch (e, st) {
    _emit('probe_fatal', {'error': '$e', 'stack': '$st'});
    exitCode = 1;
  }

  _emit('probe_summary', {
    'userid': userid,
    'results': results,
    'decision_hint': _decisionHint(results),
  });
}

String _decisionHint(Map<String, Object?> results) {
  final diff = results['diff_session_id_term_first'];
  if (diff is Map && diff['safe'] == true) {
    return 'diff_session_id_looks_safe — announcer may use short-lived '
        'SessionBridge with session id comstar-<uid>-announce-*';
  }
  final same = results['same_session_id_term_first'];
  if (same is Map && same['safe'] == true) {
    return 'same_session_id_also_safe — unexpected; still prefer distinct announce ids';
  }
  return 'concurrent_unsafe — enqueue intent only; terminal generates text at delivery';
}

Map<String, String> _headers({
  required String userid,
  required String sessionId,
  required String token,
}) {
  final h = <String, String>{
    'x-agentic-user-name': userid,
    'x-agentic-session-id': sessionId,
  };
  if (token.isNotEmpty) h['x-warpgate-token'] = token;
  return h;
}

Future<SessionBridge> _start({
  required String baseUrl,
  required String token,
  required String overlayRoot,
  required String userid,
  required String sessionId,
  required String role,
}) async {
  final bridge = SessionBridge();
  final sw = Stopwatch()..start();
  try {
    await bridge.start(
      config: ReachConnectionConfig(
        baseUrl: baseUrl,
        headers: _headers(userid: userid, sessionId: sessionId, token: token),
        ttlSeconds: 600,
      ),
      overlayRoot: overlayRoot,
    );
    _emit('bridge_start_ok', {
      'role': role,
      'sessionId': sessionId,
      'ms': sw.elapsedMilliseconds,
      'agents': bridge.registeredAgentIds,
      'state': '${bridge.state}',
      'overlay': bridge.sessionOverlay,
    });
  } catch (e) {
    _emit('bridge_start_fail', {
      'role': role,
      'sessionId': sessionId,
      'ms': sw.elapsedMilliseconds,
      'error': '$e',
    });
    rethrow;
  }
  return bridge;
}

Future<Map<String, Object?>> _turn(
  SessionBridge bridge, {
  required String role,
  required String text,
}) async {
  final sw = Stopwatch()..start();
  try {
    final result = await bridge.directAgent(
      agentProviderId: 'client.greeter',
      text: text,
      timeout: const Duration(seconds: 90),
    );
    final body = '${result['text'] ?? ''}'.trim();
    final ok = result['ok'] == true && body.isNotEmpty;
    _emit('turn', {
      'role': role,
      'ok': ok,
      'ms': sw.elapsedMilliseconds,
      'text': body.length > 200 ? '${body.substring(0, 200)}…' : body,
      'agents': bridge.registeredAgentIds,
    });
    return {
      'ok': ok,
      'ms': sw.elapsedMilliseconds,
      'text': body,
      'agents': List<String>.from(bridge.registeredAgentIds),
    };
  } catch (e) {
    _emit('turn_fail', {
      'role': role,
      'ms': sw.elapsedMilliseconds,
      'error': '$e',
      'agents': bridge.registeredAgentIds,
    });
    return {
      'ok': false,
      'ms': sw.elapsedMilliseconds,
      'error': '$e',
      'agents': List<String>.from(bridge.registeredAgentIds),
    };
  }
}

Future<Map<String, Object?>> _caseAlone({
  required String baseUrl,
  required String token,
  required String overlayRoot,
  required String userid,
  required int stamp,
}) async {
  final sessionId = 'comstar-$userid-announce-alone-$stamp';
  SessionBridge? ann;
  try {
    ann = await _start(
      baseUrl: baseUrl,
      token: token,
      overlayRoot: overlayRoot,
      userid: userid,
      sessionId: sessionId,
      role: 'announcer',
    );
    final agentsBefore = List<String>.from(ann.registeredAgentIds);
    final turn = await _turn(
      ann,
      role: 'announcer',
      text:
          'Announce in one short spoken sentence: you have a calendar note in 30 minutes. No greeting fluff.',
    );
    await ann.stop(clearRemote: true);
    final agentsAfter = List<String>.from(ann.registeredAgentIds);
    _emit('bridge_stop', {
      'role': 'announcer',
      'sessionId': sessionId,
      'agents_after_stop': agentsAfter,
    });
    final ok = turn['ok'] == true && agentsAfter.isEmpty;
    return {
      'ok': ok,
      'sessionId': sessionId,
      'agents_before': agentsBefore,
      'turn': turn,
      'agents_after_stop': agentsAfter,
    };
  } catch (e) {
    return {'ok': false, 'error': '$e'};
  } finally {
    try {
      await ann?.stop(clearRemote: true);
    } catch (_) {}
  }
}

Future<Map<String, Object?>> _caseConcurrent({
  required String baseUrl,
  required String token,
  required String overlayRoot,
  required String userid,
  required int stamp,
  required String label,
  required bool sameSessionId,
  required bool terminalFirst,
}) async {
  final termSession = sameSessionId
      ? 'comstar-$userid-probe-$stamp'
      : 'comstar-$userid-probe-$stamp';
  final annSession = sameSessionId
      ? termSession
      : 'comstar-$userid-announce-$stamp';

  SessionBridge? term;
  SessionBridge? ann;
  try {
    if (terminalFirst) {
      term = await _start(
        baseUrl: baseUrl,
        token: token,
        overlayRoot: overlayRoot,
        userid: userid,
        sessionId: termSession,
        role: 'terminal',
      );
      final a0 = List<String>.from(term.registeredAgentIds);
      ann = await _start(
        baseUrl: baseUrl,
        token: token,
        overlayRoot: overlayRoot,
        userid: userid,
        sessionId: annSession,
        role: 'announcer',
      );
      final a1Term = List<String>.from(term.registeredAgentIds);
      final a1Ann = List<String>.from(ann.registeredAgentIds);

      final annTurn = await _turn(
        ann,
        role: 'announcer',
        text:
            'Announce in one short spoken sentence: package at the door. No greeting.',
      );
      final termDuring = await _turn(
        term,
        role: 'terminal',
        text: 'Reply in one short spoken sentence that the terminal session is still healthy.',
      );

      await ann.stop(clearRemote: true);
      final a2Term = List<String>.from(term.registeredAgentIds);
      final a2Ann = List<String>.from(ann.registeredAgentIds);
      _emit('bridge_stop', {
        'role': 'announcer',
        'label': label,
        'agents_ann_after': a2Ann,
        'agents_term_after': a2Term,
      });

      final termAfter = await _turn(
        term,
        role: 'terminal',
        text: 'Confirm in one short spoken sentence you are still responding after announcer stop.',
      );

      await term.stop(clearRemote: true);
      final termAgentsFinal = List<String>.from(term.registeredAgentIds);

      final safe = annTurn['ok'] == true &&
          termDuring['ok'] == true &&
          termAfter['ok'] == true &&
          a2Ann.isEmpty &&
          // Terminal agents should remain non-empty while terminal is up after ann stop
          a2Term.isNotEmpty &&
          termAgentsFinal.isEmpty;

      return {
        'label': label,
        'sameSessionId': sameSessionId,
        'terminalFirst': terminalFirst,
        'termSession': termSession,
        'annSession': annSession,
        'safe': safe,
        'a0_term': a0,
        'a1_term': a1Term,
        'a1_ann': a1Ann,
        'a2_term_after_ann_stop': a2Term,
        'a2_ann_after_stop': a2Ann,
        'ann_turn': annTurn,
        'term_during': termDuring,
        'term_after': termAfter,
        'term_agents_final': termAgentsFinal,
      };
    }

    // Announcer first, then terminal.
    ann = await _start(
      baseUrl: baseUrl,
      token: token,
      overlayRoot: overlayRoot,
      userid: userid,
      sessionId: annSession,
      role: 'announcer',
    );
    term = await _start(
      baseUrl: baseUrl,
      token: token,
      overlayRoot: overlayRoot,
      userid: userid,
      sessionId: termSession,
      role: 'terminal',
    );
    final a1Term = List<String>.from(term.registeredAgentIds);
    final a1Ann = List<String>.from(ann.registeredAgentIds);

    final annTurn = await _turn(
      ann,
      role: 'announcer',
      text:
          'Announce in one short spoken sentence: reminder to take trash out. No greeting.',
    );
    final termDuring = await _turn(
      term,
      role: 'terminal',
      text: 'Reply in one short spoken sentence that the terminal session is healthy.',
    );

    await ann.stop(clearRemote: true);
    final a2Term = List<String>.from(term.registeredAgentIds);
    final a2Ann = List<String>.from(ann.registeredAgentIds);

    final termAfter = await _turn(
      term,
      role: 'terminal',
      text: 'Confirm in one short spoken sentence you still work after announcer stop.',
    );

    await term.stop(clearRemote: true);
    final termAgentsFinal = List<String>.from(term.registeredAgentIds);

    final safe = annTurn['ok'] == true &&
        termDuring['ok'] == true &&
        termAfter['ok'] == true &&
        a2Ann.isEmpty &&
        a2Term.isNotEmpty &&
        termAgentsFinal.isEmpty;

    return {
      'label': label,
      'sameSessionId': sameSessionId,
      'terminalFirst': terminalFirst,
      'termSession': termSession,
      'annSession': annSession,
      'safe': safe,
      'a1_term': a1Term,
      'a1_ann': a1Ann,
      'a2_term_after_ann_stop': a2Term,
      'a2_ann_after_stop': a2Ann,
      'ann_turn': annTurn,
      'term_during': termDuring,
      'term_after': termAfter,
      'term_agents_final': termAgentsFinal,
    };
  } catch (e) {
    _emit('case_fail', {'label': label, 'error': '$e'});
    return {
      'label': label,
      'sameSessionId': sameSessionId,
      'terminalFirst': terminalFirst,
      'safe': false,
      'error': '$e',
    };
  } finally {
    try {
      await ann?.stop(clearRemote: true);
    } catch (_) {}
    try {
      await term?.stop(clearRemote: true);
    } catch (_) {}
  }
}

Future<Map<String, Object?>> _caseLeakCycles({
  required String baseUrl,
  required String token,
  required String overlayRoot,
  required String userid,
  required int stamp,
}) async {
  final termSession = 'comstar-$userid-probe-leak-$stamp';
  SessionBridge? term;
  final cycles = <Map<String, Object?>>[];
  try {
    term = await _start(
      baseUrl: baseUrl,
      token: token,
      overlayRoot: overlayRoot,
      userid: userid,
      sessionId: termSession,
      role: 'terminal',
    );
    final baseline = List<String>.from(term.registeredAgentIds);

    for (var i = 0; i < 3; i++) {
      final annSession = 'comstar-$userid-announce-leak-$stamp-$i';
      SessionBridge? ann;
      try {
        ann = await _start(
          baseUrl: baseUrl,
          token: token,
          overlayRoot: overlayRoot,
          userid: userid,
          sessionId: annSession,
          role: 'announcer',
        );
        await _turn(
          ann,
          role: 'announcer',
          text: 'Say one word: ping.',
        );
        await ann.stop(clearRemote: true);
        final termAgents = List<String>.from(term.registeredAgentIds);
        final annAgents = List<String>.from(ann.registeredAgentIds);
        cycles.add({
          'i': i,
          'term_agents': termAgents,
          'ann_agents_after_stop': annAgents,
          'term_grew': termAgents.length > baseline.length,
        });
        _emit('leak_cycle', {
          'i': i,
          'baseline_n': baseline.length,
          'term_n': termAgents.length,
          'ann_after_n': annAgents.length,
        });
      } finally {
        try {
          await ann?.stop(clearRemote: true);
        } catch (_) {}
      }
    }

    final finalAgents = List<String>.from(term.registeredAgentIds);
    await term.stop(clearRemote: true);
    return {
      'ok': cycles.every((c) => c['term_grew'] != true && c['ann_agents_after_stop'] == <String>[] ||
          (c['ann_agents_after_stop'] is List && (c['ann_agents_after_stop'] as List).isEmpty)),
      'baseline': baseline,
      'cycles': cycles,
      'final_term_agents': finalAgents,
    };
  } catch (e) {
    return {'ok': false, 'error': '$e', 'cycles': cycles};
  } finally {
    try {
      await term?.stop(clearRemote: true);
    } catch (_) {}
  }
}
