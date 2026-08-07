import 'package:comstar_bridge/net/hotspot.dart';
import 'package:comstar_bridge/net/nmcli.dart';
import 'package:comstar_bridge/net/service.dart';
import 'package:test/test.dart';

class FakeNmcli extends NmcliRunner {
  FakeNmcli(this.script);

  final Future<NmcliResult> Function(List<String> args) script;

  @override
  Future<NmcliResult> run(List<String> args) => script(args);

  @override
  Future<bool> available() async => true;
}

void main() {
  group('HotspotService', () {
    test('resolveSsid prefixes COMSTAR and stays ≤32', () {
      final svc = HotspotService(
        network: NetworkService(nmcli: FakeNmcli((_) async => const NmcliResult(
              exitCode: 0,
              stdout: '',
              stderr: '',
            ))),
        ssidOverride: 'COMSTAR-verylonghostnamethatexceedslimits',
      );
      expect(svc.resolveSsid().length, lessThanOrEqualTo(32));
      expect(svc.resolveSsid(), startsWith('COMSTAR-'));
    });

    test('reconcile tears down when uplink present', () async {
      var downs = 0;
      final nm = FakeNmcli((args) async {
        final joined = args.join(' ');
        if (joined.contains('connection show --active')) {
          return const NmcliResult(
            exitCode: 0,
            stdout: 'comstar-hotspot:wlan0\n',
            stderr: '',
          );
        }
        if (joined.startsWith('connection down')) {
          downs++;
          return const NmcliResult(exitCode: 0, stdout: '', stderr: '');
        }
        if (joined.contains('device status')) {
          return const NmcliResult(
            exitCode: 0,
            stdout: 'end0:ethernet:connected:Wired connection 1\n'
                'wlan0:wifi:connected:comstar-hotspot\n',
            stderr: '',
          );
        }
        if (joined.contains('device show') || joined.contains('connection show')) {
          return const NmcliResult(
            exitCode: 0,
            stdout: 'ipv4.method:auto\nipv4.addresses:192.168.89.34/24\n'
                'ipv4.gateway:192.168.89.1\nipv4.dns:192.168.89.1\n',
            stderr: '',
          );
        }
        return const NmcliResult(exitCode: 0, stdout: '', stderr: '');
      });
      final net = NetworkService(nmcli: nm);
      final hs = HotspotService(network: net, nmcli: nm);
      // Pretend active so teardown path runs.
      // ignore: invalid_use_of_visible_for_testing_member
      final r = await hs.reconcile();
      expect(r['uplink'], isTrue);
      expect(r['active'], isFalse);
      expect(downs, greaterThan(0));
    });
  });

  group('NetworkService preferredLanIpv4', () {
    test('prefers ethernet over hotspot wifi', () async {
      final nm = FakeNmcli((args) async {
        final joined = args.join(' ');
        if (joined.contains('device status')) {
          return const NmcliResult(
            exitCode: 0,
            stdout: 'end0:ethernet:connected:Wired\n'
                'wlan0:wifi:connected:comstar-hotspot\n',
            stderr: '',
          );
        }
        if (joined.contains('device show end0') ||
            (joined.contains('connection show') && joined.contains('Wired'))) {
          return const NmcliResult(
            exitCode: 0,
            stdout: 'IP4.ADDRESS[1]:192.168.89.34/24\n'
                'ipv4.method:auto\nipv4.addresses:192.168.89.34/24\n',
            stderr: '',
          );
        }
        if (joined.contains('wlan0') || joined.contains('comstar-hotspot')) {
          return const NmcliResult(
            exitCode: 0,
            stdout: 'IP4.ADDRESS[1]:10.87.65.1/24\n'
                'ipv4.method:shared\nipv4.addresses:10.87.65.1/24\n',
            stderr: '',
          );
        }
        return const NmcliResult(exitCode: 0, stdout: '', stderr: '');
      });
      final net = NetworkService(nmcli: nm);
      final lan = await net.preferredLanIpv4();
      expect(lan.ip, '192.168.89.34');
      expect(lan.hotspot, isFalse);
      expect(await net.hasUplink(), isTrue);
    });
  });
}
