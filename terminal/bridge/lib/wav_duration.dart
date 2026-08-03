import 'dart:io';
import 'dart:typed_data';

/// PCM WAV play duration in milliseconds, or null if the file is not a
/// readable RIFF/WAVE with a `fmt` + `data` chunk.
int? wavDurationMs(String path) {
  try {
    final bytes = File(path).readAsBytesSync();
    return wavDurationMsFromBytes(bytes);
  } catch (_) {
    return null;
  }
}

int? wavDurationMsFromBytes(Uint8List bytes) {
  if (bytes.length < 44) return null;
  if (!_fourCc(bytes, 0, 'RIFF') || !_fourCc(bytes, 8, 'WAVE')) return null;

  var offset = 12;
  int? byteRate;
  int? dataSize;
  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = ByteData.sublistView(bytes, offset + 4, offset + 8)
        .getUint32(0, Endian.little);
    final dataStart = offset + 8;
    final dataEnd = dataStart + size;
    if (dataEnd > bytes.length) break;
    if (id == 'fmt ' && size >= 16) {
      byteRate = ByteData.sublistView(bytes, dataStart + 8, dataStart + 12)
          .getUint32(0, Endian.little);
    } else if (id == 'data') {
      dataSize = size;
    }
    offset = dataEnd + (size.isOdd ? 1 : 0);
    if (byteRate != null && dataSize != null) break;
  }
  if (byteRate == null || byteRate <= 0 || dataSize == null || dataSize <= 0) {
    return null;
  }
  return ((dataSize * 1000) / byteRate).round();
}

/// Rough spoken length when WAV metadata is unavailable (~12.5 chars/sec).
int estimateSpeechMs(String text, {int minMs = 1500, int maxMs = 120000}) {
  final n = text.trim().length;
  if (n == 0) return minMs;
  final ms = (n / 12.5 * 1000).round();
  if (ms < minMs) return minMs;
  if (ms > maxMs) return maxMs;
  return ms;
}

bool _fourCc(Uint8List bytes, int offset, String tag) {
  if (offset + 4 > bytes.length || tag.length != 4) return false;
  return bytes[offset] == tag.codeUnitAt(0) &&
      bytes[offset + 1] == tag.codeUnitAt(1) &&
      bytes[offset + 2] == tag.codeUnitAt(2) &&
      bytes[offset + 3] == tag.codeUnitAt(3);
}
