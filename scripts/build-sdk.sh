#!/bin/bash
# Build a minimal liblinphone SDK for Ring from source: audio only, size-optimised.
# Produces a local Swift package at build/linphone-sdk-min/linphone-sdk-swift-macos, which
# `make small` uses instead of the prebuilt SDK.
#
# Usage: scripts/build-sdk.sh [universal|native|arm64|x86_64]   (default: universal)
#
# Needs: Xcode 15+, Homebrew packages `cmake ninja doxygen yasm nasm`, and the Python modules
# `pystache six` for /usr/bin/python3 (see README). The first build takes a while.
set -euo pipefail

case "${1:-universal}" in
  universal) ARCHS="arm64, x86_64" ;;
  native)    ARCHS="$(uname -m)" ;;
  *)         ARCHS="$1" ;;
esac
VERSION="5.5.41"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/linphone-sdk-src"
OUT="$ROOT/build/linphone-sdk-min"

if [ ! -d "$SRC/.git" ]; then
  echo "Cloning linphone-sdk $VERSION (with submodules)…"
  git clone --recursive --depth 1 --shallow-submodules --branch "$VERSION" \
    https://gitlab.linphone.org/BC/public/linphone-sdk.git "$SRC"
fi

# Everything Ring doesn't use is off. Kept: SIP/TLS (belle-sip, mbedtls), SRTP, G.711, G.722,
# GSM, Opus (also decodes the .mkv ring tone), Speex DSP (resampling, echo canceller), MKV.
cmake --preset=mac-sdk -G Ninja -S "$SRC" -B "$OUT" \
  -DCMAKE_BUILD_TYPE=MinSizeRel \
  -DENABLE_FAT_BINARY=OFF \
  -DLINPHONESDK_MACOS_ARCHS="$ARCHS" \
  -DPython3_EXECUTABLE=/usr/bin/python3 \
  -DENABLE_SWIFT_WRAPPER=ON \
  -DENABLE_SWIFT_WRAPPER_COMPILATION=OFF \
  -DENABLE_VIDEO=OFF \
  -DENABLE_SCREENSHARING=OFF \
  -DENABLE_ADVANCED_IM=OFF \
  -DENABLE_DB_STORAGE=OFF \
  -DENABLE_LIME_X3DH=OFF \
  -DENABLE_XERCESC=OFF \
  -DENABLE_VCARD=OFF \
  -DENABLE_FLEXIAPI=OFF \
  -DENABLE_HIDAPI=OFF \
  -DENABLE_LDAP=OFF \
  -DENABLE_MDNS=OFF \
  -DENABLE_RNNOISE=OFF \
  -DENABLE_ZRTP=OFF \
  -DENABLE_GOCLEAR=OFF \
  -DENABLE_DECAF=OFF \
  -DENABLE_BV16=OFF \
  -DENABLE_BAUDOT=OFF \
  -DENABLE_WEBRTC_AEC=OFF \
  -DENABLE_WEBRTC_VAD=OFF \
  -DENABLE_DAEMON=OFF \
  -DENABLE_TOOLS=OFF \
  -DENABLE_DOC=OFF \
  -DENABLE_TESTS_COMPONENT=OFF \
  -DENABLE_UNIT_TESTS=OFF

cmake --build "$OUT"

PKG="$OUT/linphone-sdk-swift-macos"
if [ -f "$PKG/Package.swift" ]; then
  echo "Done: $PKG"
  du -sh "$PKG" 2>/dev/null || true
else
  echo "Build finished but no Swift package at $PKG; look under $OUT for linphone-sdk-swift-macos." >&2
  exit 1
fi
