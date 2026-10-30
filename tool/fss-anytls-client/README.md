# Native fancyss AnyTLS transport

Minimal adapter for sing-anytls v0.0.11 and sing v0.6.1, pinned by go.sum.
No node database, DNS controller, subscription parser or automatic fallback.
The hnd/full release uses Linux ARMv7, Go 1.24.4 and UPX 5.3.0. Other platforms
must build their matching binary before enabling this fork's helper.

Use `go test -race ./...` (local loopback sockets and a raised descriptor limit
may be required). Build from the repository root with
`FSS_UPX=/path/to/upx scripts/build_anytls_client.sh`.
The release outputs packed and unpacked SHA-256 hashes. Compression does not
change TLS policy and must be tested on the destination kernel before release.

CLI: `-server host:port --password-file path -l 127.0.0.1:port [-sni name]
[--verify|--insecure]`. TLS verification is the default. Passwords are literal
file bytes; a regular, nonempty private file (0600) is required. Never pass
passwords on the command line. `--ca-file` optionally adds a CA certificate.
`--version` prints the wrapper and protocol library versions.
When SNI is omitted, the server hostname is used even with `--insecure`.
Go TLS omits IP literals from the SNI extension. Disabling certificate checks
does not disable SNI or introduce a retry without SNI.

256 local TCP connections are admitted without a worker queue. Additional
connections close immediately. SOCKS negotiation has a 5-second deadline;
remote dial/TLS has a 10-second total context deadline. Established connections
have no wrapper lifetime limit. Idle sessions are checked every 30 seconds,
expire after 30 seconds, and the pool retains two idle sessions. UDP is rejected.
The native Xray rules must direct domestic UDP before the AnyTLS rejection.

fancyss/perp owns persistent instances through ss_anytls_helper.sh. PID,
/proc start time, actual executable, password file and listen address must all
match before signalling a process. Old and new executable identities are
recognized for stopping an existing instance; startup requires the selected
new binary and never falls back silently. Upgrade must stop the old version's
owned instances before installing new lifecycle scripts.

Licenses: GPL-3.0-or-later (adapter, sing-anytls, sing), BSD-3-Clause (x/sys).
See LICENSE, LICENSE.x-sys and NOTICE. Dependency sources are available through
the module versions in go.mod/go.sum and can be fetched with `go mod download`.
