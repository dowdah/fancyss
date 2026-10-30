# Full TLS resource probe (hnd/full)

This is a one-shot test fixture, not a production service. Keep the current
native fancyss stack running. On the router, stage the pinned candidate client,
shared helper, candidate shunt library, sampler and setup/cleanup/expiry scripts
under `/tmp/fss-tls-peak/`. Create a fresh random SOCKS user/pass JSON, mode 0600,
on the router and Pi only; never copy the airport password or SSH private keys
to the Pi. Build sampler.c with the matching static ARMv7 toolchain and strip
symbols. Use the actual package client binary and verify its checksum.

`router-setup.sh` currently describes the authorized lab's LAN addresses; review
those before reuse. It checks the native.1/TW baseline and memory, installs a
Pi-only temporary INPUT rule and password-authenticated SOCKS port, then starts
candidate AnyTLS and a second Xray with the complete candidate domestic policy
and geodata. Production files, DBUS, NAT/TPROXY routing and node selection are
unchanged. Loading the shell library temporarily tolerates its legacy top-level
nonzero statuses, then verifies the required function exists.

The Pi's `driver.py` uses the standard library. It connects through the isolated
proxy, verifies www.google.com's certificate, requests `/generate_204` and keeps
all successfully established TLS sessions alive with requests every five
seconds. This is verified TLS plus real HTTPS traffic with a zero-length body;
it is not a bulk-payload throughput or 128-big-download stress test.

`sampler.c` samples MemAvailable, both processes' RSS/HWM and threads every
250 ms. It independently reads new `/dev/kmsg` records without consuming
`/proc/kmsg` or clearing the kernel ring. Data streams to the workstation, so a
router reboot does not erase already delivered samples. Missing vmstat counters
are -1, never zero. Below 48 MiB available memory, it signals only test PIDs
whose start times and exact test command/config still match. It cannot signal
the native production instance. `--check-crashlog` is a separate read-only byte
count for the previously verified hnd 512 KiB `/dev/mtd3` partition; verify the
partition layout before using that option on any other device.

Set FSS_TLS_ROUTER, FSS_TLS_ROUTER_PORT, FSS_TLS_PI, FSS_TLS_REPORT_DIR, and
optionally FSS_TLS_JUMP_HOST, then run `run-from-workstation.sh`. The workstation
is only a management/receipt transport. HTTPS load originates on the Pi and
exits through the router's same selected TW node. No whole-airport scan occurs.
The runner progresses 1/16/32/64/128 sessions with 30-second holds and records
75 seconds after closing the final load. A failed stage stops progression.

Cleanup signals only matching test instances, removes the exact temporary
firewall rule/chain and deletes test credentials/config. A 15-minute test expiry
performs cleanup even if the management session is lost. No persistent cron,
controller, firmware change, OOM-policy change or router reboot is installed.

Review setup high-water marks as well as steady-state RSS. An isolated pass
with a freshly booted router and two cores is not acceptance of the previous
warm production memory state. Keep raw failed setup/transport receipts separate
from actual TLS test failures, and do not infer a past OOM from a later reboot's
empty log or absent counters.
