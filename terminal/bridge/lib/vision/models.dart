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

/// Named box for Admin Live camera overlay (pixel coords of last frame).
class VisionOverlay {
  const VisionOverlay({
    required this.kind,
    required this.label,
    required this.confidence,
    required this.xMin,
    required this.yMin,
    required this.xMax,
    required this.yMax,
  });

  /// `person` or `face`.
  final String kind;
  final String label;
  final double confidence;
  final int xMin;
  final int yMin;
  final int xMax;
  final int yMax;

  Map<String, Object?> toJson() => {
        'kind': kind,
        'label': label,
        'confidence': confidence,
        'x_min': xMin,
        'y_min': yMin,
        'x_max': xMax,
        'y_max': yMax,
      };
}
