# Native AnyTLS transport repair (hnd/full)

The fork replaces only the AnyTLS transport adapter with `tool/fss-anytls-client`.
It reuses pinned sing-anytls v0.0.11 and sing v0.6.1. The node schema, subscription
format, native node selection and Xray outbound tags remain compatible.

## Build and verification

Use Go 1.24.4, Linux ARMv7, CGO disabled, trimpath and stripped build IDs.
`scripts/build_anytls_client.sh` requires UPX 5.3.0 and produces packed/unpacked
SHA-256 hashes. The protocol module dependencies are checksum verified. The
release includes source references and GPL/BSD licenses. This revision ships
only hnd/full; other architectures need corresponding builds.

Run `go test -race ./...` in the client directory (local sockets and adequate
file descriptor limits required), then `python3 -m unittest discover -s
 tests/native-anytls -q` from the repository root. `scripts/build_native_v2.py`
requires the exact pinned native.1 full artifact and emits deterministic full
and narrow delta packages. The manifest lists every changed payload file and
client source hash. No rules or unrelated cores are downloaded by packaging.

The adapter admits 256 local TCP clients without a fixed worker queue. SOCKS
negotiation expires after 5 seconds; upstream connection/TLS setup has a
10-second total context. Established sessions have no arbitrary lifetime cap.
Session cleanup/check intervals are 30 seconds with two idle sessions retained.
UDP remains unsupported and explicitly rejected when selected for AnyTLS.

## Native integration and routing

`ss_anytls_helper.sh` verifies PID, process start time, actual backend executable,
password file and listen address. It recognizes an installed old backend when
stopping an owned instance, but startup requires the new backend. Long-lived
perp services belong only to the exact production shunt directory or the
single-node PID path. Web tests use independent short-lived instances, avoiding
service-name collisions with the current node. Status reports the actual engine
and version. Original certificate verification/SNI policy is preserved.

The rule materializer exports each rule independently, then rebuilds the final
DNS union from retained rules. Builtin domestic DIRECT rules use domestic DNS;
recording-body DIRECT rules retain trusted DNS. Native explicit proxy domains
are read from persistent configuration, never from the merged DNS black list.

Transparent policy precedence is configured recording body DIRECT, explicit
proxy domains/IPs, explicit DIRECT domains/IPs, custom node rules, domestic
CN/private DIRECT (mainland ingress only), then the selected default policy.
Service/SOCKS ingress retains its native routing. Unsupported AnyTLS UDP guards
are inserted only after policy generation, at the rules selecting that backend;
they cannot override the earlier domestic or recording DIRECT rules. Domestic
geodata references use the native asset directory. Shell helper execution uses
explicit `/bin/sh` to avoid firmware hardware tools with the same basename.

## Release and rollback

Never use historical bridge receipts. Begin with current read-only identity,
health, resource and native configuration checks. Use router/Pi traffic as
acceptance evidence, not the development computer's WAN.

Stage the final delta under `/tmp/fancyss-native-v2-deploy`, with the final guard
as `guard.sh` and archive file names as `payload-files`. Run the v2 prepare script
to capture the currently running native.1 files and private DBUS locally. It
requires a fresh snapshot directory and budgets the client, snapshot and at
least 2 MiB of remaining flash. Preserve previous failed attempts separately.
The apply script validates hashes, arms a router-local timeout guard, invokes
the old version's stop path and owned helpers, and only then installs files.
It refuses to publish below the flash gate. Restart through native fancyss.

Renew the local guard while checking native UI selection, single-node tests,
cancellation, subscription reconciliation and restart. Verify at least 32 MiB
available RAM during the 128-local-connection test and no OOM. Confirm actual
Graph/auth proxying and a 1 MiB recording body DIRECT transfer with outbound
bytes and the WAN socket; observe natural upload verification as the service
UID. Root must not open the CameraMonitor production database.

After acceptance, use `/bin/sh /jffs/configs/fss-native-v2/guard.sh commit` on the
router. Manual rollback remains `/bin/sh /jffs/configs/fss-native-v2/guard.sh
rollback`; it restores that release's newly captured snapshot. Do not overwrite
or delete the snapshot to make a subsequent release fit.

Phone avatar reproduction remains a device acceptance item. Capture only that
phone's brief DNS/target/outbound correlation when it is available; add only
confirmed misrouted domains to the native DIRECT whitelist. Do not whitelist
shared CDN address ranges or Tencent wholesale. A full router cold boot and
longer stability observation require a separate window.
