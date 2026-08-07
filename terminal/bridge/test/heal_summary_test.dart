import 'package:comstar_bridge/heal_summary.dart';
import 'package:test/test.dart';

void main() {
  test('healthy output', () {
    expect(
      summarizeHealOutput('OK   unit bridge\nResults: PASS=5 FAIL=0 HEALED=0\n'),
      contains('perfectly healthy'),
    );
  });

  test('healed issues', () {
    final s = summarizeHealOutput('''
FAIL unit comstar-audio inactive
HEAL restarted comstar-audio
Results: PASS=4 FAIL=0 HEALED=1
''');
    expect(s.toLowerCase(), contains('fixed'));
    expect(s.toLowerCase(), contains('audio'));
  });

  test('remaining fails', () {
    final s = summarizeHealOutput('''
FAIL AO unreachable
Results: PASS=3 FAIL=1 HEALED=0
''');
    expect(s.toLowerCase(), contains('could not fully fix'));
  });
}
