import 'dart:async';
import 'dart:typed_data';

import 'package:comstar_bridge/attention/clock.dart';
import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/vision/camera.dart';
import 'package:comstar_bridge/vision/cpai_client.dart';
import 'package:comstar_bridge/vision/identity.dart';

/// Events emitted by the vision poll loop for the attention machine.
sealed class VisionEvent {
  const VisionEvent();
}

final class VisionPersonDetected extends VisionEvent {
  const VisionPersonDetected(this.confidence);
  final double confidence;
}

final class VisionPersonAbsent extends VisionEvent {
  const VisionPersonAbsent();
}

final class VisionFaceRecognized extends VisionEvent {
  const VisionFaceRecognized(this.userid, this.confidence);
  final String userid;
  final double confidence;
}

final class VisionFaceUnknown extends VisionEvent {
  const VisionFaceUnknown();
}

final class VisionDegraded extends VisionEvent {
  const VisionDegraded();
}

final class VisionRecovered extends VisionEvent {
  const VisionRecovered();
}

/// Poll loop: detection at current fps; recognize only when needed.
class VisionPoller {
  VisionPoller({
    required this.camera,
    required this.client,
    required this.identity,
    required this.config,
    required this.clock,
    this.absentFrameThreshold = 3,
  });

  final Camera camera;
  final CpaiClient client;
  final IdentityResolver identity;
  final VisionConfig config;
  final Clock clock;
  final int absentFrameThreshold;

  final _events = StreamController<VisionEvent>.broadcast(sync: true);
  StreamSubscription<Uint8List>? _frameSub;
  StreamSubscription<bool>? _degradedSub;
  late double _targetFps;
  var _running = false;
  var _personPresent = false;
  var _absentFrames = 0;
  var _busy = false;

  Stream<VisionEvent> get events => _events.stream;

  double get targetFps => _targetFps;

  void setTargetFps(double fps) => _targetFps = fps;

  Future<void> start({double? initialFps}) async {
    if (_running) return;
    _running = true;
    _targetFps = initialFps ?? config.ambientFps;

    _degradedSub = client.degradedStream.listen((degraded) {
      if (degraded) {
        _emit(const VisionDegraded());
        setTargetFps(config.ambientFps);
      } else {
        _emit(const VisionRecovered());
      }
    });

    _frameSub = camera.frames(targetFps: _targetFps).listen(
      (frame) => unawaited(_onFrame(frame)),
      onError: (_) {},
    );
  }

  Future<void> stop() async {
    _running = false;
    await _frameSub?.cancel();
    await _degradedSub?.cancel();
    _frameSub = null;
    _degradedSub = null;
  }

  Future<void> pollOnce(Uint8List frame) => _processFrame(frame);

  Future<void> _onFrame(Uint8List frame) async {
    if (!_running || _busy) return;
    await _processFrame(frame);
  }

  Future<void> _processFrame(Uint8List frame) async {
    if (_busy) return;
    _busy = true;
    try {
      final detections = await client.detectPerson(frame);
      final person = detections
          .where((d) => d.isPerson && d.confidence >= config.personConfidence)
          .toList();

      if (person.isNotEmpty) {
        _personPresent = true;
        _absentFrames = 0;
        identity.onPersonDetected();
        final best = person.reduce(
          (a, b) => a.confidence >= b.confidence ? a : b,
        );
        _emit(VisionPersonDetected(best.confidence));

        if (_personPresent && identity.needsRecognition) {
          await _recognize(frame);
        }
      } else {
        _personPresent = false;
        _absentFrames++;
        if (_absentFrames >= absentFrameThreshold) {
          _emit(const VisionPersonAbsent());
        }
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _recognize(Uint8List frame) async {
    final matches = await client.recognizeFace(frame);
    if (matches.isEmpty) {
      // No face this frame (angle/blur/cutoff). Keep vote progress while the
      // person is still present — wiping here blocked engagement whenever CPAI
      // flipped between success and unsuccessful on adjacent frames.
      return;
    }

    final best = matches.reduce(
      (a, b) => a.confidence >= b.confidence ? a : b,
    );

    if (!best.isKnown) {
      final vote = identity.recordUnknown();
      if (vote is IdentityVoteUnknown) {
        _emit(const VisionFaceUnknown());
      }
      return;
    }

    final vote = identity.recordMatch(best.userid, best.confidence);
    switch (vote) {
      case IdentityVoteRecognized(:final userid, :final confidence):
        _emit(VisionFaceRecognized(userid, confidence));
      case IdentityVoteUnknown():
        _emit(const VisionFaceUnknown());
      case IdentityVotePending():
        break;
    }
  }

  void _emit(VisionEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
    await camera.dispose();
  }
}
