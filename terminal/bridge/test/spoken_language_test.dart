import 'package:comstar_bridge/spoken_language.dart';
import 'package:test/test.dart';

void main() {
  test('English ok', () {
    expect(shouldRejectForeignScriptReply('Your 2pm moved to 3.'), isFalse);
  });

  test('Thai rejected', () {
    expect(
      shouldRejectForeignScriptReply(
        'คณะกรรมการทำงานของฉันไม่มีข้อมูลเกี่ยวกับผู้ที่มาที่ประตูหน้าในวันนี้',
      ),
      isTrue,
    );
  });

  test('mixed Thai + Chinese rejected', () {
    expect(
      shouldRejectForeignScriptReply(
        'คณะกรรมการทำงานของฉันไม่มี权限执行resume所有 torrents的操作。',
      ),
      isTrue,
    );
  });

  test('latin with accent ok', () {
    expect(shouldRejectForeignScriptReply('Café is ready.'), isFalse);
  });
}
