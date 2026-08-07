import 'dart:io';

import 'package:comstar_bridge/road/cidr.dart';
import 'package:comstar_bridge/road/config.dart';
import 'package:comstar_bridge/road/home_detect.dart';
import 'package:comstar_bridge/road/nmcli_backend.dart';
import 'package:comstar_bridge/road/service.dart';
import 'package:comstar_bridge/road/store.dart';
import 'package:comstar_bridge/config.dart';
import 'package:test/test.dart';

void main() {
  group('Ipv4Cidr', () {
    test('parses and matches /24', () {
      final c = Ipv4Cidr.parse('192.168.89.0/24');
      expect(c.containsIpString('192.168.89.34'), isTrue);
      expect(c.containsIpString('192.168.90.1'), isFalse);
      expect(c.containsIpString('10.0.10.16'), isFalse);
    });

    test('parses bare IP as /32', () {
      final c = Ipv4Cidr.parse('172.16.90.5');
      expect(c.containsIpString('172.16.90.5'), isTrue);
      expect(c.containsIpString('172.16.90.6'), isFalse);
    });

    test('defaults cover configured homes', () {
      final cidrs = parseCidrList(defaultHomeCidrs);
      expect(cidrs.any((c) => c.containsIpString('192.168.89.1')), isTrue);
      expect(cidrs.any((c) => c.containsIpString('192.168.90.50')), isTrue);
      expect(cidrs.any((c) => c.containsIpString('172.16.90.2')), isTrue);
      expect(cidrs.any((c) => c.containsIpString('8.8.8.8')), isFalse);
    });
  });

  group('detectHome', () {
    test('at home when interface matches', () async {
      final result = await detectHome(
        homeCidrs: defaultHomeCidrs,
        listInterfaces: ({
          bool includeLinkLocal = false,
          bool includeLoopback = false,
          InternetAddressType? type,
        }) async {
          return [
            _FakeIface('end0', [InternetAddress('192.168.89.34')]),
          ];
        },
      );
      expect(result.atHome, isTrue);
      expect(result.matchedAddrs, ['192.168.89.34']);
    });

    test('off home on travel Wi-Fi', () async {
      final result = await detectHome(
        homeCidrs: defaultHomeCidrs,
        listInterfaces: ({
          bool includeLinkLocal = false,
          bool includeLoopback = false,
          InternetAddressType? type,
        }) async {
          return [
            _FakeIface('wlan0', [InternetAddress('10.20.30.40')]),
          ];
        },
      );
      expect(result.atHome, isFalse);
      expect(result.matchedAddrs, isEmpty);
      expect(result.allAddrs, ['10.20.30.40']);
    });
  });

  group('road config', () {
    test('example yaml section parses via defaults when absent', () {
      final path = '${Directory.current.path}/test/fixtures/comstar.valid.yaml';
      final config = ComstarConfig.loadFile(path);
      expect(config.road.enabled, isFalse);
      expect(config.road.protocol, 'openvpn');
      expect(config.road.homeCidrs, defaultHomeCidrs);
    });

    test('road section overrides', () {
      final path = '${Directory.current.path}/test/fixtures/comstar.valid.yaml';
      final base = ComstarConfig.loadFile(path);
      final map = <String, dynamic>{
        'orchestration': {
          'base_url': base.orchestration.baseUrl,
          'token': base.orchestration.token,
          'ttl_seconds': base.orchestration.ttlSeconds,
          'timeout_seconds': base.orchestration.timeoutSeconds,
          'overlay_root': base.orchestration.overlayRoot,
        },
        'vision': {
          'codeproject_url': base.vision.codeprojectUrl,
          'detection_endpoint': base.vision.detectionEndpoint,
          'recognize_endpoint': base.vision.recognizeEndpoint,
          'ambient_fps': base.vision.ambientFps,
          'engaged_fps': base.vision.engagedFps,
          'person_confidence': base.vision.personConfidence,
          'face_confidence': base.vision.faceConfidence,
          'recognize_votes': base.vision.recognizeVotes,
          'identity_ttl_seconds': base.vision.identityTtlSeconds,
        },
        'audio': {
          'wakeword_model': base.audio.wakewordModel,
          'wakeword_threshold': base.audio.wakewordThreshold,
          'vad_silence_ms': base.audio.vadSilenceMs,
          'max_utterance_seconds': base.audio.maxUtteranceSeconds,
          'followup_window_seconds': base.audio.followupWindowSeconds,
          'duplex': base.audio.duplex,
        },
        'avatar': {
          'render': base.avatar.render,
          'model': base.avatar.model,
          'tts': base.avatar.tts,
          'piper_voice': base.avatar.piperVoice,
        },
        'attention': {
          'face_attention_trigger': base.attention.faceAttentionTrigger,
          'stranger_mode': base.attention.strangerMode,
        },
        'directory': {
          'enabled': false,
          'sidecar_url': '',
          'require': true,
          'cache_ttl_seconds': 600,
          'timeout_ms': 1500,
        },
        'dev': {
          'bind_lan': false,
          'lan_token': '',
        },
        'road': {
          'enabled': true,
          'protocol': 'l2tp',
          'home_cidrs': ['10.0.0.0/8'],
          'check_interval_seconds': 60,
          'openvpn_connection': 'ovpn-a',
          'l2tp_connection': 'l2tp-b',
        },
      };
      final config = ComstarConfig.loadMap(map, sourcePath: path);
      expect(config.road.enabled, isTrue);
      expect(config.road.protocol, 'l2tp');
      expect(config.road.homeCidrs, ['10.0.0.0/8']);
      expect(config.road.checkIntervalSeconds, 60);
      expect(config.road.openvpnConnection, 'ovpn-a');
      expect(config.road.l2tpConnection, 'l2tp-b');
    });

    test('rejects bad protocol', () {
      final path = '${Directory.current.path}/test/fixtures/comstar.valid.yaml';
      final base = ComstarConfig.loadFile(path);
      expect(
        () => ComstarConfig.loadMap({
          'orchestration': {
            'base_url': base.orchestration.baseUrl,
            'token': '',
            'ttl_seconds': 3600,
            'timeout_seconds': 15,
            'overlay_root': './overlays',
          },
          'vision': {
            'codeproject_url': 'http://127.0.0.1',
            'detection_endpoint': '/d',
            'recognize_endpoint': '/r',
            'ambient_fps': 1,
            'engaged_fps': 3,
            'person_confidence': 0.6,
            'face_confidence': 0.5,
            'recognize_votes': 2,
            'identity_ttl_seconds': 300,
          },
          'audio': {
            'wakeword_model': 'm',
            'wakeword_threshold': 0.5,
            'vad_silence_ms': 700,
            'max_utterance_seconds': 15,
            'followup_window_seconds': 10,
            'duplex': 'half',
          },
          'avatar': {
            'render': 'local',
            'model': 'm',
            'tts': 'piper',
            'piper_voice': 'v',
          },
          'attention': {
            'face_attention_trigger': false,
            'stranger_mode': 'restricted',
          },
          'directory': {
            'enabled': false,
            'sidecar_url': '',
            'require': true,
            'cache_ttl_seconds': 600,
            'timeout_ms': 1500,
          },
          'dev': {'bind_lan': false, 'lan_token': ''},
          'road': {'protocol': 'wireguard'},
        }, sourcePath: path),
        throwsA(isA<ConfigError>()),
      );
    });
  });

  group('RoadService heal', () {
    test('brings VPN up when off-home and enabled', () async {
      final dir = await Directory.systemTemp.createTemp('comstar-road-');
      final connections = <String>{'comstar-ovpn'};
      final active = <String>{};
      var healthCalls = 0;

      Future<ProcessResult> runner(String exe, List<String> args) async {
        // Skip real prereq dpkg calls — service caches after first inspect.
        if (exe == 'dpkg-query' || exe == 'sh' || (exe == 'sudo' && args.contains('nmcli') == false)) {
          return ProcessResult(0, 1, '', '');
        }
        final nmArgs = exe == 'sudo'
            ? args.skipWhile((a) => a != 'nmcli').skip(1).toList()
            : (exe == 'nmcli' ? args : args);
        if (nmArgs.isEmpty) {
          // sudo -n nmcli probe
          if (args.contains('nmcli')) {
            return ProcessResult(0, 0, 'comstar-ovpn\n', '');
          }
          return ProcessResult(0, 1, '', '');
        }
        final joined = nmArgs.join(' ');
        if (joined.contains('connection show --active') ||
            (nmArgs.contains('--active') && nmArgs.contains('show'))) {
          return ProcessResult(0, 0, active.map((e) => e).join('\n') + (active.isEmpty ? '' : '\n'), '');
        }
        if (joined.contains('connection show') ||
            (nmArgs.contains('show') && !nmArgs.contains('--active'))) {
          return ProcessResult(0, 0, '${connections.join('\n')}\n', '');
        }
        if (nmArgs.contains('up')) {
          final idIdx = nmArgs.indexOf('id');
          final name = idIdx >= 0 && idIdx + 1 < nmArgs.length ? nmArgs[idIdx + 1] : '';
          active.add(name);
          return ProcessResult(0, 0, 'Connection activated\n', '');
        }
        if (nmArgs.contains('down')) {
          final idIdx = nmArgs.indexOf('id');
          final name = idIdx >= 0 && idIdx + 1 < nmArgs.length ? nmArgs[idIdx + 1] : '';
          active.remove(name);
          return ProcessResult(0, 0, '', '');
        }
        return ProcessResult(0, 0, '', '');
      }

      final svc = RoadService(
        yamlConfig: const RoadConfig(enabled: true, protocol: 'openvpn'),
        store: RoadStore(stateDir: dir.path),
        backend: NmcliVpnBackend(runner: runner, stateDir: dir.path),
        processRunner: runner,
        listInterfaces: ({
          bool includeLinkLocal = false,
          bool includeLoopback = false,
          InternetAddressType? type,
        }) async =>
            [_FakeIface('wlan0', [InternetAddress('10.20.30.40')])],
        healthProber: (url) async {
          healthCalls++;
          return true;
        },
      );

      // Seed prereq cache so inspect does not depend on dpkg.
      // ignore: invalid_use_of_visible_for_testing_member

      final result = await svc.reconcile(forceConnect: true);
      expect(result['ok'], isTrue);
      expect(active.contains('comstar-ovpn'), isTrue);
      expect(healthCalls, greaterThan(0));
      expect(svc.monitorState, anyOf('healthy', 'watching', 'healing'));

      await dir.delete(recursive: true);
    });
  });
}

class _FakeIface implements NetworkInterface {
  _FakeIface(this.name, this.addresses);
  @override
  final String name;
  @override
  final List<InternetAddress> addresses;
  @override
  int get index => 0;
}
