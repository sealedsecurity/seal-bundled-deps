# seal-bundled-deps

Statically-linked dispatcher dependencies that the
[`seal`](https://github.com/sealedsecurity/seal) coding agent bundles
into its binary (SEA-707).

## What this is

seal's sandbox dispatcher depends on a handful of binaries —
`sh` (POSIX shell), `bwrap` (the Linux sandbox), and
`xdg-dbus-proxy` (filtered D-Bus session-bus proxy). Resolving those
from the host's `PATH` makes seal's behaviour vary with whatever
version the host happens to ship, and breaks outright when a
`nix-rebuild` moves them mid-session. SEA-707 deletes that variance by
bundling one pinned, statically-linked copy of each into the `seal`
binary and extracting them to `~/.seal/internal/bin/` on first run.

This repo produces those static binaries. It is **separate from the
main `seal` repo on purpose** — its release tags
(`bundled-deps-vN`) would otherwise clutter seal's own Releases page,
and the bundled-dep version history is independent of seal's.

The other two bundled binaries — `seal-netbridge` and `seal-daemon`
— are built from the seal workspace itself, not here.

## Layout

```text
build/build-deps.sh            # builds the three static binaries for one arch
.buildkite/pipelines/release.yml   # matrix build (x86_64 + aarch64) + publish
.buildkite/scripts/publish.sh      # packages per-arch tarball, publishes the release
.buildkite/scripts/gh-app-token.sh # mints the GitHub App token (Contents:write)
```

## How seal consumes it

seal's `release-build.sh` downloads the per-arch
`seal-bundled-deps-<arch>.tar.zst` asset matching its target triple,
verifies the `.sha256`, combines it with the freshly-built
`seal-netbridge` + `seal-daemon`, and embeds the lot into the `seal`
binary via `build.rs`. Each archive's `bin/` layout mirrors
`~/.seal/internal/bin/` exactly, so extraction is a straight unpack.

## Bumping a bundled dependency

1. Edit the pinned version (and, for `dash`, the source `*_SHA256`) at
   the top of `build/build-deps.sh`.
2. Push a new `bundled-deps-vN` tag. The Buildkite pipeline builds
   both arches and publishes the release.
3. In the `seal` repo, bump the `BUNDLED_DEPS_TAG` the release build
   downloads from. A bundled-dep CVE therefore ships as a seal patch
   release — we lean on shipping over hot-fetching, acceptable for
   this low-CVE-surface set.

## Provenance

Every build records exact upstream versions + source sha256s into a
`PROVENANCE.txt` inside each published archive. The build fails if any
binary comes out dynamically linked (`ldd` check) — a dynamically
linked binary would defeat the run-anywhere property the bundling
relies on.

Licenses: dash is BSD-3, bubblewrap is LGPL-2.0+, xdg-dbus-proxy is
LGPL-2.1+ — all permit redistribution. seal ships the license texts
under `~/.seal/internal/licenses/`.
