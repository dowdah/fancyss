# Recording body protection companion

`direct-content.patch` applies to an isolated copy of the existing application;
`source-manifest.json` identifies the exact baseline and patched files. Do not
apply blindly to a changed application tree. The original workspace is not edited.

All recording upload kinds use an upload session. Body destinations are validated
before sending bytes; body sessions do not inherit environment proxies and refuse
redirects. Graph/auth/control retain their existing control session. Download
redirect metadata is requested separately from the validated body request, including
bounded ranges and content reconciliation. Unknown hosts and direct failures do
not trigger a proxy or small Graph content upload fallback.

The application still relies on the router's maintained DIRECT domain rules.
It does not bypass a separately configured proxy on an unrelated client receiving
a redirect URL. The upstream OneDrive web player is outside this acceptance scope.

Auth and Graph sessions bind an IPv4 source address so alternate IPv6 DNS answers
cannot bypass the router's IPv4 transparent proxy. The body session remains
independent and dual stack. This requires the native router's proxy policy to
remain enabled for the control domains. It does not change the Pi's DNS servers,
IPv6 addresses, recorder, MediaMTX or live relay.

Stage the manifest, both application files and all deployment/probe scripts before
using the bounded deployment wrapper. It validates source hashes and retains a
separate `fancyss-direct-v1-control-v4` backup of the previously accepted version.
Do not reuse old staging files or confirm from an old health receipt. The original
`fancyss-direct-v1` attempt and any rolled-back network-setting experiments remain
separate audit history; the delivered fix does not depend on those DNS changes.
