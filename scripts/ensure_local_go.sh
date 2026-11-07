#!/bin/sh
set -eu
GO_BIN=$(command -v go) || { echo "Install Go 1.25.6 before building" >&2; exit 1; }
[ "$("$GO_BIN" version | awk '{print $3}')" = go1.25.6 ] || { echo "Go 1.25.6 is required for locked builds" >&2; exit 1; }
printf '%s\n' "$GO_BIN"
