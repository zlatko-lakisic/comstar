import 'package:comstar_bridge/sentiment.dart';
import 'package:test/test.dart';

void main() {
  group('inferMoodFromText', () {
    test('happy / celebratory / concerned / thinking / neutral', () {
      expect(inferMoodFromText('Great to see you!'), kMoodHappy);
      expect(inferMoodFromText('Congratulations on the launch!'), kMoodCelebratory);
      expect(inferMoodFromText('Sorry, I cannot do that.'), kMoodConcerned);
      expect(inferMoodFromText('Let me check that for you.'), kMoodThinking);
      expect(inferMoodFromText('The lights are on.'), kMoodNeutral);
    });

    test('resolveSpeakMood respects explicit tag', () {
      expect(
        resolveSpeakMood('Sorry about that', explicit: 'happy'),
        kMoodHappy,
      );
      expect(resolveSpeakMood('Sorry about that'), kMoodConcerned);
    });
  });
}
