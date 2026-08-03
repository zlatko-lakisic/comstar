import 'dart:io';

/// First non-empty environment value among [names], or null.
String? envFirst(List<String> names) {
  for (final name in names) {
    final raw = Platform.environment[name];
    if (raw != null && raw.trim().isNotEmpty) {
      return raw.trim();
    }
  }
  return null;
}

/// Camera ffmpeg input: `/dev/video0`, `avfoundation:0`, etc.
///
/// Preferred: `COMSTAR_CAMERA_SOURCE`.
/// Aliases: `COMSTAR_CAMERA_INPUT`, `COMSTAR_CAMERA_DEVICE`.
String? cameraSource() => envFirst(const [
      'COMSTAR_CAMERA_SOURCE',
      'COMSTAR_CAMERA_INPUT',
      'COMSTAR_CAMERA_DEVICE',
    ]);

/// PulseAudio / PipeWire sink for local paplay fallback.
///
/// Preferred: `COMSTAR_SPEAKER_SOURCE`.
/// Aliases: `COMSTAR_SPEAKER_SINK`, `COMSTAR_AUDIO_SINK`.
String? speakerSource() => envFirst(const [
      'COMSTAR_SPEAKER_SOURCE',
      'COMSTAR_SPEAKER_SINK',
      'COMSTAR_AUDIO_SINK',
    ]);
