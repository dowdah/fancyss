# Independent airport bootstrap DNS

The maintained scripts replace the existing `/jffs/scripts/airport-node-dns*.sh`
interfaces. The 6053 resolver remains independent of proxy/business DNS restarts.
`ss_airport_dns_install.sh` adopts an existing configuration, infers the approved
airport identity scope from existing forwarding rules, and installs the scripts.

For the CTC provider, its DNS tutorial also defines `ctcxianyu.com` and
`525536.xyz` as the node suffix scope. The installer adds the verified backup
DoH endpoint with certificate checking enabled. It does not broaden the existing
primary endpoint's certificate exception to other endpoints or HTTPS sites.

Commands:

- `sync`: ensure the owned resolver, atomically synchronize forwarding rules,
  reload dnsmasq only on changes.
- `sync --defer-reload`: allow the caller's normal DNS startup to perform reload.
- `sync --ids-file PATH`: also check only the explicitly required node targets.
- `ensure`: check/create the owned resolver without changing forwarding rules.

Policy is stored locally in `airport-node-dns.identities` and
`airport-node-dns.suffixes`. No credentials or subscription URLs belong in these
files or this repository. Metadata enumeration is not a network scan. Cron and
subscription/startup checks share a bounded lock. Successful cached replies are
reported with `answer_freshness=unknown`, never as proof of a fresh upstream query.
