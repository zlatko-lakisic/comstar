/// M11.0.1 — Shared session semantics for terminal + text channel.
///
/// Empirically answers: can two surfaces attach to the same
/// `x-agentic-session-id: comstar-<uid>` concurrently, and does memory merge?
/// Fallback: distinct session ids (`comstar-<uid>` vs `comstar-<uid>-channel`)
/// sharing userid / KB scope.
///
/// Usage:
///   cd spike && dart run channel_session_probe.dart
///
/// Env:
///   AO_BASE_URL   default http://10.0.10.16:8765
///   AO_TOKEN      optional Warpgate token
///   COMSTAR_USER  default zlatko
///
/// Prints one JSON object per line. Save stdout to
/// docs/fixtures/channel_session_probe_<stamp>.log
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
    'question':
        'Can terminal + channel share x-agentic-session-id comstar-<uid>?',
  });

  final results = <String, Object?>{};

  try {
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

    results['same_session_id_channel_first'] = await _caseConcurrent(
      baseUrl: baseUrl,
      token: token,
      overlayRoot: overlayRoot,
      userid: userid,
      stamp: stamp + 1,
      label: 'same_session_id_channel_first',
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

    results['diff_session_id_channel_first'] = await _caseConcurrent(
      baseUrl: baseUrl,
      token: token,
      overlayRoot: overlayRoot,
      userid: userid,
      stamp: stamp + 3,
      label: 'diff_session_id_channel_first',
      sameSessionId: false,
      terminalFirst: false,
    );

    results['channel_stop_cycles'] = await _caseChannelStopCycles(
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
  final same = results['same_session_id_term_first'];
  if (same is Map && same['safe'] == true) {
    return 'same_session_id_looks_safe — unexpected; still prefer distinct '
        'channel ids for stop()/overlay isolation';
  }
  final diff = results['diff_session_id_term_first'];
  if (diff is Map && diff['safe'] == true) {
    return 'same_session_id_unsafe — channel uses comstar-<uid>-channel; '
        'shared memory via userid/KB not shared session overlay';
  }
  return 'concurrent_unsafe — investigate before shipping M11 sessions';
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
  // Product terminal session id shape: comstar-<uid>
  // Channel product id: comstar-<uid>-channel
  // Probe stamps avoid colliding with a live terminal.
  final termSession = sameSessionId
      ? 'comstar-$userid-chprobe-$stamp'
      : 'comstar-$userid-chprobe-$stamp';
  final channelSession =
      sameSessionId ? termSession : 'comstar-$userid-channel-$stamp';

  SessionBridge? term;
  SessionBridge? channel;
  try {
    Future<void> startTerm() async {
      term = await _start(
        baseUrl: baseUrl,
        token: token,
        overlayRoot: overlayRoot,
        userid: userid,
        sessionId: termSession,
        role: 'terminal',
      );
    }

    Future<void> startChannel() async {
      channel = await _start(
        baseUrl: baseUrl,
        token: token,
        overlayRoot: overlayRoot,
        userid: userid,
        sessionId: channelSession,
        role: 'channel',
      );
    }

    if (terminalFirst) {
      await startTerm();
      final a0 = List<String>.from(term!.registeredAgentIds);
      await startChannel();
      final a1Term = List<String>.from(term!.registeredAgentIds);
      final a1Ch = List<String>.from(channel!.registeredAgentIds);

      final chTurn = await _turn(
        channel!,
        role: 'channel',
        text:
            'Reply in one short sentence that the channel session is healthy.',
      );
      final termDuring = await _turn(
        term!,
        role: 'terminal',
        text:
            'Reply in one short sentence that the terminal session is still healthy.',
      );

      await channel!.stop(clearRemote: true);
      final a2Term = List<String>.from(term!.registeredAgentIds);
      final a2Ch = List<String>.from(channel!.registeredAgentIds);
      _emit('bridge_stop', {
        'role': 'channel',
        'label': label,
        'agents_channel_after': a2Ch,
        'agents_term_after': a2Term,
      });

      final termAfter = await _turn(
        term!,
        role: 'terminal',
        text:
            'Confirm in one short sentence you still respond after channel stop.',
      );

      await term!.stop(clearRemote: true);
      final termAgentsFinal = List<String>.from(term!.registeredAgentIds);

      final safe = chTurn['ok'] == true &&
          termDuring['ok'] == true &&
          termAfter['ok'] == true &&
          a2Ch.isEmpty &&
          a2Term.isNotEmpty &&
          termAgentsFinal.isEmpty;

      return {
        'label': label,
        'sameSessionId': sameSessionId,
        'terminalFirst': terminalFirst,
        'termSession': termSession,
        'channelSession': channelSession,
        'safe': safe,
        'a0_term': a0,
        'a1_term': a1Term,
        'a1_channel': a1Ch,
        'a2_term_after_channel_stop': a2Term,
        'a2_channel_after_stop': a2Ch,
        'channel_turn': chTurn,
        'term_during': termDuring,
        'term_after': termAfter,
        'term_agents_final': termAgentsFinal,
      };
    }

    await startChannel();
    await startTerm();
    final a1Term = List<String>.from(term!.registeredAgentIds);
    final a1Ch = List<String>.from(channel!.registeredAgentIds);

    final chTurn = await _turn(
      channel!,
      role: 'channel',
      text: 'Reply in one short sentence that the channel session is healthy.',
    );
    final termDuring = await _turn(
      term!,
      role: 'terminal',
      text: 'Reply in one short sentence that the terminal session is healthy.',
    );

    await channel!.stop(clearRemote: true);
    final a2Term = List<String>.from(term!.registeredAgentIds);
    final a2Ch = List<String>.from(channel!.registeredAgentIds);

    final termAfter = await _turn(
      term!,
      role: 'terminal',
      text: 'Confirm in one short sentence you still work after channel stop.',
    );

    await term!.stop(clearRemote: true);
    final termAgentsFinal = List<String>.from(term!.registeredAgentIds);

    final safe = chTurn['ok'] == true &&
        termDuring['ok'] == true &&
        termAfter['ok'] == true &&
        a2Ch.isEmpty &&
        a2Term.isNotEmpty &&
        termAgentsFinal.isEmpty;

    return {
      'label': label,
      'sameSessionId': sameSessionId,
      'terminalFirst': terminalFirst,
      'termSession': termSession,
      'channelSession': channelSession,
      'safe': safe,
      'a1_term': a1Term,
      'a1_channel': a1Ch,
      'a2_term_after_channel_stop': a2Term,
      'a2_channel_after_stop': a2Ch,
      'channel_turn': chTurn,
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
      await channel?.stop(clearRemote: true);
    } catch (_) {}
    try {
      await term?.stop(clearRemote: true);
    } catch (_) {}
  }
}

Future<Map<String, Object?>> _caseChannelStopCycles({
  required String baseUrl,
  required String token,
  required String overlayRoot,
  required String userid,
  required int stamp,
}) async {
  final termSession = 'comstar-$userid-chprobe-leak-$stamp';
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
      final chSession = 'comstar-$userid-channel-leak-$stamp-$i';
      SessionBridge? channel;
      try {
        channel = await _start(
          baseUrl: baseUrl,
          token: token,
          overlayRoot: overlayRoot,
          userid: userid,
          sessionId: chSession,
          role: 'channel',
        );
        await _turn(
          channel,
          role: 'channel',
          text: 'Say one word: ping.',
        );
        await channel.stop(clearRemote: true);
        final termAgents = List<String>.from(term.registeredAgentIds);
        final chAgents = List<String>.from(channel.registeredAgentIds);
        cycles.add({
          'i': i,
          'term_agents': termAgents,
          'channel_agents_after_stop': chAgents,
          'term_grew': termAgents.length > baseline.length,
        });
        _emit('leak_cycle', {
          'i': i,
          'baseline_n': baseline.length,
          'term_n': termAgents.length,
          'channel_after_n': chAgents.length,
        });
      } finally {
        try {
          await channel?.stop(clearRemote: true);
        } catch (_) {}
      }
    }

    final finalAgents = List<String>.from(term.registeredAgentIds);
    await term.stop(clearRemote: true);
    return {
      'ok': cycles.every((c) =>
          c['term_grew'] != true &&
          (c['channel_agents_after_stop'] is List &&
              (c['channel_agents_after_stop'] as List).isEmpty)),
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
