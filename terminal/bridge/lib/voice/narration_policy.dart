/// Pure spoken-progress narration policy for AO turns.
///
/// No I/O / TTS. Takes status events + clock ticks; returns phrase-bank lines.
library;

import 'package:comstar_bridge/voice/phrase_bank.dart';

/// Tunables for [NarrationPolicy]. Defaults match the handoff / config block.
class VoiceNarrationSettings {
  const VoiceNarrationSettings({
    this.enabled = true,
    this.firstSpeechDelayMs = 2500,
    this.minGapMs = 12000,
    this.heartbeatIntervalMs = 15000,
    this.heartbeatTier2AfterMs = 30000,
    this.heartbeatTier3AfterMs = 60000,
    this.suppressPrefaceWithinMs = 3000,
    this.queueMinPosition = 2,
    this.speakStage3 = true,
    this.recentRingSize = 3,
  });

  final bool enabled;
  final int firstSpeechDelayMs;
  final int minGapMs;
  final int heartbeatIntervalMs;
  final int heartbeatTier2AfterMs;
  final int heartbeatTier3AfterMs;
  final int suppressPrefaceWithinMs;
  final int queueMinPosition;
  final bool speakStage3;
  final int recentRingSize;
}

/// Status snapshot fed into the policy (never spoken verbatim).
class NarrationStatusFrame {
  const NarrationStatusFrame({
    required this.phase,
    this.queuePosition,
    this.toolHint,
    this.categoryHint,
    this.heartbeat = false,
  });

  final String phase;
  final int? queuePosition;

  /// Tool / MCP id hint for category selection (never spoken).
  final String? toolHint;

  /// Optional turn-level category override (e.g. news → web).
  final String? categoryHint;

  final bool heartbeat;
}

/// One phrase-bank utterance the coordinator should TTS.
class NarrationUtterance {
  const NarrationUtterance({
    required this.text,
    required this.bank,
    required this.atMs,
    this.stage,
    this.heartbeatTier,
  });

  final String text;
  final String bank;
  final int atMs;
  final int? stage;
  final int? heartbeatTier;
}

/// Result of [NarrationPolicy.onDone].
class NarrationDoneResult {
  const NarrationDoneResult({this.preface});

  /// Optional result-preface line when progress was spoken earlier.
  final String? preface;
}

typedef NarrationLogFn = void Function(String message, {Map<String, Object?>? data});

/// Collapses AO phases into four spoken stages with time gates.
class NarrationPolicy {
  NarrationPolicy({
    required this.phrases,
    this.settings = const VoiceNarrationSettings(),
    this.onInfoLog,
  });

  final NarrationPhraseBank phrases;
  final VoiceNarrationSettings settings;
  final NarrationLogFn? onInfoLog;

  int _turnStartAt = 0;
  String _turnId = '';
  var _spokenStage = -1;
  int? _pendingStage;
  String? _pendingCategory;
  int? _lastSpokenAt;
  var _heartbeatTier = 0;
  int? _queuePending;
  var _active = false;

  /// True when any progress / queue / heartbeat line was spoken this turn.
  bool get didSpeak => _lastSpokenAt != null;

  bool get isActive => _active;

  void startTurn({required String turnId, required int nowMs}) {
    _active = true;
    _turnId = turnId;
    _turnStartAt = nowMs;
    _spokenStage = -1;
    _pendingStage = null;
    _pendingCategory = null;
    _lastSpokenAt = null;
    _heartbeatTier = 0;
    _queuePending = null;
    phrases.beginTurn(turnId);
  }

  void cancelTurn() {
    _active = false;
    _pendingStage = null;
    _pendingCategory = null;
    _queuePending = null;
    phrases.endTurn();
  }

  /// Ingest a Reach status frame. Never speaks directly.
  void onStatus(NarrationStatusFrame frame, {required int nowMs}) {
    if (!_active) return;
    final phase = frame.phase.trim().toLowerCase();
    if (phase == 'done' || phase == 'error') return;

    if (phase == 'queued') {
      final pos = frame.queuePosition;
      if (pos != null && pos >= settings.queueMinPosition) {
        _queuePending = pos;
      }
    }

    final mapped = mapPhaseToStage(phase);
    if (mapped == null) {
      onInfoLog?.call(
        'Unknown AO narration phase; keeping last stage',
        data: {'phase': frame.phase, 'turn_id': _turnId},
      );
      // Unknown phase keeps last known stage — no speech on its own.
      return;
    }

    final category = categoryFor(
      toolHint: frame.toolHint,
      categoryHint: frame.categoryHint,
    );

    if (mapped > _spokenStage && mapped > (_pendingStage ?? -1)) {
      if (mapped == 3 && !settings.speakStage3) {
        // Hold composing only when stage3 speech is enabled.
      } else {
        _pendingStage = mapped;
        _pendingCategory =
            mapped == 2 ? category : NarrationCategory.generic;
      }
    } else if (mapped == 2 &&
        mapped == _pendingStage &&
        _pendingCategory == NarrationCategory.generic &&
        category != NarrationCategory.generic) {
      // Upgrade generic → specific category while still pending.
      _pendingCategory = category;
    }
  }

  /// 200ms (or any) tick. Returns at most one utterance.
  NarrationUtterance? onTick({required int nowMs}) {
    if (!_active) return null;
    final elapsed = nowMs - _turnStartAt;
    if (elapsed < settings.firstSpeechDelayMs) return null;
    if (_lastSpokenAt != null &&
        (nowMs - _lastSpokenAt!) < settings.minGapMs) {
      return null;
    }

    // Gate open with no status yet → stage 0 (replaces working ack).
    if (_lastSpokenAt == null && _pendingStage == null) {
      _pendingStage = 0;
      _pendingCategory = NarrationCategory.generic;
    }

    if (_queuePending != null) {
      final pos = _queuePending!;
      _queuePending = null;
      final bank = pos <= 2
          ? NarrationBank.queuePositionTwo
          : NarrationBank.queuePositionMany;
      // Position N means N-1 ahead when 1-based? Handoff: position 2 → "one ahead".
      // Position 3+ → counted form with {n} = position - 1 ahead.
      final ahead = pos <= 2 ? 1 : pos - 1;
      final text = phrases.pick(bank, queueAhead: ahead);
      return _emit(
        text: text,
        bank: bank,
        atMs: nowMs,
      );
    }

    if (_pendingStage != null) {
      final stage = _pendingStage!;
      final category = _pendingCategory ?? NarrationCategory.generic;
      _pendingStage = null;
      _pendingCategory = null;
      final bank = NarrationBank.stageBank(stage, category: category);
      final text = phrases.pick(bank);
      _spokenStage = stage;
      return _emit(
        text: text,
        bank: bank,
        atMs: nowMs,
        stage: stage,
      );
    }

    if (_lastSpokenAt != null &&
        (nowMs - _lastSpokenAt!) >= settings.heartbeatIntervalMs) {
      final tier = _tierForElapsed(elapsed);
      final nextTier =
          tier > _heartbeatTier ? tier : _heartbeatTier;
      _heartbeatTier = nextTier == 0 ? 1 : nextTier;
      final bank = NarrationBank.heartbeatBank(_heartbeatTier);
      final text = phrases.pick(bank);
      return _emit(
        text: text,
        bank: bank,
        atMs: nowMs,
        heartbeatTier: _heartbeatTier,
      );
    }

    return null;
  }

  /// Terminal success: discard pending progress; maybe speak a preface.
  NarrationDoneResult onDone({required int nowMs}) {
    _pendingStage = null;
    _pendingCategory = null;
    _queuePending = null;
    String? preface;
    if (_lastSpokenAt != null &&
        (nowMs - _lastSpokenAt!) >= settings.suppressPrefaceWithinMs) {
      preface = phrases.pick(NarrationBank.resultPreface);
      // Preface counts as spoken for used-lines, but does not update stage.
      _lastSpokenAt = nowMs;
    }
    _active = false;
    phrases.endTurn();
    return NarrationDoneResult(preface: preface);
  }

  /// Terminal failure: discard pending; failure speech is handled elsewhere.
  void onError({required int nowMs}) {
    _pendingStage = null;
    _pendingCategory = null;
    _queuePending = null;
    _active = false;
    phrases.endTurn();
  }

  NarrationUtterance _emit({
    required String text,
    required String bank,
    required int atMs,
    int? stage,
    int? heartbeatTier,
  }) {
    _lastSpokenAt = atMs;
    return NarrationUtterance(
      text: text,
      bank: bank,
      atMs: atMs,
      stage: stage,
      heartbeatTier: heartbeatTier,
    );
  }

  int _tierForElapsed(int elapsedMs) {
    if (elapsedMs >= settings.heartbeatTier3AfterMs) return 3;
    if (elapsedMs >= settings.heartbeatTier2AfterMs) return 2;
    return 1;
  }

  /// Map AO phase → stage 0–3, or null when unknown.
  static int? mapPhaseToStage(String phase) {
    switch (phase.trim().toLowerCase()) {
      case 'starting':
      case 'preparing':
      case 'queued':
      case 'queue_admitted':
      case 'busy':
        return 0;
      case 'planning':
      case 'planned':
        return 1;
      case 'executing':
      case 'warming_agent':
      case 'starting_agent':
      case 'generating':
      case 'step':
      case 'tool':
      case 'info':
      case 'working':
        return 2;
      case 'preparing_response':
        return 3;
      case 'done':
      case 'error':
      case 'preempted':
        return null;
      default:
        return null;
    }
  }

  /// Pick stage-2 category from tool / turn hints (never from prose for speech).
  static String categoryFor({
    String? toolHint,
    String? categoryHint,
  }) {
    if (categoryHint != null && categoryHint.trim().isNotEmpty) {
      final c = categoryHint.trim().toLowerCase();
      if (c == NarrationCategory.web ||
          c == NarrationCategory.knowledge ||
          c == NarrationCategory.house ||
          c == NarrationCategory.generic) {
        return c;
      }
    }
    final blob = (toolHint ?? '').toLowerCase();
    if (blob.isEmpty) return NarrationCategory.generic;

    if (_webTool.hasMatch(blob)) return NarrationCategory.web;
    if (_knowledgeTool.hasMatch(blob)) return NarrationCategory.knowledge;
    if (_houseTool.hasMatch(blob)) return NarrationCategory.house;
    return NarrationCategory.generic;
  }

  static final _webTool = RegExp(
    r'fetch_url|news_research|web_?search|browser|http_fetch|search_web',
    caseSensitive: false,
  );
  static final _knowledgeTool = RegExp(
    r'\brag\b|knowledge|memory|orchestrator_kb|vector|embed',
    caseSensitive: false,
  );
  static final _houseTool = RegExp(
    r'home_assistant|hass_|ha_|weather_mcp|vision_comstar',
    caseSensitive: false,
  );

  /// Extract a tool-ish hint from Reach status fields without using it as speech.
  static String? toolHintFromStatus({
    String? agentProviderId,
    String? message,
    String? detail,
    Map<String, dynamic>? raw,
  }) {
    final parts = <String>[];
    void add(String? s) {
      final t = s?.trim();
      if (t != null && t.isNotEmpty) parts.add(t);
    }

    add(agentProviderId);
    if (raw != null) {
      add(raw['tool']?.toString());
      add(raw['tool_name']?.toString());
      add(raw['toolName']?.toString());
      add(raw['mcp']?.toString());
      add(raw['mcp_provider']?.toString());
      final providers = raw['mcp_providers'] ?? raw['mcpProviders'];
      if (providers is List) {
        for (final p in providers) {
          add(p.toString());
        }
      }
    }
    // Message / detail only for category regex — never spoken.
    add(message);
    add(detail);
    if (parts.isEmpty) return null;
    return parts.join(' ');
  }
}
