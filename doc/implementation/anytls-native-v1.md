# Native AnyTLS shunt implementation

The frontend, shell support checks and node-tool shunt profile accept type 9.
node-tool reuses its existing AnyTLS SOCKS builder. Generated starts/stops invoke
`ss_anytls_helper.sh`; shunt instances use native perp supervision and own their
PID/start identity/password file/listening port. Web tests use separate instances.
The runtime artifact command does not replace the global node JSON cache.

The startup order is airport bootstrap DNS, ordinary DNS, AnyTLS helper readiness,
Xray, then native firewall/status. Failed helpers fail startup. AnyTLS transitions
use the existing complete restart path; hot reload returns before cleanup.
UDP rejection follows each selected AnyTLS routing target, preserving DIRECT and
other protocols. The native status page reports Xray and actual shunt helpers.

Native SmartDNS groups additionally support HTTPS DoH with explicit bootstrap IP
and normal certificate verification. The existing DNS page displays and saves
these items. This is separate from the independent 6053 airport resolver.

Build only the pinned hnd/full package:

```sh
python3 scripts/build_native_v1.py
```

The builder retains the checked-in baseline package's core binaries/rules and
replaces only the listed patch files plus the matching node-tool binary. It emits
full and delta archives and a manifest with per-file and package SHA-256 values.
The delta is intended for guarded deployment preserving the current node database;
the full package follows the normal software-center installer. A fork marker
prevents upstream self-update from overwriting this integration; subscriptions keep
using the native updater.

Run isolated shell/config tests with:

```sh
python3 -m unittest discover -s tests/native-anytls -v
```

Build node-tool with Zig 0.15.2, target `arm-linux-musleabi`, CPU `mpcorenovfp`.
The child fork fixes its exact source commit. Router-side test scripts operate
only on explicit candidates, temporary ports and private temporary artifacts.
Never deploy the tests as a controller or replay a historical bridge rollback.

Without IPv6 transparent proxying, explicit proxy domains suppress AAAA answers.
This includes the `black_list` and `shunt_proxy` sets, even when a broader China
list entry permits AAAA. This prevents authenticated Graph traffic bypassing the
selected IPv4 proxy. Existing control clients must reconnect after changing this
policy; recording-body connections may continue directly over IPv4 or IPv6.
The companion also binds control sessions to IPv4, since clients with alternate
IPv6 resolvers can otherwise bypass the router DNS policy during a DNS restart.

The CameraMonitor companion patch in `integrations/camera-monitor/` separates
control and body sessions. All recording uploads use upload sessions; body hosts
must match the approved HTTPS content domains, environment proxies are disabled,
and redirects cannot silently change the data route. Authentication and Graph
metadata continue through the native network policy. The companion manifest pins
both baseline and patched source hashes. Keep it with future CameraMonitor
releases: replacing those files from the original workspace would remove the
companion change. The original workspace is intentionally not modified.

Deployment scripts capture restricted router-local backups, arm a bounded local
rollback guard, apply only the delta and preserve the node database. Airport DNS
is accepted independently before the fork baseline is captured. The Pi component
has its own backup and confirmation guard; it restarts uploaders/web only. Failed
attempts and their original backups are retained. These scripts are deployment
and rollback tools, not a replacement node controller.

Router cold-boot recovery requires a separately scheduled reboot validation.
Successful plugin restart or node switching does not establish that result.
