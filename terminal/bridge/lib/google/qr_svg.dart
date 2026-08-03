import 'package:qr/qr.dart';

/// Renders [data] as a compact SVG QR (light modules on dark, kiosk-friendly).
String qrSvg(String data, {int moduleSize = 6, int quietZone = 2}) {
  final code = QrCode(
    payload: QrPayload.fromString(data),
    errorCorrectLevel: QrErrorCorrectLevel.medium,
  );
  final image = QrImage(code);
  final n = image.moduleCount;
  final dim = (n + quietZone * 2) * moduleSize;
  final buf = StringBuffer()
    ..write(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $dim $dim" '
      'width="$dim" height="$dim" shape-rendering="crispEdges">',
    )
    ..write('<rect width="100%" height="100%" fill="#f5f7fa"/>');
  for (var y = 0; y < n; y++) {
    for (var x = 0; x < n; x++) {
      if (!image.isDark(y, x)) continue;
      final px = (x + quietZone) * moduleSize;
      final py = (y + quietZone) * moduleSize;
      buf.write(
        '<rect x="$px" y="$py" width="$moduleSize" height="$moduleSize" fill="#0b1220"/>',
      );
    }
  }
  buf.write('</svg>');
  return buf.toString();
}
