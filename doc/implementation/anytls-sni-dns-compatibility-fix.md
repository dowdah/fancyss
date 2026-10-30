# AnyTLS SNI and SmartDNS port compatibility fix

Release: `3.5.30-anytls-native.2-compat.1`, client `0.1.2`.
Source/build commit: `d5c83720dca77a08876985de89b71570615577f2`.
Based on the verified `egress.1` package; its outbound mark 255 and OUTPUT
bypass fix are retained. No node schema, stored configuration or web UI changed.

## Behavior

An omitted AnyTLS SNI now uses the server hostname independently of certificate
verification. Explicit SNI still takes precedence. Go TLS suppresses IP literals
in ClientHello; `--insecure` only disables certificate checks and does not add
fallback/retry without SNI. Existing cancellation and shutdown patches remain.

SmartDNS DoH/DoT configuration encodes non-default ports in the endpoint itself,
never in the unsupported `-port` option. Precedence is explicit endpoint port,
then the separate port field, then protocol default (HTTPS 443, TLS 853).
Defaults may remain implicit. Paths, queries and IPv6 brackets are preserved.
The shared DoT generator follows the same rule. UDP/TCP formatting and the
separate airport path that emits complete upstream URLs are unchanged.

## Tests and build

Before the fix, the ClientHello regression observed an empty SNI in the
insecure/default case. DNS generation failed seven subcases. Both failure
receipts are retained privately. After the fix:

- Full Go tests, race and vet passed with Go 1.24.4, including existing real
  protocol/session reuse and cancellation/shutdown regressions.
- The ClientHello test checks verified/insecure defaults, explicit SNI and
  IPv4/IPv6 suppression. The existing real TLS test rejects an untrusted cert.
- All 22 native Python tests and shell syntax checks passed.
- The shipped ARM64 SmartDNS Release47.1 ran in a network-disabled Linux
  container with synthetic trusted TLS endpoints. DNS answers were correct at
  actual HTTPS ports 443, 853, 8443, explicit-URL 9443, and DoT 8853. Certificate
  verification stayed enabled. Port-generation tests additionally cover IPv6
  and preserved queries. This is offline mechanism evidence, not Mac WAN proof.

Build from the fixed source commit with Go 1.24.4, `CGO_ENABLED=0`, Linux ARMv7
and UPX 5.3.0 using `scripts/build_anytls_client.sh`, then
`scripts/build_native_compat1.py`. Binary VCS metadata records this source
commit with `vcs.modified=false`. The destination router successfully executed
the packed candidate before any production stop.

SHA-256:

| Artifact | SHA-256 |
| --- | --- |
| Raw ARMv7 client | `d8af48487cbe37596f7506eac8ce582cee15fc0fbe3d05091f669064d670da63` |
| Packed ARMv7 client | `0e0f80358b69a69fed88b240b17117d757662e365ca7bce57f397fd03f61471d` |
| Full package | `bf2613bb1b648d9ab867733157aae062930015e18c857ca0ff8da9fcbc4a7d05` |
| Delta package | `949bfbe2c6b30d5c28f9d352b7c2ccc946bee029b263ff69d0e06ec3f29c51e2` |

Full metadata and file hashes are in `artifacts/native-compat1-build.json`.
Private operational receipts are in `local-reports/compat1-20261030/`; credentials
and snapshots stay on the router and are not committed.

## Deployment and rollback

The 2026-10-30 release created a fresh rollback archive of the then-current
`egress.1` binary, scripts, metadata, runtime/DNS configuration and local DBUS.
The first 768 KiB is `/jffs/configs/fss-compat-release-20261030T1430/baseline.000`;
the remainder and private metadata are under
`/data/fss-compat-release-20261030T1430`. The concatenated archive, both part
hashes, extracted payload hashes and guard timeout branch were verified.
All older snapshots remain. Restoration uses both volumes and requires no
external management connection.

The first attempt hit the 2 MiB JFFS gate immediately after replacing files.
It automatically restored `egress.1` at 14:24:51; restored hashes and Google 204
were verified. No router reboot occurred. A bounded retry used the exact
verified restored snapshot and added `sync` after unlink/copy plus a maximum
30-second wait for settled filesystem space, without lowering the gate. The
retry's first post-sync sample had JFFS 2400 KiB/data 2572 KiB free and passed.
Original failure and rollback receipts were retained.

The native plugin started at approximately 14:28, preserving TW node 654, and
passed necessary acceptance at 14:30:09. JFFS had 2396 KiB and data 2556 KiB
free. A final check caught that the generated operational guard had written
its confirmation audit without clearing pending. The task-owned guard was
corrected, its pending-removal branch was tested in a separate router RAM
fixture, and the real pending marker was then cleared. No extra rollback or
core restart occurred during this correction; final confirmation is recorded
in the router audit. The persistent archive was reverified afterward.
Manual emergency rollback to the captured `egress.1` baseline:

```
/bin/sh /data/fss-compat-release-20261030T1430/guard.sh rollback
```

That baseline retains the two compatibility defects, while retaining the
OUTPUT recursion fix. Do not replay older independent-bridge receipts.

## Production acceptance

- All eight installed manifest file hashes matched; client 0.1.2 was confirmed
  by the actual node helper. Core outbound marks and OUTPUT bypass order passed.
- Airport node DNS returned 209.248.40.126 and business DNS resolved Graph.
  Airport config and dnsmasq forward file hashes matched the new snapshot.
- Router SOCKS requests: Google 204/0.316 s, fast.com 200/0.925 s, X static
  favicon 200/0.442 s. These are bounded requests, not a browser performance test.
- Pi service UID: real authentication 200, Graph 200/302; their IPs
  20.190.166.132 and 20.190.144.169 were in black_list/current proxy654.
  Recording 902754 returned HTTP 206 and exactly 1,048,576 bytes. The final WAN
  socket was 100.78.73.132:36900 -> 52.107.238.2:443; DIRECT downlink increased
  from 460 to 1,060,354 bytes. Body-session proxy-environment use remained off.
- Pi was healthy before release, the camera-buffer filesystem was mounted and
  get_throttled was zero. Recorder/live/MediaMTX identities were unchanged.
  SQLite queries were performed only as camera-monitor, never root.

Natural emergency recordings 903418–903422 continued to become verified at
14:30:43–14:30:57; no NEEDS_OPERATOR cases were returned by the service-UID
probe. Pi health/media/live were OK with unchanged media process identities.
The state query logged one 2.651-second SQL operation, retained as a database
latency observation rather than attributed to this network change.

The 14:28:54–14:38:56 read-only observation completed (119 samples). Boot
1146ac85-1892-4dc6-927f-eb3e13dbd42e and Xray PID 24547 stayed unchanged.
Minimum available memory was 97,992 KiB; maximum SUnreclaim 55,120 KiB,
conntrack 648 and Xray RSS 54,140 KiB. There was no observed reboot or the
previous connection/memory avalanche during this bounded window. The actual
pending-removal confirmation was 14:33:12; its RAM fixture test and persistent
archive verification passed.
No whole-router cold boot, smartphone test or long-term stability claim is made.
The historical final OOM/panic/watchdog reset mechanism remains unresolved.

Final read-only check at 14:39:32: same build/node/boot/core PID, pending absent,
no active restore, archive verification passed; JFFS 2396 KiB/data 2564 KiB free,
MemAvailable 102752 KiB. Pi final health/media/live were OK with issues empty
and the original recorder/live/MediaMTX identities unchanged.
