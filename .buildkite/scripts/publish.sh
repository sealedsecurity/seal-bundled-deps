#!/usr/bin/env bash
# Package the per-arch static binaries built by build-deps.sh into
# `seal-bundled-deps-<arch>.tar.zst` and publish them to a
# `bundled-deps-<tag>` GitHub Release on sealedsecurity/seal-bundled-deps.
#
# seal's own release-build.sh downloads the per-arch tarball matching
# its target, verifies the checksum, and embeds it into the `seal`
# binary (SEA-707).
#
# Env contract (set by the pipeline):
#   BUNDLED_DEPS_TAG   release tag, e.g. bundled-deps-v1
#   ARCHES             space-separated arch list whose out/<arch>/
#                      dirs exist (e.g. "x86_64 aarch64")
# Auth: GH_APP_ID + GH_APP_PRIVATE_KEY_B64 (from secret-env); this
# script installs a pinned gh, mints the App token, and exports it.
set -euo pipefail

# Resolve the release tag. Normally set via the pipeline `env:` from
# ${BUILDKITE_TAG} (a real tag push). Fall back to ${BUILDKITE_BRANCH}
# so a manual UI build on a `bundled-deps-vN` branch also works — the
# namespace check below rejects anything that isn't a real release tag.
BUNDLED_DEPS_TAG="${BUNDLED_DEPS_TAG:-${BUILDKITE_BRANCH:-}}"
if [[ ! "$BUNDLED_DEPS_TAG" =~ ^bundled-deps-v[0-9]+$ ]]; then
    echo "FATAL: release tag '${BUNDLED_DEPS_TAG}' must match bundled-deps-vN" >&2
    echo "       (set BUNDLED_DEPS_TAG, push a bundled-deps-vN tag, or run from such a branch)" >&2
    exit 1
fi
ARCHES="${ARCHES:-x86_64 aarch64}"
REPO="sealedsecurity/seal-bundled-deps"
here="$(dirname "$0")"

# Pinned, SHA256-verified gh — never an ambient binary (this path
# publishes release assets). Bump + refresh hashes from the release's
# gh_<ver>_checksums.txt.
GH_VERSION=2.94.0
GH_SHA256_AMD64=a757f1ba6db18f4de8cbadb244843a5f89bc75b5e7c6fc127d2bd77fbd12ed62
GH_SHA256_ARM64=705a23b70b0f1b7ba4c302fdcef392ce3edaacfa7ce8e85e4d93d72ea800a538
echo "--- :github: install gh ${GH_VERSION}"
case "$(uname -m)" in
x86_64) gh_arch=amd64 gh_sha="${GH_SHA256_AMD64}" ;;
aarch64 | arm64) gh_arch=arm64 gh_sha="${GH_SHA256_ARM64}" ;;
*)
    echo "unsupported arch $(uname -m)" >&2
    exit 1
    ;;
esac
bin_dir="$(mktemp -d)"
tarball="$(mktemp)"
curl -fsSL --connect-timeout 10 --max-time 120 --retry 3 --retry-delay 2 -o "${tarball}" \
    "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${gh_arch}.tar.gz"
echo "${gh_sha}  ${tarball}" | sha256sum --check --strict
tar -xz --strip-components=2 -C "${bin_dir}" -f "${tarball}" "gh_${GH_VERSION}_linux_${gh_arch}/bin/gh"
rm -f "${tarball}"
export PATH="${bin_dir}:${PATH}"
gh --version

echo "--- :key: mint GitHub App token"
GH_TOKEN="$(GH_APP_REPO="$REPO" bash "${here}/gh-app-token.sh")"
export GH_TOKEN

mkdir -p dist
for arch in $ARCHES; do
    src="out/${arch}"
    base="seal-bundled-deps-${arch}"
    # The build step (build-deps.sh, in Alpine) already produced the
    # final archive + its checksum — zstd lives in apk there, not on
    # this bare host agent. Just collect them for upload.
    if [[ ! -f "${src}/${base}.tar.zst" ]]; then
        echo "FATAL: ${src}/${base}.tar.zst not found — build step must run for ${arch} first" >&2
        exit 1
    fi
    cp "${src}/${base}.tar.zst" "${src}/${base}.tar.zst.sha256" dist/
done

echo "--- :github: publish ${BUNDLED_DEPS_TAG}"
ls -la dist/
if gh release view "${BUNDLED_DEPS_TAG}" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "${BUNDLED_DEPS_TAG}" --repo "$REPO" --clobber \
        dist/seal-bundled-deps-*.tar.zst dist/seal-bundled-deps-*.tar.zst.sha256
else
    gh release create "${BUNDLED_DEPS_TAG}" --repo "$REPO" \
        --title "${BUNDLED_DEPS_TAG}" \
        --notes "Static dispatcher dependencies bundled into seal (SEA-707). See PROVENANCE.txt inside each archive for exact upstream versions + source checksums." \
        dist/seal-bundled-deps-*.tar.zst dist/seal-bundled-deps-*.tar.zst.sha256
fi
