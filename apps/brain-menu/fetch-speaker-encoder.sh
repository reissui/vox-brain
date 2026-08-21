#!/usr/bin/env bash
set -euo pipefail
destination="${1:-}"
if [ -z "$destination" ] || [ "${destination#/}" = "$destination" ]; then
  echo "usage: $0 /absolute/output/dir/SpeakerEncoder.mlmodelc" >&2
  exit 64
fi
source_model="${BRAIN_SPEAKER_ENCODER_SOURCE:-}"
if [ -z "$source_model" ]; then
  echo "speaker encoder skipped: set BRAIN_SPEAKER_ENCODER_SOURCE to a SpeakerEncoder.mlmodelc directory" >&2
  exit 0
fi
if [ ! -d "$source_model" ]; then
  echo "error: BRAIN_SPEAKER_ENCODER_SOURCE is not a directory: $source_model" >&2
  exit 66
fi
rm -rf "$destination"
mkdir -p "$(dirname "$destination")"
cp -R "$source_model" "$destination"
expected_sha256="${BRAIN_SPEAKER_ENCODER_SHA256:-}"
if [ -n "$expected_sha256" ]; then
  actual_sha256="$(tar -C "$destination" -cf - . | shasum -a 256 | awk '{print $1}')"
  if [ "$actual_sha256" != "$expected_sha256" ]; then
    echo "error: SpeakerEncoder SHA-256 verification failed" >&2
    exit 65
  fi
fi
