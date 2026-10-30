#!/bin/sh
sleep 900
ROOT=/tmp/fss-tls-peak
[ -f "$ROOT/setup.complete" ] && [ "$(cat "$ROOT/run-id")" = "$1" ] || exit 0
/bin/sh "$ROOT/router-cleanup.sh"
