/// COMSTAR text channel daemon (Ada-side).
///
/// Env:
///   TELEGRAM_BOT_TOKEN          required
///   COMSTAR_CHANNEL_ALLOWLIST   JSON object or path to yaml/json
///   AO_BASE_URL / COMSTAR_AO_BASE_URL
///   AO_TOKEN / COMSTAR_AO_TOKEN
///   COMSTAR_OVERLAY_ROOT        default /opt/comstar/src/overlays/comstar
///   COMSTAR_CHANNEL_RATE_MAX    per-sender max (default 20)
///   COMSTAR_CHANNEL_DAILY_CAP   daily orchestration cap (default 200)
///   COMSTAR_CHANNEL_BIND        announce HTTP bind (default 127.0.0.1)
///   COMSTAR_CHANNEL_PORT        announce HTTP port (default 8782)
///   COMSTAR_CHANNEL_TOKEN       required when bind is non-loopback
///   COMSTAR_AO_MTLS=1          use Reach mTLS (Ada AO ≥ 1.29)
///   COMSTAR_AO_MTLS_DIR        PEM dir (default ~/.local/share/comstar/ao-mtls)
///
/// Unknown senders: ZERO outbound (allowlist silence).
///
/// Providers: Telegram today (ChannelMux). Additional Channel implementations
/// register beside Telegram without rewriting the turn loop.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'package:comstar_channel/announce_http.dart';
import 'package:comstar_channel/channel.dart';
import 'package:comstar_channel/identity.dart';
import 'package:comstar_channel/mux.dart';
import 'package:comstar_channel/rate_limit.dart';
import 'package:comstar_channel/session.dart';
import 'package:comstar_channel/telegram.dart';

void _log(String level, String evt, String msg, [Map<String, Object?>? data]) {
  stdout.writeln(jsonEncode({
    'ts': DateTime.now().millisecondsSinceEpoch,
    'level': level,
    'proc': 'channel',
    'evt': evt,
    'msg': msg,
    if (data != null) 'data': data,
  }));
}

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false)
    ..addOption('overlay-root', help: 'COMSTAR overlay root');
  final opts = parser.parse(args);
  if (opts['help'] == true) {
    stdout.writeln(parser.usage);
    exit(0);
  }

  final token = Platform.environment['TELEGRAM_BOT_TOKEN'] ?? '';
  if (token.isEmpty) {
    _log('error', 'config', 'TELEGRAM_BOT_TOKEN required');
    exit(2);
  }

  final allowlist = Allowlist.fromEnv();
  if (allowlist.length == 0) {
    _log('warn', 'config',
        'Allowlist empty — all senders will be silently ignored');
  } else {
    _log('info', 'config', 'Allowlist loaded', {'n': allowlist.length});
  }

  final repoGuess = Directory.current.path.endsWith('channel')
      ? Directory('..').absolute.path
      : Directory.current.absolute.path;
  final overlayRoot = (opts['overlay-root'] as String?) ??
      Platform.environment['COMSTAR_OVERLAY_ROOT'] ??
      p.normalize(p.join(repoGuess, 'overlays', 'comstar'));

  final aoToken = Platform.environment['AO_TOKEN'] ??
      Platform.environment['COMSTAR_AO_TOKEN'] ??
      '';
  final mtlsOn = aoMtlsEnabledFromEnv();
  final sessions = ChannelSessionManager(
    baseUrl: aoBaseUrlFromEnv(),
    overlayRoot: overlayRoot,
    token: aoToken,
    mtlsEnabled: mtlsOn,
    mtlsMaterialDir: aoMtlsDirFromEnv(),
  );
  if (mtlsOn) {
    _log('info', 'config', 'AO mTLS enabled for channel sessions', {
      'materialDir': sessions.resolvedMtlsDir,
      'ao': sessions.baseUrl,
    });
  }

  final perSenderMax =
      int.tryParse(Platform.environment['COMSTAR_CHANNEL_RATE_MAX'] ?? '') ??
          20;
  final dailyCap =
      int.tryParse(Platform.environment['COMSTAR_CHANNEL_DAILY_CAP'] ?? '') ??
          200;
  final limiter = RateLimiter(perSenderMax: perSenderMax, dailyCap: dailyCap);

  // M11.2: Telegram is the only provider today; mux is the integration point
  // for additional Channel implementations.
  final mux = ChannelMux([
    TelegramChannel(botToken: token),
  ]);
  late final StreamSubscription<ChannelInbound> sub;

  final announceBind =
      Platform.environment['COMSTAR_CHANNEL_BIND'] ?? '127.0.0.1';
  final announcePort =
      int.tryParse(Platform.environment['COMSTAR_CHANNEL_PORT'] ?? '') ?? 8782;
  final channelHttpToken = Platform.environment['COMSTAR_CHANNEL_TOKEN'] ?? '';
  final announceHttp = AnnounceHttpServer(
    channel: mux,
    allowlist: allowlist,
    token: channelHttpToken,
    bindHost: announceBind,
    port: announcePort,
    log: _log,
  );

  Future<void> shutdown() async {
    _log('info', 'shutdown', 'stopping channel');
    await sub.cancel();
    await announceHttp.stop();
    await mux.stop();
    await sessions.stopAll();
    exit(0);
  }

  ProcessSignal.sigterm.watch().listen((_) => shutdown());
  ProcessSignal.sigint.watch().listen((_) => shutdown());

  sub = mux.inbound.listen((msg) async {
    final userid = allowlist.useridFor(msg.senderId);
    if (userid == null) {
      // Security boundary: silence. Do not send(), do not reveal the bot lives.
      _log('info', 'allowlist_deny', 'unknown sender silenced', {
        'senderId': msg.senderId,
      });
      return;
    }
    if (!limiter.allow(msg.senderId)) {
      _log('warn', 'rate_limit', 'sender or daily cap hit', {
        'senderId': msg.senderId,
        'userid': userid,
      });
      try {
        await mux.send(
          msg.senderId,
          'Too many messages — try again later.',
        );
      } catch (_) {}
      return;
    }

    _log('info', 'inbound', 'message', {
      'userid': userid,
      'chars': msg.text.length,
    });
    try {
      await mux.setTyping(msg.senderId, ChannelTyping.started);
      final reply = await sessions.turn(userid, msg.text);
      await mux.send(msg.senderId, reply);
      _log('info', 'outbound', 'replied', {
        'userid': userid,
        'chars': reply.length,
      });
    } catch (e) {
      _log('error', 'turn_fail', '$e', {'userid': userid});
      try {
        await mux.send(msg.senderId, 'Sorry — something went wrong.');
      } catch (_) {}
    }
  });

  await mux.start();
  try {
    await announceHttp.start();
  } catch (e) {
    _log('error', 'announce_http_fail', '$e');
    exit(2);
  }
  _log('info', 'ready', 'comstar-channel polling providers', {
    'overlayRoot': overlayRoot,
    'ao': aoBaseUrlFromEnv(),
    'mtls': mtlsOn,
    'providers': ['telegram'],
    'announceHttp': '$announceBind:$announcePort',
  });

  Timer.periodic(const Duration(minutes: 15), (_) async {
    try {
      await sessions.reapIdle();
    } catch (e) {
      _log('warn', 'reap', '$e');
    }
  });

  await Completer<void>().future;
}
