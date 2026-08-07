#!/usr/bin/env dart
// Headless AO mTLS enroll (ADR 0013).
//
// Usage:
//   TOKEN=<mint-token> dart run tool/ao_mtls_enroll.dart --config ../../config/comstar.yaml
//   make ao-mtls-enroll TOKEN=… CONFIG=config/comstar.yaml

import 'dart:io';

import 'package:args/args.dart';
import 'package:comstar_bridge/ao_mtls/service.dart';
import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/log.dart';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('config', abbr: 'c', help: 'Path to comstar.yaml')
    ..addOption('token', abbr: 't', help: 'Ada mint-token (or env TOKEN / ENROLL_TOKEN)')
    ..addOption('client-name', help: 'Optional CN override')
    ..addFlag('probe', help: 'Probe /health with existing material (no enroll)', defaultsTo: false)
    ..addFlag('clear', help: 'Clear local material', defaultsTo: false)
    ..addFlag('help', abbr: 'h', negatable: false);

  final opts = parser.parse(args);
  if (opts['help'] == true) {
    stdout.writeln(parser.usage);
    exit(0);
  }

  final configPath = (opts['config'] as String?)?.trim().isNotEmpty == true
      ? opts['config'] as String
      : (Platform.environment['CONFIG'] ?? 'config/comstar.yaml');
  final config = ComstarConfig.loadFile(configPath);
  final svc = AoMtlsService(config: config);

  if (opts['clear'] == true) {
    final r = await svc.clear();
    stdout.writeln(r);
    exit(r['ok'] == true ? 0 : 1);
  }

  if (opts['probe'] == true) {
    final r = await svc.probe();
    stdout.writeln(r);
    exit(r['ok'] == true ? 0 : 1);
  }

  final token = ((opts['token'] as String?)?.trim().isNotEmpty == true
          ? opts['token'] as String
          : (Platform.environment['TOKEN'] ??
              Platform.environment['ENROLL_TOKEN'] ??
              ''))
      .trim();
  if (token.isEmpty) {
    stderr.writeln('Missing enroll token. Pass --token or TOKEN=…');
    exit(2);
  }

  final clientName = (opts['client-name'] as String?)?.trim();
  try {
    final r = await svc.enroll(
      enrollToken: token,
      clientName: clientName?.isNotEmpty == true ? clientName : null,
    );
    stdout.writeln('enrolled ok material_dir=${r['material_dir']} client=${r['client_name']}');
    exit(0);
  } on Object catch (e) {
    logError('ao_mtls_enroll_cli', e.toString());
    stderr.writeln(e);
    exit(1);
  }
}
