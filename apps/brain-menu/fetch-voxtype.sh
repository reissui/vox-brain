#!/usr/bin/env bash
# Fetch the exact VoxType build embedded in Brain.app.
set -euo pipefail

version="0.7.5"
asset="voxtype-${version}-macos-universal"
expected_sha256="12e794655f0e0efadceb92e6313cec2c618c571892490368d0b90194cc27cc6e"
download_url="https://github.com/peteonrails/voxtype/releases/download/v${version}/${asset}"
destination="${1:-}"

if [ -z "$destination" ] || [ "${destination#/}" = "$destination" ]; then
  echo "usage: $0 /absolute/output/path" >&2
  exit 64
fi

destination_parent="$(dirname "$destination")"
if [ ! -d "$destination_parent" ]; then
  echo "error: VoxType destination parent does not exist: $destination_parent" >&2
  exit 66
fi

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/brain-voxtype.XXXXXX")"
case "$temporary_root" in
  "${TMPDIR:-/tmp}"/brain-voxtype.*) ;;
  *)
    echo "error: unsafe VoxType temporary directory" >&2
    exit 70
    ;;
esac

cleanup() {
  /usr/bin/find "$temporary_root" -depth -delete >/dev/null 2>&1 || true
}
trap cleanup EXIT

source_binary="${BRAIN_VOXTYPE_BINARY:-}"
if [ -z "$source_binary" ]; then
  source_binary="$temporary_root/$asset"
  /usr/bin/curl \
    --fail \
    --location \
    --silent \
    --show-error \
    --proto '=https' \
    --tlsv1.2 \
    --retry 3 \
    --connect-timeout 15 \
    "$download_url" \
    --output "$source_binary"
fi

if [ ! -f "$source_binary" ] || [ -L "$source_binary" ]; then
  echo "error: VoxType source is not a regular file" >&2
  exit 66
fi

actual_sha256="$(/usr/bin/shasum -a 256 "$source_binary" | /usr/bin/awk '{print $1}')"
if [ "$actual_sha256" != "$expected_sha256" ]; then
  echo "error: VoxType $version SHA-256 verification failed" >&2
  exit 65
fi

binary_size="$(/usr/bin/stat -f '%z' "$source_binary")"
if [ "$binary_size" -lt 1000000 ] || [ "$binary_size" -gt 67108864 ]; then
  echo "error: VoxType binary size is outside Brain's safety bounds" >&2
  exit 65
fi

if ! /usr/bin/lipo "$source_binary" -verify_arch arm64 x86_64 >/dev/null 2>&1; then
  echo "error: VoxType binary is not the expected universal macOS build" >&2
  exit 65
fi

/usr/bin/install -m 0755 "$source_binary" "$destination"
