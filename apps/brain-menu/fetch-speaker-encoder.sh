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
  # A compiled model is a directory. Hash sorted per-file digests rather than an
  # archive stream so the pin depends only on file names and contents, never on
  # timestamps, ownership, or archive member order.
  actual_sha256="$(
    cd "$destination" &&
      /usr/bin/find . -type f -print0 |
      LC_ALL=C sort -z |
      while IFS= read -r -d '' file; do
        /usr/bin/shasum -a 256 "$file"
      done |
      /usr/bin/shasum -a 256 |
      /usr/bin/awk '{print $1}'
  )"
  if [ "$actual_sha256" != "$expected_sha256" ]; then
    rm -rf "$destination"
    echo "error: SpeakerEncoder SHA-256 verification failed" >&2
    exit 65
  fi
fi
