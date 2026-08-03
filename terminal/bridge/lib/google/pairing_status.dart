/// In-flight Google device-code pairing lifecycle (voice + QR).
enum GooglePairingPhase {
  /// No active attempt.
  idle,

  /// Device code + QR shown; waiting for the user to approve on another device.
  awaitingUser,

  /// Approval received; writing tokens and (re)starting the Workspace MCP.
  verifying,

  /// Linked for this userid (tokens on disk). Tools may still be warming up.
  linked,

  /// Last attempt failed (timeout / denied / error). Cleared on next connect.
  failed,
}

/// Snapshot for voice / kiosk UX.
class GooglePairingStatus {
  const GooglePairingStatus({
    required this.phase,
    required this.hasTokens,
    required this.toolsReady,
    this.userCode,
    this.lastError,
  });

  final GooglePairingPhase phase;
  final bool hasTokens;
  final bool toolsReady;
  final String? userCode;
  final String? lastError;

  bool get isPairingInFlight =>
      phase == GooglePairingPhase.awaitingUser ||
      phase == GooglePairingPhase.verifying;
}
