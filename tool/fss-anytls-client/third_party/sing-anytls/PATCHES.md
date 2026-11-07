# Local patches on sing-anytls v0.0.11

Base github.com/anytls/sing-anytls v0.0.11, original checksum retained in parent go.sum. All upstream sources and license retained. The cancellation patch makes contexts interrupt blocked authentication, OpenStream and destination-address writes. A cancelled establishment aborts the owning session transport; Stream.Close alone could block while writing FIN. Successful establishment removes callbacks, so established long connections retain no total lifetime deadline. No node fallback or protocol changes.

These changes fix independently reproduced setup/shutdown defects. They do not establish the cause of router reboots.

Padding updates are validated and budgeted before publication. A session uses one scheme for authentication and record padding, and oversized updates are discarded without allocating the advertised length.

Stream close callbacks are installed before publication. Error state is synchronized,
and a closed transport is excluded from the idle pool during callback execution.
