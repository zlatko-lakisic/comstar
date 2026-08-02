import 'dart:io';

import 'package:comstar_bridge/host_metrics.dart';
import 'package:test/test.dart';

void main() {
  group('HostMetrics', () {
    test('sample returns bounded percents', () async {
      final metrics = HostMetrics();
      await metrics.sample();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final sample = await metrics.sample();
      expect(sample.cpuPercent, inInclusiveRange(0, 100));
      expect(sample.memPercent, inInclusiveRange(0, 100));
      expect(sample.tsMs, greaterThan(0));
      final json = sample.toJson();
      expect(json['cpu'], isA<double>());
      expect(json['mem'], isA<double>());
    }, skip: !Platform.isLinux ? 'Linux /proc only' : false);
  });
}
