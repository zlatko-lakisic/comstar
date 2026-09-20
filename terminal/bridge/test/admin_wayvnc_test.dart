import 'package:comstar_bridge/admin_wayvnc.dart';
import 'package:test/test.dart';

void main() {
  group('WayvncPanel', () {
    test('statusMap includes ws path and backend', () {
      final panel = WayvncPanel(port: 5901, maxFps: 15);
      final m = panel.statusMap();
      expect(m['backend'], 'wayvnc');
      expect(m['ws'], '/admin/api/preview/panel.ws');
      expect(m['subscribers'], 0);
      expect(m['running'], isFalse);
    });
  });
}
