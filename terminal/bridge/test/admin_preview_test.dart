import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:comstar_bridge/admin_preview.dart';
import 'package:test/test.dart';

/// Minimal SOI…EOI JPEG stub (not a real image; fine for framing tests).
Uint8List fakeJpeg([int marker = 1]) =>
    Uint8List.fromList([0xFF, 0xD8, marker, 0xFF, 0xD9]);

Future<void> waitUntil(
  bool Function() pred, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final end = DateTime.now().add(timeout);
  while (!pred()) {
    if (DateTime.now().isAfter(end)) {
      throw TimeoutException('waitUntil timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  group('MjpegFramer', () {
    test('multipart part includes boundary, length, and jpeg bytes', () {
      final jpeg = fakeJpeg(42);
      final part = MjpegFramer.part(jpeg);
      final text = utf8.decode(part.sublist(0, part.length - jpeg.length - 2));
      expect(text, contains('--${MjpegFramer.boundary}'));
      expect(text, contains('Content-Type: image/jpeg'));
      expect(text, contains('Content-Length: ${jpeg.length}'));
      expect(
        part.sublist(part.length - jpeg.length - 2, part.length - 2),
        jpeg,
      );
    });

    test('content type is multipart x-mixed-replace', () {
      final ct = MjpegFramer.contentType;
      expect(ct.mimeType, 'multipart/x-mixed-replace');
      expect(ct.parameters['boundary'], MjpegFramer.boundary);
    });
  });

  group('PanelPreview', () {
    test('starts capture while subscribed and stops on dispose', () async {
      var captures = 0;
      final panel = PanelPreview(
        fps: 5,
        grimAvailable: () async => true,
      );
      panel.injectCapture = () async {
        captures++;
        return fakeJpeg(captures);
      };

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await panel.dispose();
        await server.close(force: true);
      });

      server.listen((req) async {
        await panel.attach(req.response);
      });

      expect(panel.subscribers, 0);

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final resp = await (await client.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}/'),
      ))
          .close();
      expect(resp.statusCode, 200);
      expect(resp.headers.contentType?.mimeType, 'multipart/x-mixed-replace');

      // Keep reading so the connection stays live.
      final sub = resp.listen((_) {});
      addTearDown(sub.cancel);

      await waitUntil(() => panel.subscribers == 1 && captures > 0);
      expect(panel.active, isTrue);

      final after = captures;
      await panel.dispose();
      expect(panel.subscribers, 0);
      expect(panel.active, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(captures, lessThanOrEqualTo(after + 1));
    });

    test('checkAvailable false when grim missing', () async {
      final panel = PanelPreview(
        fps: 1,
        grimAvailable: () async => false,
      );
      expect(await panel.checkAvailable(), isFalse);
      expect(panel.unavailableHint, contains('grim'));
    });
  });

  group('CameraPreview', () {
    test('serves last-frame cache without starting ffmpeg', () async {
      final frame = fakeJpeg(7);
      final cam = CameraPreview(
        fps: 5,
        lastFrameProvider: () => frame,
        visionActiveProvider: () => true,
        cameraInput: '/dev/should-not-open',
      );

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await cam.dispose();
        await server.close(force: true);
      });
      server.listen((req) => cam.attach(req.response));

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final resp = await (await client.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}/'),
      ))
          .close();
      expect(resp.statusCode, 200);

      final sub = resp.listen((_) {});
      addTearDown(sub.cancel);

      await waitUntil(() => cam.active && cam.source == 'vision_tap');
      expect(cam.hasFrame, isTrue);
      expect(cam.statusMap()['source'], 'vision_tap');

      await cam.dispose();
      expect(cam.active, isFalse);
    });

    test('canStart true when vision active even without frame yet', () {
      final cam = CameraPreview(
        fps: 1,
        lastFrameProvider: () => null,
        visionActiveProvider: () => true,
      );
      expect(cam.canStart, isTrue);
      expect(cam.statusMap()['source'], 'vision_tap');
    });

    test('canStart false when vision off and no camera input', () {
      final cam = CameraPreview(
        fps: 1,
        lastFrameProvider: () => null,
        visionActiveProvider: () => false,
        cameraInput: '',
      );
      expect(cam.canStart, isFalse);
      expect(cam.statusMap()['source'], 'none');
    });
  });
}
