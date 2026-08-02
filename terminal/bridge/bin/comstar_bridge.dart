import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/local_ws.dart';
import 'package:comstar_bridge/log.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'config',
      abbr: 'c',
      help: 'Path to comstar.yaml',
    );

  late final String configPath;
  try {
    final results = parser.parse(arguments);
    configPath = results['config'] as String? ??
        Platform.environment['COMSTAR_CONFIG'] ??
        'config/comstar.yaml';
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    exit(2);
  }

  late final ComstarConfig config;
  try {
    config = ComstarConfig.loadFile(configPath);
  } on ConfigError catch (e) {
    logError('config_error', e.message);
    exit(1);
  }

  final ws = LocalWs(config: config);
  await ws.start();

  logInfo('bridge_started', 'COMSTAR bridge running', data: {
    'config': configPath,
    'dev_lan': config.devLanBindingEnabled,
  });

  final completer = Completer<void>();
  var stopping = false;

  Future<void> shutdown() async {
    if (stopping) return;
    stopping = true;
    logInfo('shutdown', 'SIGTERM received, draining');
    await ws.stop();
    if (!completer.isCompleted) completer.complete();
  }

  ProcessSignal.sigterm.watch().listen((_) => unawaited(shutdown()));
  ProcessSignal.sigint.watch().listen((_) => unawaited(shutdown()));

  await completer.future;
  exit(0);
}
