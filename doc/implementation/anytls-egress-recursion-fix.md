# Native shunt egress recursion fix (egress.1)

The native.2 domain-based DIRECT policy exposed an interaction with existing
router-IP interception. A DIRECT destination sharing an IP with a forced-router
DNS entry could leave Xray and immediately be redirected by nat OUTPUT back to
port 3333. Its original destination is still port 443, so Xray's TCP self-loop
check for its own listening address does not reject this route.

On 2026-10-29 at 22:00, passive production evidence captured 1,013 local 3333
sockets and 1,012 remote sockets to the same Google IP, almost all owned by
Xray. Conntrack paired original WAN-to-Google:443 with the redirected reply
127.0.0.1:3333; that destination belonged to the router ipset. Goroutine profiles
showed hundreds of dokodemo -> freedom DIRECT stacks. This establishes the
recursive routing defect and resource amplification. It does not establish
whether the earlier final resets were OOM, panic or watchdog; no fatal stack
was captured. The exact initial TLS hostname was not recorded.

## Patch contract

`ss_node_shunt.sh` sets SO_MARK 255 on all generated non-blackhole core
outbounds while preserving other stream settings. `ssconfig.sh` adds a full-mask
mark-255 RETURN in IPv4 and IPv6 nat/mangle OUTPUT before router-set capture.
The native SHADOWSOCKS/SHADOWSOCKS6 comments include these rules in existing
stop/mode-change cleanup. Mark 255 was checked against the live routing rules.
The mark is reserved for core-generated sockets; it does not change LAN routing
or turn recording DIRECT traffic into proxy traffic.

Only these two scripts and build metadata changed in production. AnyTLS client
0.1.1, TW node 654, airport DNS, native UI/schema and monitor policy remain.

## Verification and release

21 native regression tests passed. An isolated Linux network namespace using
Xray 26.6.1 ARM64 reproduced OUTPUT recursion from a single TLS request (63
redirects, FD 8 -> 256; bounded abort). With the mark/bypass fix, the same
request completed TLS 1.3/HTTP 204 with FD 8 and exactly one original redirect
plus one marked RETURN. The initial ARMv7 emulated NAT fixture failed with a
connection reset and is retained; it is not counted as passing verification.
The actual ARMv7 router recursion was established by passive production data.

Production build `3.5.30-anytls-native.2-egress.1` started 22:41:48 and was
confirmed 22:46:16 after these checks:

- All eight manifest file hashes matched; generated core marks were 255 and
  OUTPUT bypass preceded capture. Live bypass counter advanced.
- Router SOCKS HTTPS: Google 204, fast.com 200, X static asset 200.
- Pi service UID: real auth 200, Graph 200/302, recording 891939 range 206,
  exactly 1,048,576 bytes. Final WAN socket 100.78.73.132 -> 52.107.238.33:443
  matched DIRECT downlink 1,059,896 bytes; auth/Graph IPs were in black_list and
  proxy654 counters advanced. No proxy fallback for body was enabled.
- Pi health/media/live were OK; router boot ID unchanged. JFFS 3,084 KiB and
  data 3,524 KiB free, MemAvailable 131,380 KiB at confirmation.
- Temporary 10086 profile listener, metrics field and profile pending marker
  were removed during the native restart/owned guard cleanup.

A bounded Pi request pinned to the previous Google IP timed out. That IP was
no longer in the regenerated router set, so it is not a successful production
DIRECT/forced-IP-overlap TLS test. The isolated regression proves that
mechanism; production overlap TLS success remains unverified. No smartphone
or long-term stability acceptance is claimed, and no whole-router reboot was
performed.

Build with `python3 scripts/build_native_egress1.py` from the retained verified
cancellation.1 full archive. Artifact manifest: `artifacts/native-egress1-build.json`.
The build-time manifest records offline validation; production results are
recorded here separately. All original failure receipts and snapshots remain.

Fresh router-local snapshot: `/data/fss-egress-release-20261029T2230`.
The five-minute local rollback was armed before stopping the old instance and
confirmed after necessary acceptance. Manual rollback, if explicitly needed:

```
/bin/sh /data/fss-egress-release-20261029T2230/guard.sh rollback
```

This restores the captured cancellation.1 baseline, which still contains the
recursion defect. It is an emergency recovery entry, not a preferred operating
version. Never use historical independent-bridge ACTIVE receipts.
