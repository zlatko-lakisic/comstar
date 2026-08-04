#!/usr/bin/env bash
# Download sherpa-onnx Moonshine STT + Piper VITS TTS models onto the Pi.
set -euo pipefail

ROOT="${COMSTAR_MODELS:-/opt/comstar/models/sherpa}"
mkdir -p "$ROOT"
cd "$ROOT"

# Default to moonshine-base — tiny hallucinates too often on soft C525 audio.
STT_URL="${COMSTAR_SHERPA_STT_URL:-https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-moonshine-base-en-int8.tar.bz2}"
# lessac-high is the same speaker as medium with noticeably less robotic timbre.
TTS_URL="${COMSTAR_SHERPA_TTS_URL:-https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-lessac-high.tar.bz2}"

fetch() {
  local url="$1"
  local archive
  archive="$(basename "$url")"
  if [[ -f "$archive" ]]; then
    echo "have $archive"
  else
    echo "fetch $url"
    curl -fL --retry 3 -o "$archive" "$url"
  fi
  local dir="${archive%.tar.bz2}"
  if [[ ! -d "$dir" ]]; then
    tar xf "$archive"
  fi
  echo "ready $ROOT/$dir"
}

fetch "$STT_URL"
fetch "$TTS_URL"

# Symlink stable names for systemd units.
ln -sfn sherpa-onnx-moonshine-base-en-int8 stt-moonshine-base
# Keep tiny symlink if present (optional fallback).
[[ -d sherpa-onnx-moonshine-tiny-en-int8 ]] && ln -sfn sherpa-onnx-moonshine-tiny-en-int8 stt-moonshine-tiny
# Prefer lessac-high when present; otherwise any lessac / piper VITS dir.
tts_dir=""
for candidate in vits-piper-en_US-lessac-high vits-piper-en_US-lessac-medium; do
  if [[ -d "$candidate" ]]; then
    tts_dir="$candidate"
    break
  fi
done
if [[ -z "$tts_dir" ]]; then
  tts_dir="$(find . -maxdepth 1 -type d -name 'vits-piper-en_US-lessac*' | head -1)"
fi
if [[ -z "$tts_dir" ]]; then
  tts_dir="$(find . -maxdepth 1 -type d -name 'vits-piper-*' | head -1)"
fi
if [[ -n "$tts_dir" ]]; then
  ln -sfn "$(basename "$tts_dir")" tts-piper
fi

echo "STT -> $ROOT/stt-moonshine-base"
echo "TTS -> $ROOT/tts-piper"
ls -la "$ROOT/stt-moonshine-base" | head
ls -la "$ROOT/tts-piper" | head
