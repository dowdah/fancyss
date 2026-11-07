#!/bin/sh
# Build and verify a packed Linux release for the requested architecture.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
OUT=${FSS_ANYTLS_BUILD_OUT:-"$ROOT/artifacts"}
case "${1:-armv7}" in
    armv5) arch=arm; arm=5,softfloat; name=fss-anytls-client-armv5 ;;
    armv7) arch=arm; arm=7,hardfloat; name=fss-anytls-client-hnd ;;
    arm64) arch=arm64; arm=; name=fss-anytls-client-arm64 ;;
    *) echo "usage: $0 [armv5|armv7|arm64]" >&2; exit 1 ;;
esac
[ -n "${FSS_UPX:-}" ] || { echo 'Set FSS_UPX to the verified UPX 5.3.0 executable for a router release.' >&2; exit 1; }
"$FSS_UPX" --version | head -1 | grep -Fx 'upx 5.3.0'
mkdir -p "$OUT"
cd "$ROOT/tool/fss-anytls-client"
go mod verify
CGO_ENABLED=0 GOOS=linux GOARCH="$arch" GOARM="$arm" GOTOOLCHAIN=local \
    go build -mod=readonly -trimpath -ldflags='-s -w -buildid=' -o "$OUT/$name.raw"
case "$arch" in
    arm) pattern='ELF 32-bit.* ARM,' ;;
    arm64) pattern='ELF 64-bit.* (ARM aarch64|AArch64|ARM64),' ;;
esac
file "$OUT/$name.raw" | grep -E "$pattern"
cp "$OUT/$name.raw" "$OUT/$name"
"$FSS_UPX" -9 "$OUT/$name"
"$FSS_UPX" -t "$OUT/$name"
[ -x "$OUT/$name" ] && file "$OUT/$name" | grep -E "$pattern"
sha256sum "$OUT/$name.raw" "$OUT/$name"
