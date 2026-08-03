import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Frame source for the vision poller.
abstract class Camera {
  Stream<Uint8List> frames({required double targetFps});
  Future<void> dispose();
}

/// Test double that emits scripted JPEG frames at the requested rate.
class FakeCamera implements Camera {
  FakeCamera(this._frames, {this.frameDelay = Duration.zero});

  final List<Uint8List> _frames;
  final Duration frameDelay;
  int _index = 0;
  StreamController<Uint8List>? _controller;
  Timer? _timer;
  var _disposed = false;

  @override
  Stream<Uint8List> frames({required double targetFps}) {
    _controller?.close();
    _controller = StreamController<Uint8List>(
      onListen: () => _schedule(targetFps),
      onCancel: () {
        _timer?.cancel();
        _timer = null;
      },
    );
    return _controller!.stream;
  }

  void _schedule(double targetFps) {
    if (_disposed || _controller == null) return;
    if (_frames.isEmpty) {
      _controller!.close();
      return;
    }

    final period = targetFps <= 0
        ? const Duration(seconds: 1)
        : Duration(microseconds: (1000000 / targetFps).round());

    void emit() {
      if (_disposed || _controller == null || _controller!.isClosed) return;
      _controller!.add(_frames[_index % _frames.length]);
      _index++;
      _timer = Timer(period + frameDelay, emit);
    }

    emit();
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _timer?.cancel();
    await _controller?.close();
  }
}

/// Long-lived ffmpeg process producing JPEG frames (mac/linux).
class FfmpegCamera implements Camera {
  FfmpegCamera({
    required this.input,
    this.ffmpegPath = 'ffmpeg',
    this.width = 640,
    this.height = 480,
  });

  final String input;
  final String ffmpegPath;
  final int width;
  final int height;

  Process? _process;
  StreamController<Uint8List>? _controller;
  StreamSubscription<List<int>>? _stdoutSub;
  var _disposed = false;

  @override
  Stream<Uint8List> frames({required double targetFps}) {
    _controller?.close();
    _controller = StreamController<Uint8List>(
      onListen: () => unawaited(_start(targetFps)),
      onCancel: () => unawaited(_stopProcess()),
    );
    return _controller!.stream;
  }

  Future<void> _start(double targetFps) async {
    if (_disposed) return;
    await _stopProcess();

    final fpsArg = targetFps > 0 ? targetFps.toStringAsFixed(2) : '1';
    final args = <String>[
      '-hide_banner',
      '-loglevel',
      'error',
      ..._inputArgs(input),
      '-vf',
      'fps=$fpsArg,scale=$width:$height',
      '-f',
      'image2pipe',
      '-vcodec',
      'mjpeg',
      '-',
    ];

    try {
      _process = await Process.start(ffmpegPath, args);
    } catch (_) {
      _controller?.addError(StateError('Failed to start ffmpeg'));
      return;
    }

    final buffer = BytesBuilder(copy: false);
    _stdoutSub = _process!.stdout.listen(
      (chunk) {
        if (_controller == null || _controller!.isClosed) return;
        buffer.add(chunk);
        final data = buffer.takeBytes();
        _emitJpegs(data, buffer);
      },
      onDone: () {
        if (!_disposed && _controller != null && !_controller!.isClosed) {
          unawaited(_start(targetFps));
        }
      },
      onError: (_) {
        if (!_disposed) unawaited(_start(targetFps));
      },
    );

    unawaited(_process!.exitCode.then((code) {
      if (code != 0 && !_disposed) unawaited(_start(targetFps));
    }));
  }

  void _emitJpegs(List<int> data, BytesBuilder buffer) {
    var i = 0;
    while (i < data.length - 1) {
      if (data[i] == 0xFF && data[i + 1] == 0xD8) {
        var end = i + 2;
        while (end < data.length - 1) {
          if (data[end] == 0xFF && data[end + 1] == 0xD9) {
            end += 2;
            final frame = Uint8List.fromList(data.sublist(i, end));
            if (_controller != null && !_controller!.isClosed) {
              _controller!.add(frame);
            }
            i = end;
            break;
          }
          end++;
        }
        if (end >= data.length - 1) {
          buffer.add(data.sublist(i));
          return;
        }
      } else {
        i++;
      }
    }
    if (i < data.length) {
      buffer.add(data.sublist(i));
    }
  }

  /// Build ffmpeg `-f` / `-i` args for Linux V4L2, macOS AVFoundation, or files.
  ///
  /// Env examples:
  ///   COMSTAR_CAMERA_SOURCE=/dev/video0
  ///   COMSTAR_CAMERA_SOURCE=avfoundation:1
  ///   COMSTAR_CAMERA_SOURCE=avfoundation:1:none   (video only)
  static List<String> _inputArgs(String input) {
    final trimmed = input.trim();
    if (trimmed.startsWith('/dev/') || trimmed.startsWith('video')) {
      return ['-f', 'v4l2', '-input_format', 'mjpeg', '-i', trimmed];
    }
    const avf = 'avfoundation:';
    if (trimmed.toLowerCase().startsWith(avf)) {
      var spec = trimmed.substring(avf.length);
      // Video-only is safer for the vision poller (no unused audio graph).
      if (!spec.contains(':')) {
        spec = '$spec:none';
      }
      return [
        '-f',
        'avfoundation',
        '-framerate',
        '30',
        '-video_size',
        '640x480',
        '-pixel_format',
        'uyvy422',
        '-i',
        spec,
      ];
    }
    // File / URL / other ffmpeg inputs.
    return ['-re', '-i', trimmed];
  }

  Future<void> _stopProcess() async {
    await _stdoutSub?.cancel();
    _stdoutSub = null;
    final proc = _process;
    _process = null;
    if (proc != null) {
      proc.kill(ProcessSignal.sigterm);
      await proc.exitCode.timeout(const Duration(seconds: 2), onTimeout: () {
        proc.kill(ProcessSignal.sigkill);
        return -1;
      });
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _stopProcess();
    await _controller?.close();
  }
}

/// No-op camera for wiring smoke tests when no device is configured.
class StubCamera implements Camera {
  @override
  Stream<Uint8List> frames({required double targetFps}) =>
      const Stream.empty();

  @override
  Future<void> dispose() async {}
}
