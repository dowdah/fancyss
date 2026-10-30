# Cancellation patch on sing-anytls v0.0.11

Base github.com/anytls/sing-anytls v0.0.11, original checksum retained in parent go.sum. All upstream sources and license retained. Changes are restricted to client.go, session/client.go and session/stream.go: contexts now interrupt blocked authentication, OpenStream and destination-address writes. A cancelled establishment aborts the owning session transport; Stream.Close alone could block while writing FIN. Successful establishment removes callbacks, so established long connections retain no total lifetime deadline. No node fallback or protocol changes.

These changes fix independently reproduced setup/shutdown defects. They do not establish the cause of router reboots.
