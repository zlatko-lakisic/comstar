/// COMSTAR text channel daemon (Ada-side).
///
/// Env (at least one provider):
///   TELEGRAM_BOT_TOKEN / TELEGRAM_BOT_USERNAME
///   COMSTAR_WHATSAPP_CLOUD_TOKEN / COMSTAR_WHATSAPP_PHONE_NUMBER_ID
///     (+ COMSTAR_WHATSAPP_VERIFY_TOKEN, COMSTAR_WHATSAPP_DISPLAY_PHONE)
///   COMSTAR_SIGNAL_URL / COMSTAR_SIGNAL_ACCOUNT  (signal-cli HTTP daemon)
///
/// Shared:
///   COMSTAR_CHANNEL_ALLOWLIST, AO_*, COMSTAR_CHANNEL_BIND/PORT/TOKEN,
///   COMSTAR_AO_MTLS*, COMSTAR_DATA_DIR, rate limits
///
/// Unknown senders: ZERO outbound. Pairing via kiosk pairing.qr (ADR 0015).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'package:comstar_channel/announce_http.dart';
import 'package:comstar_channel/bindings.dart';
import 'package:comstar_channel/channel.dart';
import 'package:comstar_channel/identity.dart';
import 'package:comstar_channel/identity_resolver.dart';
import 'package:comstar_channel/mux.dart';
import 'package:comstar_channel/pairing.dart';
import 'package:comstar_channel/rate_limit.dart';
import 'package:comstar_channel/session.dart';
import 'package:comstar_channel/signal.dart';
import 'package:comstar_channel/telegram.dart';
import 'package:comstar_channel/whatsapp.dart';

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

  final tgToken = Platform.environment['TELEGRAM_BOT_TOKEN'] ?? '';
  final waOn = whatsappConfiguredFromEnv();
  final signalOn = signalConfiguredFromEnv();
  if (tgToken.isEmpty && !waOn && !signalOn) {
    _log('error', 'config',
        'Need TELEGRAM_BOT_TOKEN and/or WhatsApp Cloud env and/or COMSTAR_SIGNAL_URL');
    exit(2);
  }

  final staticAllowlist = Allowlist.fromEnv();
  final bindings = BindingStore();
  await bindings.load();
  final identity = IdentityResolver(
    staticAllowlist: staticAllowlist,
    bindings: bindings,
  );
  _log('info', 'config', 'Identity loaded', {
    'static': staticAllowlist.length,
    'bindings': bindings.length,
  });

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

  final providers = <Channel>[];
  TelegramChannel? telegram;
  if (tgToken.isNotEmpty) {
    telegram = TelegramChannel(botToken: tgToken);
    providers.add(telegram);
  }
  WhatsAppChannel? whatsapp;
  if (waOn) {
    whatsapp = WhatsAppChannel.fromEnv();
    providers.add(whatsapp);
  }
  SignalChannel? signal;
  if (signalOn) {
    signal = SignalChannel.fromEnv();
    providers.add(signal);
  }
  final mux = ChannelMux(providers);
  final pairing = PairingManager(bindings: bindings);
  late final StreamSubscription<ChannelInbound> sub;

  final announceBind =
      Platform.environment['COMSTAR_CHANNEL_BIND'] ?? '127.0.0.1';
  final announcePort =
      int.tryParse(Platform.environment['COMSTAR_CHANNEL_PORT'] ?? '') ?? 8782;
  final channelHttpToken = Platform.environment['COMSTAR_CHANNEL_TOKEN'] ?? '';
  final announceHttp = AnnounceHttpServer(
    channel: mux,
    identity: identity,
    pairing: pairing,
    token: channelHttpToken,
    bindHost: announceBind,
    port: announcePort,
    whatsapp: whatsapp,
    whatsappDisplayPhone: whatsappDisplayPhoneFromEnv() ?? '',
    signalAccount: signalAccountFromEnv() ?? '',
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

  Future<void> replyOn(ChannelInbound msg, String text) async {
    try {
      await mux.sendOn(msg.provider, msg.senderId, text);
    } catch (_) {
      try {
        await mux.send(msg.senderId, text);
      } catch (_) {}
    }
  }

  sub = mux.inbound.listen((msg) async {
    final linkedUser = await pairing.completeFromInboundText(
      provider: msg.provider,
      senderId: msg.senderId,
      text: msg.text,
    );
    if (linkedUser != null) {
      _log('info', 'pairing_complete', 'Channel linked via QR/start', {
        'userid': linkedUser,
        'provider': msg.provider,
        'senderId': msg.senderId,
      });
      await replyOn(
        msg,
        'Linked to COMSTAR as $linkedUser. You can message me here.',
      );
      return;
    }
    // Telegram /start with unknown token → silence (do not reveal bot).
    if (PairingManager.telegramStartPayload(msg.text) != null) {
      _log('info', 'pairing_miss', 'start payload did not match pending', {
        'senderId': msg.senderId,
        'provider': msg.provider,
      });
      return;
    }

    final userid = identity.useridFor(
      provider: msg.provider,
      senderId: msg.senderId,
    );
    if (userid == null) {
      _log('info', 'allowlist_deny', 'unknown sender silenced', {
        'senderId': msg.senderId,
        'provider': msg.provider,
      });
      return;
    }
    if (!limiter.allow('${msg.provider}:${msg.senderId}')) {
      _log('warn', 'rate_limit', 'sender or daily cap hit', {
        'senderId': msg.senderId,
        'userid': userid,
      });
      await replyOn(msg, 'Too many messages — try again later.');
      return;
    }

    _log('info', 'inbound', 'message', {
      'userid': userid,
      'chars': msg.text.length,
      'provider': msg.provider,
    });
    try {
      await mux.setTyping(msg.senderId, ChannelTyping.started);
      final reply = await sessions.turn(userid, msg.text);
      await replyOn(msg, reply);
      _log('info', 'outbound', 'replied', {
        'userid': userid,
        'chars': reply.length,
      });
    } catch (e) {
      _log('error', 'turn_fail', '$e', {'userid': userid});
      await replyOn(msg, 'Sorry — something went wrong.');
    }
  });

  await mux.start();
  if (telegram != null) {
    final botUser = await resolveTelegramBotUsername(telegram);
    announceHttp.telegramBotUsername = botUser;
    if (botUser.isEmpty) {
      _log('warn', 'config',
          'Telegram bot username unknown — Telegram QR pairing needs TELEGRAM_BOT_USERNAME or getMe');
    }
  }

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
    'providers': [
      if (telegram != null) 'telegram',
      if (whatsapp != null) 'whatsapp',
      if (signal != null) 'signal',
    ],
    'telegramBot': announceHttp.telegramBotUsername,
    'announceHttp': '$announceBind:$announcePort',
  });

  Timer.periodic(const Duration(minutes: 15), (_) async {
    try {
      await sessions.reapIdle();
    } catch (e) {
      _log('warn', 'reap_fail', '$e');
    }
  });
}
