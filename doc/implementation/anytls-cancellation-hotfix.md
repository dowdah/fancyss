# AnyTLS cancellation hotfix, 2026-10-29

Build `3.5.30-anytls-native.2-cancel.1`, client `0.1.1`. Repeated router resets remain an unresolved incident. This change fixes two independently reproduced client defects; it does not establish reboot causality or claim long term stability.

The v0.0.11 protocol dependency did not honor the setup context while writing authentication, opening a pooled stream or writing its destination. The wrapper also waited for handlers before closing upstream sessions. Under transport backpressure this could retain connection slots and prevent graceful termination. Three regression cases fail on native.2 and pass with the local patch; existing protocol/TLS/session reuse and race tests pass.

The original dependency source/license is retained under `tool/fss-anytls-client/third_party/sing-anytls`; only client.go, session/client.go and session/stream.go differ. See PATCHES.md. Setup cancellation closes the affected transport, including before a stream has been registered. Successful setup removes cancellation callbacks; no total lifetime deadline is imposed on normal established connections. Shutdown cancels handlers and closes upstream sessions before joining them.

Build with the pinned Go/UPX toolchain using scripts/build_anytls_client.sh and scripts/build_native_cancel1.py. Set FSS_ANYTLS_BUILD_OUT consistently when selecting an alternate output folder. Old native.2 packages are retained. The delta replaces only the client, NOTICE and fork-build metadata; routing, schema, DNS and helper scripts are unchanged.

Production snapshot: `/data/fss-native-cancel1-20261029T2009`. Necessary functional acceptance passed and was confirmed at 20:14:40 local. Rollback: `/bin/sh /data/fss-native-cancel1-20261029T2009/guard.sh rollback`. This restores the fresh native.2 snapshot; it does not revive the old bridge or reset to a stale node receipt. All prior snapshots remain. /data was used to preserve JFFS space; executable replacement occurs only after the verified persistent snapshot, local guard and owned-instance shutdown.

Actual reboot evidence, reproducible tests, candidate hashes and acceptance are in the ignored `local-reports/reboot-diagnosis-20261029/` directory. Reset causes are not known: SW reset is not a caller identity; current normal RAM and short functional success cannot exonerate the fork. No kernel/OOM/watchdog settings were changed and no router reboot or production pressure test was issued.

A further router reset was confirmed at approximately 20:21:50 after this
hotfix. External samples immediately before it recorded available RAM falling
126256→104084→23108 KiB, Xray RSS 48200→58304→102376 KiB and unreclaimable kernel
slab 47228→60176→108400 KiB, while the adapter remained at 8620 KiB. No fatal
kernel line survived transmission. This is concrete transient memory pressure,
not proof of a particular allocation path or an observed OOM kill. Stability
remains unaccepted. Follow-up uses bounded loopback profiling with automatic
removal; no speculative routing or kernel tuning is part of this commit.
