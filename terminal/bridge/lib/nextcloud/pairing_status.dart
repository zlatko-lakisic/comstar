/// In-flight Nextcloud Login Flow v2 lifecycle (voice + QR).
enum NextcloudPairingPhase {
  idle,
  awaitingUser,
  verifying,
  linked,
  failed,
}
