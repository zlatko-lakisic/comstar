/// Attention states per CONTRACTS §8.
sealed class AttentionState {
  const AttentionState();

  String get name => switch (this) {
        Ambient() => 'ambient',
        Noticed() => 'noticed',
        Engaged() => 'engaged',
        Listening() => 'listening',
        Responding() => 'responding',
        Sleeping() => 'sleeping',
      };
}

final class Ambient extends AttentionState {
  const Ambient();
}

final class Noticed extends AttentionState {
  const Noticed();
}

final class Engaged extends AttentionState {
  const Engaged();
}

final class Listening extends AttentionState {
  const Listening();
}

final class Responding extends AttentionState {
  const Responding();
}

final class Sleeping extends AttentionState {
  const Sleeping();
}
