import 'package:comstar_bridge/attention/machine.dart';
import 'package:comstar_bridge/attention/states.dart';
import 'package:comstar_bridge/log.dart';

/// Runtime invariant checks for the attention machine (CONTRACTS §8).
void assertInvariants(MachineContext ctx, {bool throwOnViolation = true}) {
  final violations = collectInvariantViolations(ctx);
  if (violations.isEmpty) return;

  final message = violations.join('; ');
  if (throwOnViolation) {
    throw StateError('Invariant violation: $message');
  }
  logError('invariant_violation', message);
}

List<String> collectInvariantViolations(MachineContext ctx) {
  final violations = <String>[];

  // Sleeping may keep an AO session open until wake/exit tears it down.
  if (ctx.state is! Sleeping) {
    final sessionStates = ctx.state is Engaged ||
        ctx.state is Listening ||
        ctx.state is Responding;
    final hasSession = ctx.sessionOpen;

    if (hasSession != sessionStates) {
      violations.add(
        'sessionOpen ($hasSession) != state in engaged/listening/responding ($sessionStates)',
      );
    }
  }

  final wakeShouldBeArmed = ctx.state is Sleeping ||
      (ctx.state is! Listening && !(ctx.halfDuplex && ctx.playing));
  if (ctx.wakeEnabled != wakeShouldBeArmed) {
    violations.add(
      'wakeEnabled (${ctx.wakeEnabled}) != expected ($wakeShouldBeArmed)',
    );
  }

  if (ctx.directAgentInFlight && ctx.state is! Responding) {
    violations.add('directAgent in flight outside responding');
  }

  final turnExpected = ctx.state is Listening || ctx.state is Responding;
  if ((ctx.turnId != null) != turnExpected) {
    violations.add(
      'turnId present (${ctx.turnId != null}) != listening/responding ($turnExpected)',
    );
  }

  return violations;
}
