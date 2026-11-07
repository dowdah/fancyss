module github.com/dowdah/fancyss/tool/fss-anytls-client

go 1.23.1

require (
	github.com/anytls/sing-anytls v0.0.11
	github.com/sagernet/sing v0.6.1
	golang.org/x/sys v0.30.0
)

// Base v0.0.11 with bounded establishment cancellation; see third_party/sing-anytls/PATCHES.md.
replace github.com/anytls/sing-anytls => ./third_party/sing-anytls
