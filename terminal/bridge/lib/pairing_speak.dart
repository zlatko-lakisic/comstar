/// Speakable pairing codes (shared with Google-style UX).
library;

class PairingManagerSpeak {
  static String speakable(String code) {
    final cleaned = code.replaceAll('-', '').toUpperCase();
    return cleaned.split('').join(' ');
  }
}
