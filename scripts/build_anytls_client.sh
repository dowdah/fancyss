#!/bin/sh
# Pinned Linux/ARMv7 client. UPX is optional for development, required for release.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
OUT=${FSS_ANYTLS_BUILD_OUT:-"$ROOT/artifacts"}
mkdir -p "$OUT"
cd "$ROOT/tool/fss-anytls-client"
go mod verify
CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 go build -trimpath -ldflags='-s -w -buildid=' -o "$OUT/fss-anytls-client-hnd.raw"
[ -n "${FSS_UPX:-}" ] || { echo 'Set FSS_UPX to the verified UPX 5.3.0 executable for a router release.' >&2; exit 1; }
"$FSS_UPX" --version | head -1 | grep -Fx 'upx 5.3.0'
cp "$OUT/fss-anytls-client-hnd.raw" "$OUT/fss-anytls-client-hnd"
"$FSS_UPX" -9 "$OUT/fss-anytls-client-hnd"
"$FSS_UPX" -t "$OUT/fss-anytls-client-hnd"
shasum -a 256 "$OUT/fss-anytls-client-hnd.raw" "$OUT/fss-anytls-client-hnd"
