/// Resolve channel sender → COMSTAR userid (static allowlist + QR bindings).
library;

import 'package:comstar_channel/bindings.dart';
import 'package:comstar_channel/identity.dart';

/// Merges static [Allowlist] (Telegram-era bare ids) with [BindingStore].
class IdentityResolver {
  IdentityResolver({
    required this.staticAllowlist,
    required this.bindings,
  });

  final Allowlist staticAllowlist;
  final BindingStore bindings;

  /// Prefer provider-scoped binding; fall back to static bare id (Telegram).
  String? useridFor({
    required String provider,
    required String senderId,
  }) {
    final fromBind = bindings.useridFor(provider, senderId);
    if (fromBind != null) return fromBind;
    if (provider == 'telegram') {
      return staticAllowlist.useridFor(senderId);
    }
    // Prefixed static entries: "whatsapp:+1555…"
    return staticAllowlist.useridFor('$provider:$senderId');
  }

  /// All outbound sender ids for [userid] (static + bindings).
  List<String> senderIdsFor(String userid, {String? provider}) {
    final out = <String>[];
    final seen = <String>{};
    void add(String id) {
      if (seen.add(id)) out.add(id);
    }

    if (provider == null || provider == 'telegram') {
      for (final id in staticAllowlist.senderIdsFor(userid)) {
        // Skip prefixed static keys when listing bare telegram ids.
        if (id.contains(':')) continue;
        add(id);
      }
    }
    for (final b in bindings.bindingsFor(userid)) {
      if (provider != null && b.provider != provider) continue;
      add(b.senderId);
    }
    // Prefixed static: provider:sender
    for (final e in staticAllowlist.entries.entries) {
      if (e.value != userid) continue;
      final key = e.key;
      final i = key.indexOf(':');
      if (i <= 0) continue;
      final prov = key.substring(0, i);
      final sid = key.substring(i + 1);
      if (provider != null && prov != provider) continue;
      add(sid);
    }
    return out;
  }

  bool isLinked(String userid, String provider) =>
      senderIdsFor(userid, provider: provider).isNotEmpty;
}
