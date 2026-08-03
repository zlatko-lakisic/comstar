import 'dart:io';

import 'package:comstar_bridge/terminal_control.dart';
import 'package:test/test.dart';

void main() {
  group('TerminalControl volume', () {
    late Map<String, String> sinkState;
    late Directory tmp;
    late TerminalControl control;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('comstar-vol-');
      sinkState = {
        'name': 'comstar_hdmi',
        'percent': '50',
        'muted': 'no',
      };
      control = TerminalControl(
        volumeStatePath: '${tmp.path}/volume.json',
        runPactl: (args) {
          if (args[0] == 'list' && args[1] == 'short') {
            return ProcessResult(
              0,
              0,
              '0\t${sinkState['name']}\tmodule-null-sink.c\ts16le 2ch 48000Hz\tIDLE\n',
              '',
            );
          }
          if (args[0] == 'get-default-sink') {
            return ProcessResult(0, 0, '${sinkState['name']}\n', '');
          }
          if (args[0] == 'get-sink-mute') {
            return ProcessResult(
              0,
              0,
              'Mute: ${sinkState['muted']}\n',
              '',
            );
          }
          if (args[0] == 'get-sink-volume') {
            final p = sinkState['percent'];
            return ProcessResult(
              0,
              0,
              'Volume: front-left: x / $p%   front-right: x / $p%\n',
              '',
            );
          }
          if (args[0] == 'set-sink-mute') {
            sinkState['muted'] = args[2] == '1' ? 'yes' : 'no';
            return ProcessResult(0, 0, '', '');
          }
          if (args[0] == 'set-sink-volume') {
            sinkState['percent'] =
                args[2].replaceAll('%', '');
            return ProcessResult(0, 0, '', '');
          }
          return ProcessResult(1, 1, '', 'unknown');
        },
      );
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('volumeSet clamps to 0-100', () {
      expect(control.volumeSet(150)['percent'], 100);
      expect(sinkState['percent'], '100');
      expect(control.volumeSet(-20)['percent'], 0);
      expect(sinkState['percent'], '0');
    });

    test('volumeAdjust clamps', () {
      sinkState['percent'] = '90';
      final r = control.volumeAdjust(50);
      expect(r['percent'], 100);
    });

    test('unmute restores last non-zero percent', () {
      control.volumeSet(65);
      control.volumeMute(true);
      expect(sinkState['muted'], 'yes');
      expect(control.lastUnmutedPercent, 65);

      final r = control.volumeMute(false);
      expect(r['muted'], isFalse);
      expect(r['percent'], 65);
      expect(sinkState['muted'], 'no');
      expect(sinkState['percent'], '65');
    });

    test('sleep flag toggles', () {
      expect(control.sleepStatus()['sleeping'], isFalse);
      control.sleepEnter();
      expect(control.sleepStatus()['sleeping'], isTrue);
      control.sleepExit();
      expect(control.sleepStatus()['sleeping'], isFalse);
    });
  });
}
