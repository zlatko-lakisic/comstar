import 'package:comstar_bridge/spoken_reply.dart';
import 'package:test/test.dart';

void main() {
  test('unwraps spoken key', () {
    expect(
      unwrapSpokenReply(
        '{"spoken":"The porch light is on.","entities":["light.porch"]}',
      ),
      'The porch light is on.',
    );
  });

  test('unwraps fenced answer', () {
    expect(
      unwrapSpokenReply(
        '```json\n{"answer":"Garden got about two inches yesterday."}\n```',
      ),
      'Garden got about two inches yesterday.',
    );
  });

  test('blanks tool stub', () {
    expect(
      unwrapSpokenReply('{"name":"GetLiveContext","parameters":{}}'),
      '',
    );
  });

  test('blanks opaque machine json', () {
    expect(
      unwrapSpokenReply(
        '{"entity_id":"sensor.x","state":"on","attributes":{"foo":1}}',
      ),
      '',
    );
  });

  test('leaves plain prose', () {
    expect(unwrapSpokenReply('Hello from the hallway.'), 'Hello from the hallway.');
  });
}
