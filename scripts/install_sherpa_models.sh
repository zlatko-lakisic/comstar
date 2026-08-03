#!/usr/bin/env bash
# Download sherpa-onnx Moonshine STT + Piper VITS TTS models onto the Pi.
set -euo pipefail

ROOT="${COMSTAR_MODELS:-/opt/comstar/models/sherpa}"
mkdir -p "$ROOT"
cd "$ROOT"

# Default to moonshine-base — tiny hallucinates too often on soft C525 audio.
STT_URL="${COMSTAR_SHERPA_STT_URL:-https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-moonshine-base-en-int8.tar.bz2}"
TTS_URL="${COMSTAR_SHERPA_TTS_URL:-https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-lessac-medium.tar.bz2}"

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
# TTS archive name may vary slightly; pick the extracted piper dir.
tts_dir="$(find . -maxdepth 1 -type d -name 'vits-piper-en_US-lessac*' | head -1)"
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
