# Source-only repository and release process

The repository tracks source, canonical rule text, licenses and locked input metadata.
The public repository currently provides source only. Build caches live in
`.cache/` and completed packages live in `packages/`. Git ignores both directories.

## Build

Use Linux with Docker, or install Go 1.25.6, Python 3.11+, GNU coreutils and awk, jq,
file, git and tar. The locked UPX 5.3.0 executable is fetched automatically.

```sh
git clone https://github.com/dowdah/fancyss.git
cd fancyss
python3 scripts/check_submodules.py
docker build -t fancyss-build -f scripts/Dockerfile.build scripts
docker run --rm -v "$PWD:/source" fancyss-build bash -ec '
  git config --global --add safe.directory /source
  bash build.sh --offline
'
```

The legacy input downloads are unavailable. The lock retains the original URLs
and checksums for provenance. An offline build requires the complete input,
rule-compiler and Go-module caches from a prior successful build. If those
caches are missing, a fresh build is unavailable until replacement inputs
are published.
`FSS_CACHE_DIR` selects an alternative cache. Existing `FSS_UPX` and
`FSS_ANYTLS_BUILD_OUT` overrides remain available.

Every build creates all seven platform profiles, full/lite release packages and
full debug packages. Source files are copied into a temporary staging directory.
Only a successful matrix replaces `packages/`. A process lock prevents concurrent
builds from replacing the same outputs. `SHA256SUMS` and `release.json` identify
the resulting packages and their source/input revisions.

To update a dependency, publish a new, versioned input asset and update
`build-inputs.lock.json` with its SHA-256 and per-file inventory. Preserve pinned
assets. Record upstream source commits and retain component licenses. Public
submodule URLs and gitlink commits must agree with the lock. Rebuild and test the
complete matrix before committing an input change. Canonical legacy lists are the uncompressed
`rules_ng/{gfwlist,chnlist,adslist}` files. Their updater refreshes these text
files; packaging creates the gzip copies only in staging.

## Releases

Once replacement build inputs are available and source checks pass, create a
release tag matching the source version. The workflow builds online and offline
and creates a draft Release. Inspect its hashes and
install on a test device before manually publishing. Keep dependency releases
excluded from Latest. The installed fork continues to block upstream self-update;
upgrade routers with matching offline packages.

## Existing clones and upstream updates

History was rewritten to remove generated assets. Keep the migration backup and
old/new commit mapping outside the repository. Re-clone before pushing further
work. Transfer outstanding source changes as patches onto the rewritten history.
Review upstream changes as source patches; merging the original upstream ancestry
can reintroduce its binary history. CI checks source files and newly introduced
Git objects to prevent this recurrence.

The standalone repository starts from a clean source snapshot. Historical pull
requests and releases belonged to the old fork. Copies of old Git objects may
remain available through its upstream fork network.
