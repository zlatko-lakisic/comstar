import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:comstar_bridge/log.dart';
import 'package:comstar_bridge/vision/camera.dart';

/// Multipart MJPEG framing for Admin Live view streams.
class MjpegFramer {
  static const boundary = 'comstarpreview';

  static ContentType get contentType => ContentType(
        'multipart',
        'x-mixed-replace',
        parameters: {'boundary': boundary},
      );

  /// One multipart body part: headers + JPEG + trailing CRLF.
  static Uint8List part(Uint8List jpeg) {
    final header = utf8.encode(
      '--$boundary\r\n'
      'Content-Type: image/jpeg\r\n'
      'Content-Length: ${jpeg.length}\r\n'
      '\r\n',
    );
    final out = BytesBuilder(copy: false)
      ..add(header)
      ..add(jpeg)
      ..add(utf8.encode('\r\n'));
    return out.takeBytes();
  }
}

/// Shared subscriber set for a timed JPEG producer.
abstract class _PreviewHub {
  final _clients = <HttpResponse>{};
  Timer? _timer;

  int get subscribers => _clients.length;
  bool get active => _clients.isNotEmpty;

  Duration get period;

  Future<void> attach(HttpResponse response) async {
    final wasIdle = _clients.isEmpty;
    if (wasIdle) {
      try {
        await onFirstSubscriber();
      } on Object {
        await onLastSubscriber();
        rethrow;
      }
    }

    response.statusCode = 200;
    response.bufferOutput = false;
    response.headers.contentType = MjpegFramer.contentType;
    response.headers.set('Cache-Control', 'no-cache, no-store');
    response.headers.set('Connection', 'close');
    response.headers.set('Pragma', 'no-cache');

    _clients.add(response);
    if (_timer == null) {
      _timer = Timer.periodic(period, (_) => unawaited(_tick()));
      unawaited(_tick());
    }

    try {
      await response.done;
    } on Object {
      // client gone
    } finally {
      if (_clients.remove(response) && _clients.isEmpty) {
        await _stopProducer();
      }
    }
  }

  Future<void> _stopProducer() async {
    final hadTimer = _timer != null;
    _timer?.cancel();
    _timer = null;
    if (hadTimer) {
      await onLastSubscriber();
    }
  }

  Future<void> _tick() async {
    if (_clients.isEmpty) return;
    Uint8List? jpeg;
    try {
      jpeg = await captureFrame();
    } on Object catch (e) {
      logWarn(errorEvt, 'Preview frame capture failed', data: {
        'error': e.toString(),
      });
      return;
    }
    if (jpeg == null || jpeg.isEmpty || _clients.isEmpty) return;
    final part = MjpegFramer.part(jpeg);
    for (final client in List<HttpResponse>.from(_clients)) {
      try {
        client.add(part);
        unawaited(client.flush());
      } on Object {
        _clients.remove(client);
        try {
          await client.close();
        } on Object {
          // ignore
        }
      }
    }
    if (_clients.isEmpty) {
      await _stopProducer();
    }
  }

  String get errorEvt;
  Future<void> onFirstSubscriber();
  Future<void> onLastSubscriber();
  Future<Uint8List?> captureFrame();

  Future<void> dispose() async {
    final leftover = List<HttpResponse>.from(_clients);
    _clients.clear();
    for (final c in leftover) {
      try {
        await c.close();
      } on Object {
        // ignore
      }
    }
    await _stopProducer();
  }
}

/// Wayland HDMI panel capture via `grim` (JPEG on stdout).
class PanelPreview extends _PreviewHub {
  PanelPreview({
    required this.fps,
    Future<Process> Function(String executable, List<String> arguments)?
        processRunner,
    this.grimPath = 'grim',
    Future<bool> Function()? grimAvailable,
  })  : processRunner = processRunner ??
            ((exe, args) => Process.start(exe, args)),
        _grimAvailable = grimAvailable;

  final double fps;
  final String grimPath;
  final Future<Process> Function(String executable, List<String> arguments)
      processRunner;
  final Future<bool> Function()? _grimAvailable;

  /// Injectable JPEG producer for tests (skips grim).
  Future<Uint8List?> Function()? injectCapture;

  bool? _grimOk;
  String? unavailableHint;

  @override
  Duration get period {
    final f = fps <= 0 ? 1.0 : fps;
    return Duration(milliseconds: (1000 / f).round().clamp(200, 2000));
  }

  @override
  String get errorEvt => 'preview_panel_error';

  Future<bool> checkAvailable() async {
    if (injectCapture != null) {
      unavailableHint = null;
      return true;
    }
    if (_grimOk != null) return _grimOk!;
    final check = _grimAvailable;
    if (check != null) {
      _grimOk = await check();
    } else {
      try {
        final r = await Process.run('which', [grimPath]);
        _grimOk = r.exitCode == 0;
      } on Object {
        _grimOk = false;
      }
    }
    if (_grimOk != true) {
      unavailableHint =
          'Install grim (apt install grim) and ensure labwc Wayland session is running';
    } else {
      unavailableHint = null;
    }
    return _grimOk!;
  }

  @override
  Future<void> onFirstSubscriber() async {
    logInfo('preview_panel_start', 'Panel preview capture started', data: {
      'fps': fps,
      'subscribers': subscribers,
    });
  }

  @override
  Future<void> onLastSubscriber() async {
    logInfo('preview_panel_stop', 'Panel preview capture stopped');
  }

  @override
  Future<Uint8List?> captureFrame() async {
    final inject = injectCapture;
    if (inject != null) return inject();

    if (!await checkAvailable()) {
      throw StateError('grim_unavailable');
    }

    Process proc;
    try {
      proc = await processRunner(grimPath, const ['-t', 'jpeg', '-']);
    } on Object catch (e) {
      unavailableHint =
          'Failed to start grim — is WAYLAND_DISPLAY set for the bridge user? ($e)';
      throw StateError('grim_start_failed');
    }

    final builder = BytesBuilder(copy: false);
    await proc.stdout.forEach(builder.add);
    final code = await proc.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        proc.kill();
        return -1;
      },
    );
    final bytes = builder.takeBytes();
    if (code != 0 || bytes.isEmpty) {
      unavailableHint =
          'grim failed (exit $code) — labwc/Wayland session may not be ready';
      throw StateError('grim_capture_failed');
    }
    return Uint8List.fromList(bytes);
  }
}

/// Camera preview: prefer vision last-frame cache; else short-lived ffmpeg.
class CameraPreview extends _PreviewHub {
  CameraPreview({
    required this.fps,
    this.lastFrameProvider,
    this.visionActiveProvider,
    this.cameraInput,
    this.ffmpegPath = 'ffmpeg',
  });

  final double fps;

  /// Latest JPEG from [VisionPoller] when vision is running.
  Uint8List? Function()? lastFrameProvider;

  /// When true, never start ffmpeg (vision owns the V4L2 device).
  bool Function()? visionActiveProvider;

  /// `COMSTAR_CAMERA_SOURCE` (e.g. `/dev/video0`) for ffmpeg fallback.
  final String? cameraInput;
  final String ffmpegPath;

  FfmpegCamera? _ffmpeg;
  StreamSubscription<Uint8List>? _ffmpegSub;
  Uint8List? _ffmpegLast;
  String? unavailableHint;
  var _source = 'none';

  String get source => _source;

  bool get _visionOn => visionActiveProvider?.call() ?? false;

  bool get hasFrame {
    final tap = lastFrameProvider?.call();
    if (tap != null && tap.isNotEmpty) return true;
    return _ffmpegLast != null && _ffmpegLast!.isNotEmpty;
  }

  @override
  Duration get period {
    final f = fps <= 0 ? 1.0 : fps;
    return Duration(milliseconds: (1000 / f).round().clamp(200, 2000));
  }

  @override
  String get errorEvt => 'preview_camera_error';

  /// Whether a stream can be opened (vision tap and/or camera device).
  bool get canStart {
    if (_visionOn) return true;
    final tap = lastFrameProvider?.call();
    if (tap != null && tap.isNotEmpty) return true;
    final input = cameraInput?.trim() ?? '';
    return input.isNotEmpty;
  }

  Map<String, Object?> statusMap() {
    final tap = lastFrameProvider?.call();
    final hasTap = tap != null && tap.isNotEmpty;
    final input = cameraInput?.trim() ?? '';
    String src;
    if (_visionOn || hasTap) {
      src = 'vision_tap';
    } else if (input.isNotEmpty) {
      src = 'ffmpeg';
    } else {
      src = 'none';
    }
    String? hint = unavailableHint;
    if (_visionOn && !hasTap) {
      hint ??= 'Waiting for vision frames';
    } else if (!_visionOn && input.isEmpty) {
      hint ??=
          'Vision off and COMSTAR_CAMERA_SOURCE unset — cannot preview camera';
    }
    return {
      'available': canStart,
      'source': active ? _source : src,
      'has_frame': hasFrame,
      if (hint != null) 'hint': hint,
    };
  }

  @override
  Future<void> onFirstSubscriber() async {
    final tap = lastFrameProvider?.call();
    if (_visionOn || (tap != null && tap.isNotEmpty)) {
      _source = 'vision_tap';
      unavailableHint = null;
      logInfo('preview_camera_start', 'Camera preview via vision tap', data: {
        'fps': fps,
        'source': _source,
        'has_frame': tap != null && tap.isNotEmpty,
      });
      return;
    }

    final input = cameraInput?.trim() ?? '';
    if (input.isEmpty) {
      unavailableHint =
          'No vision frames and COMSTAR_CAMERA_SOURCE unset — cannot preview camera';
      _source = 'none';
      throw StateError('camera_unavailable');
    }

    _source = 'ffmpeg';
    unavailableHint = null;
    _ffmpeg = FfmpegCamera(input: input, ffmpegPath: ffmpegPath);
    _ffmpegSub = _ffmpeg!.frames(targetFps: fps).listen(
      (frame) => _ffmpegLast = frame,
      onError: (Object e) {
        logWarn('preview_camera_error', 'ffmpeg preview error', data: {
          'error': e.toString(),
        });
      },
    );
    logInfo('preview_camera_start', 'Camera preview via ffmpeg', data: {
      'fps': fps,
      'source': _source,
    });
  }

  @override
  Future<void> onLastSubscriber() async {
    await _ffmpegSub?.cancel();
    _ffmpegSub = null;
    await _ffmpeg?.dispose();
    _ffmpeg = null;
    _ffmpegLast = null;
    _source = 'none';
    logInfo('preview_camera_stop', 'Camera preview stopped');
  }

  @override
  Future<Uint8List?> captureFrame() async {
    final tap = lastFrameProvider?.call();
    if (tap != null && tap.isNotEmpty) {
      _source = 'vision_tap';
      return tap;
    }
    if (_ffmpegLast != null && _ffmpegLast!.isNotEmpty) {
      _source = 'ffmpeg';
      return _ffmpegLast;
    }
    // Vision may not have produced a frame yet — keep waiting.
    if (_visionOn) return null;
    return _ffmpegLast;
  }
}
