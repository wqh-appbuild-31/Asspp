#!/bin/sh
# Build libKBSyncBridge.a (iOS arm64) into KBSyncBridge/lib/.
#
# Two parts, following ipatool's own tools/build-ios.sh recipe, adapted for
# a library instead of a jailbroken CLI executable:
#   1. Unicorn Engine 2.1.4, static, guest arch arm64 (the pinned macOS 27
#      storeagent profile is arm64), patched with ipatool's
#      tools/patches/unicorn-ios.patch (W^X mprotect toggling of the TCG
#      translation buffer instead of MAP_JIT/RWX).
#   2. The Go bridge package (vendored ipatool, cmd/kbsyncbridge) built as
#      a c-archive for GOOS=ios/arm64, then merged with libunicorn.a via
#      libtool so the app links exactly one archive. The bridge takes the
#      addresses of core uc_* symbols, which makes the app's static linker
#      extract the Unicorn objects from the merged archive; the app also
#      links with -Wl,-export_dynamic so purego can resolve them again at
#      runtime through dlsym(RTLD_DEFAULT).
#
# Runs on a macOS host with Xcode and a Go toolchain (go.mod pins the Go
# version). In CI this is invoked by .github/workflows/build-ent.yml before
# the app build.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
IPATOOL="$ROOT/ipatool"
OUT="$ROOT/lib"
mkdir -p "$OUT"

for TOOL in cmake curl patch shasum; do
  command -v "$TOOL" >/dev/null 2>&1 || {
    echo "$TOOL is required" >&2
    exit 1
  }
done
command -v go >/dev/null 2>&1 || {
  echo "go is required (see KBSyncBridge/ipatool/go.mod for the version)" >&2
  exit 1
}

SDKROOT=$(xcrun --sdk iphoneos --show-sdk-path)
CC=$(xcrun --sdk iphoneos --find clang)
export SDKROOT CC
export IPHONEOS_DEPLOYMENT_TARGET=15.0
export GOOS=ios GOARCH=arm64 CGO_ENABLED=1

WORK=$(mktemp -d /tmp/kbsync-bridge.XXXXXX)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

# --- Unicorn -------------------------------------------------------------
# Keep this version in sync with internal/sap/unicorn/artifact.go.
curl -fL --retry 3 https://github.com/unicorn-engine/unicorn/archive/refs/tags/2.1.4.tar.gz -o "$WORK/unicorn.tar.gz"
echo "ea8863f095a0136388694e5a6063afd9bb7650e30243dd6251af59c5ce5601f4  $WORK/unicorn.tar.gz" | shasum -a 256 -c -
tar -xzf "$WORK/unicorn.tar.gz" -C "$WORK"
# Use iOS W^X memory protection for Unicorn, including nested Go callbacks.
patch -d "$WORK/unicorn-2.1.4" -p1 < "$IPATOOL/tools/patches/unicorn-ios.patch"
cmake -S "$WORK/unicorn-2.1.4" -B "$WORK/ubuild" \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SDKROOT" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DCMAKE_C_FLAGS='-target arm64-apple-ios15.0' -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF -DUNICORN_ARCH=aarch64 -DUNICORN_BUILD_TESTS=OFF -DUNICORN_INSTALL=OFF
cmake --build "$WORK/ubuild" --parallel "$(sysctl -n hw.ncpu)"

UNICORN_LIBS=$(find "$WORK/ubuild" \( -name 'libunicorn*.a' -o -name 'lib*-softmmu.a' \) -type f)
if ! printf '%s\n' "$UNICORN_LIBS" | grep -q 'libunicorn\.a'; then
  echo "libunicorn.a not found in Unicorn build output:" >&2
  printf '%s\n' "$UNICORN_LIBS" >&2
  exit 1
fi
# The per-guest softmmu archive holds the TCG core (translate-all.c, with
# the patched ipatool_jit_write_protect); without it the app link fails
# with an undefined symbol referenced from uc.c.
if ! printf '%s\n' "$UNICORN_LIBS" | grep -q 'softmmu\.a'; then
  echo "no lib*-softmmu.a found in Unicorn build output:" >&2
  printf '%s\n' "$UNICORN_LIBS" >&2
  exit 1
fi

# --- Go c-archive ---------------------------------------------------------
cd "$IPATOOL"
go build -buildmode=c-archive -trimpath -o "$WORK/libkbsyncbridge.a" ./cmd/kbsyncbridge

# --- Merge ----------------------------------------------------------------
# One archive for the app: Go bridge objects first, then every Unicorn
# archive the cmake build produced (libunicorn.a plus any split libraries).
# shellcheck disable=SC2086
libtool -static -o "$OUT/libKBSyncBridge.a" "$WORK/libkbsyncbridge.a" $UNICORN_LIBS

# Structural check: the merged archive must export the bridge entry points
# and actually contain the Unicorn core symbols.
nm "$OUT/libKBSyncBridge.a" | grep -q ' T _KBSyncGenerate' || {
  echo "merged archive is missing KBSyncGenerate" >&2
  exit 1
}
nm "$OUT/libKBSyncBridge.a" | grep -q ' T _uc_open' || {
  echo "merged archive is missing uc_open (Unicorn merge failed)" >&2
  exit 1
}
nm "$OUT/libKBSyncBridge.a" | grep -q ' T _ipatool_jit_write_protect' || {
  echo "merged archive is missing ipatool_jit_write_protect (softmmu archive not merged)" >&2
  exit 1
}

echo "[+] bridge archive: $OUT/libKBSyncBridge.a"
ls -la "$OUT"
