import 'dart:convert';
import 'dart:io';

const _proc = 'bridge';

enum LogLevel {
  debug(0),
  info(1),
  warn(2),
  error(3);

  const LogLevel(this.priority);
  final int priority;

  static LogLevel fromEnv([String? raw]) {
    final value = (raw ?? Platform.environment['COMSTAR_LOG'] ?? 'info')
        .trim()
        .toLowerCase();
    return switch (value) {
      'debug' => LogLevel.debug,
      'warn' => LogLevel.warn,
      'error' => LogLevel.error,
      _ => LogLevel.info,
    };
  }
}

LogLevel _globalLevel = LogLevel.fromEnv();

void configureLogLevel(LogLevel level) => _globalLevel = level;

void logEvent({
  required LogLevel level,
  required String evt,
  required String msg,
  String? turnId,
  Map<String, dynamic>? data,
}) {
  if (level.priority < _globalLevel.priority) return;
  final entry = <String, dynamic>{
    'ts': DateTime.now().millisecondsSinceEpoch,
    'level': level.name,
    'proc': _proc,
    'evt': evt,
    'msg': msg,
  };
  if (turnId != null) entry['turn_id'] = turnId;
  if (data != null && data.isNotEmpty) entry['data'] = data;
  stdout.writeln(jsonEncode(entry));
}

void logDebug(String evt, String msg,
        {String? turnId, Map<String, dynamic>? data}) =>
    logEvent(
        level: LogLevel.debug,
        evt: evt,
        msg: msg,
        turnId: turnId,
        data: data);

void logInfo(String evt, String msg,
        {String? turnId, Map<String, dynamic>? data}) =>
    logEvent(
        level: LogLevel.info,
        evt: evt,
        msg: msg,
        turnId: turnId,
        data: data);

void logWarn(String evt, String msg,
        {String? turnId, Map<String, dynamic>? data}) =>
    logEvent(
        level: LogLevel.warn,
        evt: evt,
        msg: msg,
        turnId: turnId,
        data: data);

void logError(String evt, String msg,
        {String? turnId, Map<String, dynamic>? data}) =>
    logEvent(
        level: LogLevel.error,
        evt: evt,
        msg: msg,
        turnId: turnId,
        data: data);

class Span {
  Span(this.name, {this.turnId}) : _start = DateTime.now();

  final String name;
  final String? turnId;
  final DateTime _start;
  bool _closed = false;

  int get elapsedMs => DateTime.now().difference(_start).inMilliseconds;

  void close({Map<String, dynamic>? data}) {
    if (_closed) return;
    _closed = true;
    logInfo('span', '$name completed', turnId: turnId, data: {
      'name': name,
      'ms': elapsedMs,
      if (data != null) ...data,
    });
  }
}
