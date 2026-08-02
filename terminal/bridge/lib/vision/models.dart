/// Typed CPAI vision results.
class Detection {
  const Detection({
    required this.label,
    required this.confidence,
    required this.xMin,
    required this.yMin,
    required this.xMax,
    required this.yMax,
  });

  final String label;
  final double confidence;
  final int xMin;
  final int yMin;
  final int xMax;
  final int yMax;

  bool get isPerson => label == 'person';
}

class FaceMatch {
  const FaceMatch({
    required this.userid,
    required this.confidence,
    required this.xMin,
    required this.yMin,
    required this.xMax,
    required this.yMax,
  });

  final String userid;
  final double confidence;
  final int xMin;
  final int yMin;
  final int xMax;
  final int yMax;

  bool get isKnown => userid.isNotEmpty && userid != 'unknown';
}
