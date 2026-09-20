import 'package:comstar_bridge/voice/narration_policy.dart';
import 'package:comstar_bridge/voice/phrase_bank.dart';
import 'package:test/test.dart';

NarrationPhraseBank _fixedBank() {
  // One deterministic line per bank so golden transcripts are exact.
  return NarrationPhraseBank(
    banks: {
      for (final id in NarrationBank.all)
        id: [
          switch (id) {
            NarrationBank.stage0Ack => 'Okay, on it.',
            NarrationBank.stage1Planning =>
              'Let me work out how to do that.',
            NarrationBank.stage2Generic => 'Working on it now.',
            NarrationBank.stage2Web => 'Checking the news now.',
            NarrationBank.stage2Knowledge => 'Looking through what I know.',
            NarrationBank.stage2House => 'Checking the house now.',
            NarrationBank.stage3Composing => 'Putting that together now.',
            NarrationBank.heartbeatTier1 => 'Still on it.',
            NarrationBank.heartbeatTier2 =>
              'This one is taking a bit longer.',
            NarrationBank.heartbeatTier3 =>
              'Still going, longer than I expected.',
            NarrationBank.resultPreface => "Here's what I found.",
            NarrationBank.queuePositionTwo =>
              "There's one ahead of you, give me a moment.",
            NarrationBank.queuePositionMany =>
              'There are {n} ahead of you, this will take a moment.',
            _ => 'Fallback line.',
          },
        ],
    },
    recentRingSize: 3,
  );
}

NarrationPolicy _policy({
  NarrationPhraseBank? phrases,
  VoiceNarrationSettings settings = const VoiceNarrationSettings(),
  List<String>? unknownPhaseLog,
}) {
  return NarrationPolicy(
    phrases: phrases ?? _fixedBank(),
    settings: settings,
    onInfoLog: (msg, {data}) {
      unknownPhaseLog?.add('${data?['phase']}');
    },
  );
}

List<NarrationUtterance> _drive({
  required NarrationPolicy policy,
  required String turnId,
  required List<(int ms, void Function(NarrationPolicy p, int now) action)>
      script,
}) {
  final spoken = <NarrationUtterance>[];
  policy.startTurn(turnId: turnId, nowMs: 0);
  for (final step in script) {
    final now = step.$1;
    step.$2(policy, now);
    final u = policy.onTick(nowMs: now);
    if (u != null) spoken.add(u);
  }
  return spoken;
}

void main() {
  group('NarrationPolicy', () {
    test('fast turn under 2.5s: no progress, no preface', () {
      final policy = _policy();
      policy.startTurn(turnId: 'fast', nowMs: 0);
      policy.onStatus(
        const NarrationStatusFrame(phase: 'starting'),
        nowMs: 300,
      );
      expect(policy.onTick(nowMs: 1000), isNull);
      expect(policy.onTick(nowMs: 1800), isNull);
      final done = policy.onDone(nowMs: 1800);
      expect(done.preface, isNull);
      expect(policy.didSpeak, isFalse);
    });

    test('Run A — news research golden transcript', () {
      // §4.1: stage2@2.5s, heartbeat@17.5s, preface@21s (stage3 discarded).
      final spoken = _drive(
        policy: _policy(),
        turnId: 'news-a',
        script: [
          (300, (p, now) {
            p.onStatus(
              const NarrationStatusFrame(phase: 'starting'),
              nowMs: now,
            );
          }),
          (1800, (p, now) {
            p.onStatus(
              const NarrationStatusFrame(
                phase: 'generating',
                toolHint: 'fetch_url',
                categoryHint: NarrationCategory.web,
              ),
              nowMs: now,
            );
          }),
          (2500, (p, now) {}),
          (17500, (p, now) {}),
          (19000, (p, now) {
            p.onStatus(
              const NarrationStatusFrame(phase: 'preparing_response'),
              nowMs: now,
            );
          }),
        ],
      );
      expect(spoken.map((u) => u.atMs).toList(), [2500, 17500]);
      expect(spoken[0].text, 'Checking the news now.');
      expect(spoken[0].bank, NarrationBank.stage2Web);
      expect(spoken[1].text, 'Still on it.');
      expect(spoken[1].bank, NarrationBank.heartbeatTier1);

      final policy = _policy();
      // Replay to get preface decision at 21s.
      _drive(
        policy: policy,
        turnId: 'news-a',
        script: [
          (300, (p, now) {
            p.onStatus(
              const NarrationStatusFrame(phase: 'starting'),
              nowMs: now,
            );
          }),
          (1800, (p, now) {
            p.onStatus(
              const NarrationStatusFrame(
                phase: 'generating',
                categoryHint: NarrationCategory.web,
              ),
              nowMs: now,
            );
          }),
          (2500, (p, now) {}),
          (17500, (p, now) {}),
          (19000, (p, now) {
            p.onStatus(
              const NarrationStatusFrame(phase: 'preparing_response'),
              nowMs: now,
            );
          }),
        ],
      );
      final done = policy.onDone(nowMs: 21000);
      expect(done.preface, "Here's what I found.");
    });

    test('Run B — dynamic planner golden transcript', () {
      final spoken = _drive(
        policy: _policy(),
        turnId: 'plan-b',
        script: [
          (400, (p, now) {
            p.onStatus(
              const NarrationStatusFrame(phase: 'starting'),
              nowMs: now,
            );
          }),
          (1500, (p, now) {
            p.onStatus(
              const NarrationStatusFrame(phase: 'planning'),
              nowMs: now,
            );
          }),
          (2500, (p, now) {}),
          (3100, (p, now) {
            p.onStatus(
              const NarrationStatusFrame(phase: 'planned'),
              nowMs: now,
            );
          }),
          (4200, (p, now) {
            p.onStatus(
              const NarrationStatusFrame(phase: 'executing'),
              nowMs: now,
            );
          }),
          (6000, (p, now) {
            p.onStatus(
              const NarrationStatusFrame(
                phase: 'generating',
                categoryHint: NarrationCategory.web,
              ),
              nowMs: now,
            );
          }),
          (14500, (p, now) {}),
          (29500, (p, now) {}),
          (31000, (p, now) {
            p.onStatus(
              const NarrationStatusFrame(phase: 'preparing_response'),
              nowMs: now,
            );
          }),
        ],
      );
      expect(spoken.map((u) => u.atMs).toList(), [2500, 14500, 29500]);
      expect(spoken[0].text, 'Let me work out how to do that.');
      expect(spoken[1].text, 'Checking the news now.');
      expect(spoken[2].bank, NarrationBank.heartbeatTier1);
      expect(spoken[2].heartbeatTier, 1);
    });

    test('four phase changes in one stage → one utterance', () {
      final spoken = _drive(
        policy: _policy(),
        turnId: 'one-stage',
        script: [
          (100, (p, now) {
            p.onStatus(
              const NarrationStatusFrame(phase: 'executing'),
              nowMs: now,
            );
          }),
          (200, (p, now) {
            p.onStatus(
              const NarrationStatusFrame(phase: 'warming_agent'),
              nowMs: now,
            );
          }),
          (300, (p, now) {
            p.onStatus(
              const NarrationStatusFrame(phase: 'generating'),
              nowMs: now,
            );
          }),
          (400, (p, now) {
            p.onStatus(
              const NarrationStatusFrame(phase: 'step'),
              nowMs: now,
            );
          }),
          (2500, (p, now) {}),
        ],
      );
      expect(spoken, hasLength(1));
      expect(spoken.single.stage, 2);
    });

    test('two stage increases inside min_gap → later stage only', () {
      final spoken = _drive(
        policy: _policy(),
        turnId: 'gap',
        script: [
          (100, (p, now) {
            p.onStatus(
              const NarrationStatusFrame(phase: 'planning'),
              nowMs: now,
            );
          }),
          (2500, (p, now) {}),
          (3000, (p, now) {
            p.onStatus(
              const NarrationStatusFrame(phase: 'executing'),
              nowMs: now,
            );
          }),
          (4000, (p, now) {}), // gap not met
          (14500, (p, now) {}), // gap met → stage 2
        ],
      );
      expect(spoken, hasLength(2));
      expect(spoken[0].stage, 1);
      expect(spoken[1].stage, 2);
    });

    test('queued position 1 silent; position 2 speaks once', () {
      final spoken = _drive(
        policy: _policy(),
        turnId: 'q',
        script: [
          (100, (p, now) {
            p.onStatus(
              const NarrationStatusFrame(phase: 'queued', queuePosition: 1),
              nowMs: now,
            );
          }),
          (2500, (p, now) {}),
          (3000, (p, now) {
            p.onStatus(
              const NarrationStatusFrame(phase: 'queued', queuePosition: 2),
              nowMs: now,
            );
          }),
          (14500, (p, now) {}),
        ],
      );
      // First speech at 2.5s is stage 0 (queued maps to stage 0).
      // Queue bank at 14.5s after gap.
      expect(spoken.any((u) => u.bank == NarrationBank.queuePositionTwo), isTrue);
      expect(
        spoken.where((u) => u.text.contains('position')).isEmpty,
        isTrue,
      );
    });

    test('heartbeat tier never decreases', () {
      final policy = _policy();
      policy.startTurn(turnId: 'hb', nowMs: 0);
      policy.onStatus(
        const NarrationStatusFrame(phase: 'generating'),
        nowMs: 100,
      );
      final u1 = policy.onTick(nowMs: 2500);
      expect(u1, isNotNull);
      final u2 = policy.onTick(nowMs: 2500 + 15000);
      expect(u2?.heartbeatTier, 1);
      final u3 = policy.onTick(nowMs: 2500 + 15000 + 15000);
      // elapsed ~32.5s → tier 2
      expect(u3?.heartbeatTier, greaterThanOrEqualTo(2));
      final u4 = policy.onTick(nowMs: 2500 + 15000 * 2 + 15000);
      // elapsed ~47.5s still tier 2
      expect(u4?.heartbeatTier, greaterThanOrEqualTo(2));
      final u5 = policy.onTick(nowMs: 70000);
      expect(u5?.heartbeatTier, 3);
      // Later tick still tier 3
      final u6 = policy.onTick(nowMs: 85000);
      expect(u6?.heartbeatTier, 3);
    });

    test('no line repeated within a turn across banks', () {
      final phrases = NarrationPhraseBank(
        banks: NarrationPhraseBank.embeddedDefaults(),
      );
      final policy = _policy(phrases: phrases);
      policy.startTurn(turnId: 'norepeat', nowMs: 0);
      final seen = <String>{};
      policy.onStatus(
        const NarrationStatusFrame(phase: 'starting'),
        nowMs: 100,
      );
      for (var t = 2500; t <= 90000; t += 15000) {
        if (t == 14500) {
          policy.onStatus(
            const NarrationStatusFrame(phase: 'planning'),
            nowMs: t,
          );
        }
        if (t == 29500) {
          policy.onStatus(
            const NarrationStatusFrame(phase: 'executing'),
            nowMs: t,
          );
        }
        final u = policy.onTick(nowMs: t);
        if (u != null) {
          expect(seen.contains(u.text), isFalse, reason: u.text);
          seen.add(u.text);
        }
      }
      expect(seen.length, greaterThan(2));
    });

    test('stage frame 200ms before done is discarded', () {
      final policy = _policy();
      policy.startTurn(turnId: 'discard', nowMs: 0);
      policy.onStatus(
        const NarrationStatusFrame(phase: 'generating'),
        nowMs: 100,
      );
      expect(policy.onTick(nowMs: 2500)?.stage, 2);
      // Heartbeat so lastSpoken is recent.
      expect(policy.onTick(nowMs: 17500), isNotNull);
      policy.onStatus(
        const NarrationStatusFrame(phase: 'preparing_response'),
        nowMs: 28000,
      );
      // Inside min_gap from 17500 — pending stage 3 held, not spoken.
      expect(policy.onTick(nowMs: 28100), isNull);
      final done = policy.onDone(nowMs: 28300);
      // Last speak at 17500 → 28300-17500 >= 3000 → preface plays.
      expect(done.preface, isNotNull);
    });

    test('unknown phase logs and produces no speech alone', () {
      final log = <String>[];
      final policy = _policy(unknownPhaseLog: log);
      policy.startTurn(turnId: 'unk', nowMs: 0);
      policy.onStatus(
        const NarrationStatusFrame(phase: 'brand_new_ao_phase'),
        nowMs: 100,
      );
      expect(log, contains('brand_new_ao_phase'));
      // Gate opens with no pending → stage 0 fallback.
      final u = policy.onTick(nowMs: 2500);
      expect(u?.stage, 0);
    });

    test('never speaks AO-supplied strings', () {
      final policy = _policy();
      policy.startTurn(turnId: 'safe', nowMs: 0);
      policy.onStatus(
        const NarrationStatusFrame(
          phase: 'generating',
          toolHint: 'sanitize prose raw_len=389 answer_len=389',
        ),
        nowMs: 100,
      );
      final u = policy.onTick(nowMs: 2500);
      expect(u, isNotNull);
      expect(u!.text.contains('sanitize'), isFalse);
      expect(u.text.contains('raw_len'), isFalse);
      expect(u.text.contains('qwen'), isFalse);
    });
  });

  group('NarrationPolicy property', () {
    test('random valid sequences keep invariants', () {
      final phrases = NarrationPhraseBank(
        banks: NarrationPhraseBank.embeddedDefaults(),
      );
      const settings = VoiceNarrationSettings();
      final phases = [
        'starting',
        'preparing',
        'planning',
        'planned',
        'executing',
        'generating',
        'warming_agent',
        'step',
        'tool',
        'preparing_response',
        'queued',
        'weird_unknown',
      ];
      for (var seed = 1; seed <= 40; seed++) {
        final policy = NarrationPolicy(phrases: phrases, settings: settings);
        policy.startTurn(turnId: 'prop-$seed', nowMs: 0);
        final spoken = <NarrationUtterance>[];
        var lastStage = -1;
        for (var t = 0; t <= 90000; t += 200) {
          if (t % 800 == 0) {
            final phase = phases[(seed + t) % phases.length];
            policy.onStatus(
              NarrationStatusFrame(
                phase: phase,
                queuePosition: phase == 'queued' ? ((seed % 4) + 1) : null,
                toolHint: seed.isEven ? 'fetch_url' : 'home_assistant',
              ),
              nowMs: t,
            );
          }
          final u = policy.onTick(nowMs: t);
          if (u != null) {
            if (spoken.isNotEmpty) {
              expect(
                u.atMs - spoken.last.atMs,
                greaterThanOrEqualTo(settings.minGapMs),
              );
            }
            expect(u.atMs, greaterThanOrEqualTo(settings.firstSpeechDelayMs));
            if (u.stage != null) {
              expect(u.stage!, greaterThanOrEqualTo(lastStage));
              lastStage = u.stage!;
            }
            // Closed bank only — no AO leak markers.
            expect(u.text.contains('sanitize'), isFalse);
            expect(u.text.contains('Consulting'), isFalse);
            expect(u.text.contains('raw_len'), isFalse);
            spoken.add(u);
          }
        }
      }
    });
  });

  group('mapPhaseToStage / categoryFor', () {
    test('maps known phases', () {
      expect(NarrationPolicy.mapPhaseToStage('starting'), 0);
      expect(NarrationPolicy.mapPhaseToStage('planning'), 1);
      expect(NarrationPolicy.mapPhaseToStage('generating'), 2);
      expect(NarrationPolicy.mapPhaseToStage('preparing_response'), 3);
      expect(NarrationPolicy.mapPhaseToStage('done'), isNull);
      expect(NarrationPolicy.mapPhaseToStage('nope'), isNull);
    });

    test('category from tool hints', () {
      expect(
        NarrationPolicy.categoryFor(toolHint: 'fetch_url'),
        NarrationCategory.web,
      );
      expect(
        NarrationPolicy.categoryFor(toolHint: 'home_assistant'),
        NarrationCategory.house,
      );
      expect(
        NarrationPolicy.categoryFor(toolHint: 'orchestrator_kb'),
        NarrationCategory.knowledge,
      );
      expect(
        NarrationPolicy.categoryFor(toolHint: 'client.greeter'),
        NarrationCategory.generic,
      );
    });
  });
}
