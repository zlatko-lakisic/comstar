import 'dart:convert';
import 'dart:io';

import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/curated_rag.dart';
import 'package:comstar_bridge/durable_memory.dart';
import 'package:comstar_bridge/working_ack.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// One spoken turn in the rolling conversation window.
class ConversationTurn {
  const ConversationTurn({
    required this.role,
    required this.text,
    required this.tsMs,
    this.terminal,
  });

  /// `user` or `assistant`.
  final String role;
  final String text;
  final int tsMs;
  final String? terminal;

  Map<String, dynamic> toJson() => {
        'role': role,
        'text': text,
        'ts': tsMs,
        if (terminal != null && terminal!.isNotEmpty) 'terminal': terminal,
      };

  static ConversationTurn? fromJson(Map<String, dynamic> map) {
    final role = map['role']?.toString() ?? '';
    final text = map['text']?.toString() ?? '';
    if (role != 'user' && role != 'assistant') return null;
    if (text.trim().isEmpty) return null;
    final ts = (map['ts'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch;
    return ConversationTurn(
      role: role,
      text: text.trim(),
      tsMs: ts,
      terminal: map['terminal']?.toString(),
    );
  }
}

class ConversationHistory {
  const ConversationHistory({required this.userid, required this.turns});

  final String userid;
  final List<ConversationTurn> turns;

  Map<String, dynamic> toJson() => {
        'userid': userid,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'turns': turns.map((t) => t.toJson()).toList(),
      };

  static ConversationHistory fromJson(Map<String, dynamic> map, String userid) {
    final raw = map['turns'];
    final turns = <ConversationTurn>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          final t = ConversationTurn.fromJson(Map<String, dynamic>.from(item));
          if (t != null) turns.add(t);
        }
      }
    }
    return ConversationHistory(userid: userid, turns: turns);
  }
}

/// Persistence backend for per-userid rolling transcripts + durable facts.
abstract class ConversationMemoryStore {
  Future<ConversationHistory> load(String userid);
  Future<void> save(ConversationHistory history);

  /// Search durable facts (empty [query] → most recent).
  Future<List<DurableFact>> searchFacts(
    String userid, {
    String query = '',
    int limit = 8,
  });

  Future<void> upsertFacts(String userid, List<DurableFact> facts);
}

/// JSON files under [root] — use a shared NFS path for multi-terminal without HTTP.
class FileConversationMemoryStore implements ConversationMemoryStore {
  FileConversationMemoryStore({Directory? root}) : _root = root;

  final Directory? _root;

  Directory get root {
    if (_root != null) return _root!;
    final override = Platform.environment['COMSTAR_MEMORY_DIR']?.trim();
    if (override != null && override.isNotEmpty) {
      return Directory(override);
    }
    final data = Platform.environment['COMSTAR_DATA_DIR']?.trim();
    final base = (data != null && data.isNotEmpty)
        ? data
        : p.join(
            Platform.environment['HOME'] ?? Directory.systemTemp.path,
            '.local',
            'share',
            'comstar',
          );
    return Directory(p.join(base, 'conversation'));
  }

  static String safeUserid(String userid) {
    final cleaned = userid.trim().toLowerCase().replaceAll(
          RegExp(r'[^a-z0-9_-]'),
          '_',
        );
    if (cleaned.isEmpty || cleaned == 'guest' || cleaned == 'unknown') {
      throw ArgumentError('invalid memory userid: $userid');
    }
    return cleaned;
  }

  File _fileFor(String userid) =>
      File(p.join(root.path, '${safeUserid(userid)}.json'));

  File _factsFileFor(String userid) =>
      File(p.join(root.path, '${safeUserid(userid)}.facts.json'));

  @override
  Future<ConversationHistory> load(String userid) async {
    final file = _fileFor(userid);
    if (!file.existsSync()) {
      return ConversationHistory(userid: userid, turns: const []);
    }
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) {
        return ConversationHistory(userid: userid, turns: const []);
      }
      return ConversationHistory.fromJson(
        Map<String, dynamic>.from(raw),
        userid,
      );
    } catch (_) {
      return ConversationHistory(userid: userid, turns: const []);
    }
  }

  @override
  Future<void> save(ConversationHistory history) async {
    root.createSync(recursive: true);
    final file = _fileFor(history.userid);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(history.toJson())}\n',
    );
    await tmp.rename(file.path);
    try {
      await Process.run('chmod', ['600', file.path]);
    } catch (_) {}
  }

  @override
  Future<List<DurableFact>> searchFacts(
    String userid, {
    String query = '',
    int limit = 8,
  }) async {
    final file = _factsFileFor(userid);
    if (!file.existsSync()) return const [];
    try {
      final raw = jsonDecode(await file.readAsString());
      var facts = parseFactsPayload(raw);
      final q = query.trim().toLowerCase();
      if (q.isNotEmpty) {
        facts = [
          for (final f in facts)
            if (f.text.toLowerCase().contains(q) ||
                f.kind.toLowerCase().contains(q))
              f,
        ];
      }
      if (facts.length > limit) {
        facts = facts.sublist(0, limit);
      }
      return facts;
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> upsertFacts(String userid, List<DurableFact> facts) async {
    if (facts.isEmpty) return;
    root.createSync(recursive: true);
    final file = _factsFileFor(userid);
    final existing = await searchFacts(userid, limit: 200);
    final byId = {for (final f in existing) f.id: f};
    for (final f in facts) {
      byId[f.id] = f;
    }
    final merged = byId.values.toList()
      ..sort((a, b) => (b.updatedMs ?? 0).compareTo(a.updatedMs ?? 0));
    final capped = merged.length > 100 ? merged.sublist(0, 100) : merged;
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(encodeFactsFile(capped));
    await tmp.rename(file.path);
  }
}

/// Shared HTTP store (multi-terminal). See `scripts/comstar_memory_server.py`.
class HttpConversationMemoryStore implements ConversationMemoryStore {
  HttpConversationMemoryStore({
    required this.baseUrl,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  Uri _uri(String userid) {
    final id = FileConversationMemoryStore.safeUserid(userid);
    final root = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$root/v1/memory/$id');
  }

  Uri _factsUri(String userid, {String query = '', int limit = 8}) {
    final id = FileConversationMemoryStore.safeUserid(userid);
    final root = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$root/v1/facts/$id').replace(
      queryParameters: {
        if (query.trim().isNotEmpty) 'q': query.trim(),
        'limit': '$limit',
      },
    );
  }

  @override
  Future<ConversationHistory> load(String userid) async {
    try {
      final res = await _client
          .get(_uri(userid))
          .timeout(const Duration(seconds: 3));
      if (res.statusCode == 404) {
        return ConversationHistory(userid: userid, turns: const []);
      }
      if (res.statusCode != 200) {
        return ConversationHistory(userid: userid, turns: const []);
      }
      final raw = jsonDecode(res.body);
      if (raw is! Map) {
        return ConversationHistory(userid: userid, turns: const []);
      }
      return ConversationHistory.fromJson(
        Map<String, dynamic>.from(raw),
        userid,
      );
    } catch (_) {
      return ConversationHistory(userid: userid, turns: const []);
    }
  }

  @override
  Future<void> save(ConversationHistory history) async {
    try {
      await _client
          .put(
            _uri(history.userid),
            headers: {'content-type': 'application/json'},
            body: jsonEncode(history.toJson()),
          )
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      // Soft-fail — voice still works without persistence.
    }
  }

  @override
  Future<List<DurableFact>> searchFacts(
    String userid, {
    String query = '',
    int limit = 8,
  }) async {
    try {
      final res = await _client
          .get(_factsUri(userid, query: query, limit: limit))
          .timeout(const Duration(seconds: 3));
      if (res.statusCode != 200) return const [];
      final raw = jsonDecode(res.body);
      return parseFactsPayload(raw);
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> upsertFacts(String userid, List<DurableFact> facts) async {
    if (facts.isEmpty) return;
    final id = FileConversationMemoryStore.safeUserid(userid);
    final root = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final uri = Uri.parse('$root/v1/facts/$id');
    for (final fact in facts) {
      try {
        await _client
            .post(
              uri,
              headers: {'content-type': 'application/json'},
              body: jsonEncode(fact.toJson()),
            )
            .timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
  }
}

/// Rolling + durable per-userid chat memory for COMSTAR voice turns.
class ConversationMemory {
  ConversationMemory({
    required this.store,
    this.maxTurns = 20,
    this.promptMaxTurns = 0,
    this.maxInjectChars = 3500,
    this.maxTurnChars = 500,
    this.maxFactsInject = 8,
    this.maxFactsChars = 1200,
    this.durableEnabled = true,
    this.terminalId,
    this.enabled = true,
    this.curatedRagEnabled = false,
    this.curatedRagId = 'comstar_resident_facts',
    this.curatedRagPackDir = '',
    this.storeDir = '',
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  factory ConversationMemory.fromConfig(ComstarConfig config) {
    final envUrl = Platform.environment['COMSTAR_MEMORY_URL']?.trim() ?? '';
    final url = envUrl.isNotEmpty ? envUrl : config.memory.url.trim();
    final ConversationMemoryStore store;
    if (url.isNotEmpty) {
      store = HttpConversationMemoryStore(baseUrl: url);
    } else if (config.memory.storeDir.trim().isNotEmpty) {
      store = FileConversationMemoryStore(
        root: Directory(config.memory.storeDir.trim()),
      );
    } else {
      store = FileConversationMemoryStore();
    }
    final envTerminal =
        Platform.environment['COMSTAR_TERMINAL_ID']?.trim() ?? '';
    final terminal =
        envTerminal.isNotEmpty ? envTerminal : Platform.localHostname;
    return ConversationMemory(
      store: store,
      maxTurns: config.memory.maxTurns,
      promptMaxTurns: config.memory.promptMaxTurns,
      maxInjectChars: config.memory.maxInjectChars,
      maxFactsInject: config.memory.maxFactsInject,
      maxFactsChars: config.memory.maxFactsChars,
      durableEnabled: config.memory.durable,
      terminalId: terminal,
      enabled: config.memory.enabled,
      curatedRagEnabled: config.memory.curatedRagEnabled,
      curatedRagId: config.memory.curatedRagId,
      curatedRagPackDir: config.memory.curatedRagPackDir,
      storeDir: config.memory.storeDir,
    );
  }

  final ConversationMemoryStore store;
  final int maxTurns;

  /// Max recent **pairs** injected into AO prompts.
  /// Default 0 — rely on `client.comstar_memory` (`recent_turns` / recall).
  final int promptMaxTurns;
  final int maxInjectChars;
  final int maxTurnChars;
  final int maxFactsInject;
  final int maxFactsChars;
  final bool durableEnabled;
  final String? terminalId;
  final bool enabled;
  final bool curatedRagEnabled;
  final String curatedRagId;
  final String curatedRagPackDir;
  final String storeDir;
  final DateTime Function() _now;

  static bool isMemoryUser(String? userid) {
    if (userid == null) return false;
    final u = userid.trim().toLowerCase();
    return u.isNotEmpty && u != 'guest' && u != 'unknown';
  }

  /// Thin AO prompt: last [promptMaxTurns] pairs only — no durable-facts block.
  Future<String> wrapForAgent(String userid, String text) async {
    final trimmed = text.trim();
    if (!enabled || !isMemoryUser(userid) || trimmed.isEmpty) return trimmed;

    final wantNews = looksLikeNewsResearch(trimmed);
    final parts = <String>[];

    if (!wantNews && curatedRagEnabled) {
      final pack = loadCuratedRagPack(
        MemoryConfig(
          curatedRagEnabled: true,
          curatedRagId: curatedRagId,
          curatedRagPackDir: curatedRagPackDir,
          storeDir: storeDir,
        ),
      );
      if (pack != null && pack.isUsable) {
        parts.add(curatedRagSteer(pack));
      }
    }

    if (promptMaxTurns <= 0) {
      if (parts.isEmpty) return trimmed;
      return '${parts.join('\n\n')}\n\nCurrent request:\n$trimmed';
    }

    final history = await store.load(userid);
    if (history.turns.isNotEmpty) {
      final recent = recentPromptTurns(
        history.turns,
        maxPairs: promptMaxTurns,
        suppressNewsAnswers: !wantNews,
      );
      if (recent.isNotEmpty) {
        final block = formatHistoryBlock(
          recent,
          maxChars: maxInjectChars,
          suppressNewsAnswers: false,
          filterNoise: false,
        );
        if (block.isNotEmpty) {
          parts.add(
            'Prior conversation (same resident; most recent only — use memory '
            'tools for older prefs/facts). Use for short follow-ups; do not recite '
            'unless asked.\n'
            'Ignore prior plan summaries, progress lines, and unfinished goals — '
            'answer ONLY the Current request below.\n'
            'Do not recite prior world news or headlines unless the Current '
            'request explicitly asks for news, world events, or headlines.\n'
            '$block',
          );
        }
      }
    }

    if (parts.isEmpty) return trimmed;
    return '${parts.join('\n\n')}\n\n'
        'Current request:\n'
        '(Authoritative — ignore conflicting prior goals or plan summaries.)\n'
        '$trimmed';
  }

  /// Last [maxPairs] user+assistant pairs that are prompt-worthy (newest last).
  static List<ConversationTurn> recentPromptTurns(
    List<ConversationTurn> turns, {
    required int maxPairs,
    bool suppressNewsAnswers = false,
  }) {
    if (maxPairs <= 0 || turns.isEmpty) return const [];
    final filtered = <ConversationTurn>[];
    for (final t in turns) {
      if (!isPromptWorthy(t, suppressNewsAnswers: suppressNewsAnswers)) {
        continue;
      }
      filtered.add(t);
    }
    if (filtered.isEmpty) return const [];
    final maxLines = maxPairs * 2;
    if (filtered.length <= maxLines) return filtered;
    return filtered.sublist(filtered.length - maxLines);
  }

  /// Greeter / sleep / working-ack / status / empty HA apology / news dump /
  /// bloated fabricated "house is fine" replies.
  static bool isPromptWorthy(
    ConversationTurn t, {
    bool suppressNewsAnswers = false,
  }) {
    final text = t.text.trim();
    if (text.isEmpty) return false;
    if (t.role == 'assistant') {
      if (isTimeoutApology(text)) return false;
      if (isNoiseAssistant(text)) return false;
      if (isBloatedHouseStatusDump(text)) return false;
      if (suppressNewsAnswers && isNewsHeadlineDump(text)) return false;
    }
    if (t.role == 'user' && isNoiseUser(text)) return false;
    return true;
  }

  static bool isNoiseAssistant(String text) {
    final t = text.toLowerCase().trim();
    if (t.isEmpty) return true;
    if (isWorkingAckPhrase(t)) return true;
    if (_assistantNoise.hasMatch(t)) return true;
    if (t.contains('awaiting your voice')) return true;
    if (t.contains('stand by for voice')) return true;
    // Empty HA / reach apologies with no house content.
    if ((t.contains('sorry') || t.contains('could not')) &&
        (t.contains("couldn't reach") ||
            t.contains('could not reach') ||
            t.contains('no entities') ||
            t.contains('nothing to report') ||
            (t.length < 80 &&
                (t.startsWith('sorry') || t.contains('i apologize'))))) {
      return true;
    }
    return false;
  }

  /// Long AO boilerplate that invents a rosy house report and often offers news.
  static bool isBloatedHouseStatusDump(String text) {
    final t = text.toLowerCase().trim();
    if (t.length < 200) return false;
    final houseBoiler = t.contains('running smoothly') ||
        (t.contains('security systems') && t.contains('climate')) ||
        (t.contains('irrigation') && t.contains('no alarms')) ||
        t.contains('everything around your house');
    final newsBleed = t.contains('global news') ||
        t.contains('if you were asking about') ||
        t.contains("here's a quick update") ||
        t.contains('heres a quick update') ||
        t.contains('insert recent global');
    return houseBoiler || (newsBleed && t.length > 280);
  }

  static bool isNoiseUser(String text) {
    final t = text.toLowerCase().trim();
    return _userNoise.hasMatch(t);
  }

  static final _assistantNoise = RegExp(
    r'^(good (morning|afternoon|evening)|welcome back|hello[,!. ]|'
    r'going to sleep|entering sleep|sleep mode|'
    r'status:|system status|i.?m (here|listening)|ready when you are)',
    caseSensitive: false,
  );

  static final _userNoise = RegExp(
    r'^(go to sleep|sleep|wake up|wake|status|what.?s your status|'
    r'system status)\.?$',
    caseSensitive: false,
  );

  /// Short progress / working-ack one-liners (not useful as AO context).
  static bool isWorkingAckPhrase(String lower) {
    return RegExp(
      r'^(one (moment|sec|second)|working on (it|that)|looking (that|it) up|'
      r'hang on|just a (sec|second|moment)|on it\.?$|got it\.?$|'
      r'still working|almost there)',
      caseSensitive: false,
    ).hasMatch(lower);
  }

  /// Append a user + assistant exchange, persist turns, upsert durable facts.
  Future<void> recordExchange({
    required String userid,
    required String userText,
    required String assistantText,
  }) async {
    if (!enabled || !isMemoryUser(userid)) return;
    final user = _clip(userText);
    final assistant = _clip(assistantText);
    if (user.isEmpty && assistant.isEmpty) return;

    final history = await store.load(userid);
    final ts = _now().millisecondsSinceEpoch;
    final next = List<ConversationTurn>.from(history.turns);
    if (user.isNotEmpty) {
      next.add(ConversationTurn(
        role: 'user',
        text: user,
        tsMs: ts,
        terminal: terminalId,
      ));
    }
    if (assistant.isNotEmpty) {
      next.add(ConversationTurn(
        role: 'assistant',
        text: assistant,
        tsMs: ts + 1,
        terminal: terminalId,
      ));
    }
    final trimmed = trimTurns(next, maxTurns: maxTurns);
    await store.save(ConversationHistory(userid: userid, turns: trimmed));

    if (durableEnabled && user.isNotEmpty) {
      final facts = extractDurableFacts(
        user,
        source: terminalId == null ? 'voice' : 'voice:$terminalId',
      );
      if (facts.isNotEmpty) {
        await store.upsertFacts(userid, facts);
      }
    }
  }

  String _clip(String text) {
    final t = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (t.length <= maxTurnChars) return t;
    return '${t.substring(0, maxTurnChars - 1)}…';
  }

  /// Keep the newest [maxTurns] turns (each role counts as one).
  static List<ConversationTurn> trimTurns(
    List<ConversationTurn> turns, {
    required int maxTurns,
  }) {
    if (maxTurns <= 0) return const [];
    if (turns.length <= maxTurns) return List<ConversationTurn>.from(turns);
    return turns.sublist(turns.length - maxTurns);
  }

  /// Render history for the model; drop oldest lines if over [maxChars].
  ///
  /// Strips timeout apologies, optional news dumps, and (when [filterNoise])
  /// greeter / sleep / working-ack spam. Each line is hard-clipped for the
  /// thin prompt window.
  static String formatHistoryBlock(
    List<ConversationTurn> turns, {
    required int maxChars,
    bool suppressNewsAnswers = false,
    bool filterNoise = true,
    int maxLineChars = 160,
  }) {
    if (turns.isEmpty || maxChars <= 0) return '';
    final lines = <String>[];
    for (final t in turns) {
      if (filterNoise) {
        if (!isPromptWorthy(t, suppressNewsAnswers: suppressNewsAnswers)) {
          continue;
        }
      } else {
        if (t.role == 'assistant' && isTimeoutApology(t.text)) continue;
        if (t.role == 'assistant' && isBloatedHouseStatusDump(t.text)) continue;
        if (suppressNewsAnswers &&
            t.role == 'assistant' &&
            isNewsHeadlineDump(t.text)) {
          continue;
        }
      }
      final who = t.role == 'user' ? 'Resident' : 'COMSTAR';
      final where =
          (t.terminal != null && t.terminal!.trim().isNotEmpty)
              ? ' [${t.terminal}]'
              : '';
      final body = _clipInject(t.text, maxLineChars);
      lines.add('$who$where: $body');
    }
    if (lines.isEmpty) return '';
    var joined = lines.join('\n');
    while (joined.length > maxChars && lines.isNotEmpty) {
      lines.removeAt(0);
      joined = lines.join('\n');
    }
    return joined;
  }

  static String _clipInject(String text, int maxChars) {
    final t = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (maxChars <= 0 || t.length <= maxChars) return t;
    return '${t.substring(0, maxChars - 1)}…';
  }

  /// Prior hallway timeout / empty-reply lines that poison research prompts.
  static bool isTimeoutApology(String text) {
    final t = text.toLowerCase().trim();
    if (t.isEmpty) return false;
    return t.contains('could not get an answer in time') ||
        t.contains("don't have a reply right now") ||
        t.contains('dont have a reply right now') ||
        t.contains('i do not have a reply right now');
  }

  /// Assistant turns that are mostly world-news dumps (memory poison).
  static bool isNewsHeadlineDump(String text) {
    final t = text.toLowerCase().trim();
    if (t.isEmpty) return false;
    if (t.contains('headlines from around the world') ||
        t.contains('headlines from around the') ||
        t.contains("here's what's happening") ||
        t.contains('heres whats happening') ||
        t.contains('here is what is happening')) {
      return true;
    }
    final hasNewsCue = t.contains('headline') ||
        t.contains(' around the world') ||
        (t.contains('news') &&
            (t.contains('bbc') ||
                t.contains('npr') ||
                t.contains('reuters') ||
                RegExp(r'\b\d+\.\s').hasMatch(t)));
    return hasNewsCue && t.length > 200;
  }
}
