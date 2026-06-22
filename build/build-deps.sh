#!/usr/bin/env bash
# Build the statically-linked dispatcher dependencies seal bundles
# (SEA-707), for one target arch, inside an Alpine (musl) container.
#
# Produces, under "$OUT_DIR" (default ./out/<arch>/):
#   sh                (dash, static musl)
#   bwrap             (bubblewrap, static musl)
#   xdg-dbus-proxy    (static musl, static GLib)
#   *.sha256          checksum per binary
#   PROVENANCE.txt    exact upstream versions + source sha256s
#
# Why static musl: the bundled binaries run on whatever host the user
# installed seal on, inside seal's own bwrap newroot. A dynamically
# linked build would couple them to the host's glibc + shared GLib —
# exactly the host-version-drift surface SEA-707 deletes. Static musl
# has no runtime loader dependency, so one build runs everywhere.
#
# This script assumes it runs INSIDE an Alpine container with build
# tooling available (the pipeline's `build-deps` step starts the
# container). Run locally with:
#   podman run --rm -v "$PWD:/w" -w /w alpine:3.21 \
#     sh -c 'apk add bash && ARCH=x86_64 bash build/build-deps.sh'
set -euo pipefail

# ─── Pinned upstream versions ─────────────────────────────────────
# Bump deliberately; refresh the source sha256s alongside. The first
# CI run records the resolved values into PROVENANCE.txt — keep these
# in sync with what that run verified.
DASH_VERSION="${DASH_VERSION:-0.5.12}"
DASH_SHA256="${DASH_SHA256:-}"   # set to enforce; empty = record-only
BWRAP_VERSION="${BWRAP_VERSION:-0.11.0}"
XDP_VERSION="${XDP_VERSION:-0.1.6}"

ARCH="${ARCH:-$(uname -m)}"
OUT_DIR="${OUT_DIR:-out/${ARCH}}"
WORK="$(mktemp -d)"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

echo "=== seal-bundled-deps build (arch=${ARCH}, out=${OUT_DIR}) ==="

# ─── Build toolchain (Alpine packages) ────────────────────────────
# meson/ninja for xdg-dbus-proxy; glib-static + its static deps for
# the static-GLib link; build-base for cc/make; the *-static packages
# carry the .a archives the static link needs.
echo "--- apk: build toolchain + static libs"
apk add --no-cache \
    build-base linux-headers pkgconf \
    meson ninja samurai \
    curl tar xz \
    glib-dev glib-static \
    zlib-static \
    libffi-dev \
    pcre2-dev \
    gettext-static \
    musl-dev >/dev/null

provenance="${OUT_DIR}/PROVENANCE.txt"
{
    echo "seal-bundled-deps build provenance"
    echo "arch: ${ARCH}"
    echo "alpine: $(cat /etc/alpine-release 2>/dev/null || echo unknown)"
    echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
} >"$provenance"

# Helper: fetch + verify a source tarball. Records the observed sha256
# into PROVENANCE; enforces the pin when the *_SHA256 var is non-empty.
fetch_verify() {
    local url="$1" dest="$2" want="$3" name="$4"
    curl -fsSL --connect-timeout 10 --max-time 180 --retry 3 --retry-delay 2 -o "$dest" "$url"
    local got
    got="$(sha256sum "$dest" | awk '{print $1}')"
    echo "${name} source: ${url}" >>"$provenance"
    echo "${name} source sha256: ${got}" >>"$provenance"
    if [[ -n "$want" && "$want" != "$got" ]]; then
        echo "FATAL: ${name} source sha256 mismatch: want ${want} got ${got}" >&2
        exit 1
    fi
}

# ─── dash (sh) ────────────────────────────────────────────────────
echo "--- build dash ${DASH_VERSION} (static)"
dash_tar="${WORK}/dash.tar.gz"
fetch_verify \
    "http://gondor.apana.org.au/~herbert/dash/files/dash-${DASH_VERSION}.tar.gz" \
    "$dash_tar" "$DASH_SHA256" "dash"
tar -C "$WORK" -xzf "$dash_tar"
(
    cd "${WORK}/dash-${DASH_VERSION}"
    CFLAGS="-Os -static" LDFLAGS="-static" ./configure --enable-static >/dev/null
    make -j"$(nproc)" >/dev/null
    cp src/dash "${OUT_DIR}/sh"
)
strip "${OUT_DIR}/sh"

# ─── bwrap (bubblewrap) ───────────────────────────────────────────
echo "--- build bubblewrap ${BWRAP_VERSION} (static)"
bwrap_tar="${WORK}/bwrap.tar.xz"
fetch_verify \
    "https://github.com/containers/bubblewrap/releases/download/v${BWRAP_VERSION}/bubblewrap-${BWRAP_VERSION}.tar.xz" \
    "$bwrap_tar" "" "bubblewrap"
tar -C "$WORK" -xf "$bwrap_tar"
(
    cd "${WORK}/bubblewrap-${BWRAP_VERSION}"
    # bwrap links libcap; the static build needs libcap.a. Alpine's
    # libcap-static provides it.
    apk add --no-cache libcap-static libcap-dev >/dev/null
    meson setup build \
        --default-library=static \
        -Dprefer_static=true \
        --buildtype=release \
        -Dc_link_args=-static >/dev/null
    ninja -C build bwrap >/dev/null
    cp build/bwrap "${OUT_DIR}/bwrap"
)
strip "${OUT_DIR}/bwrap"

# ─── xdg-dbus-proxy (static, static GLib) ─────────────────────────
# The fiddliest of the set: GLib's static link pulls pcre2, libffi,
# zlib, gettext (intl). `prefer_static` + `-static` link args force
# the .a archives the *-static apk packages provide.
echo "--- build xdg-dbus-proxy ${XDP_VERSION} (static + static GLib)"
xdp_tar="${WORK}/xdp.tar.xz"
fetch_verify \
    "https://github.com/flatpak/xdg-dbus-proxy/releases/download/${XDP_VERSION}/xdg-dbus-proxy-${XDP_VERSION}.tar.xz" \
    "$xdp_tar" "" "xdg-dbus-proxy"
tar -C "$WORK" -xf "$xdp_tar"
(
    cd "${WORK}/xdg-dbus-proxy-${XDP_VERSION}"
    meson setup build \
        --default-library=static \
        -Dprefer_static=true \
        --buildtype=release \
        -Dc_link_args=-static >/dev/null
    ninja -C build >/dev/null
    cp build/xdg-dbus-proxy "${OUT_DIR}/xdg-dbus-proxy"
)
strip "${OUT_DIR}/xdg-dbus-proxy"

# ─── Verify staticness + record checksums ─────────────────────────
echo "--- verify static linkage"
for b in sh bwrap xdg-dbus-proxy; do
    path="${OUT_DIR}/${b}"
    # `ldd` on a static binary prints "not a dynamic executable" (or
    # errors); a dynamic one lists shared libs. Fail loudly if any
    # binary came out dynamically linked — that would defeat the
    # whole point of bundling.
    if ldd "$path" 2>&1 | grep -qE "=> /|ld-musl|ld-linux"; then
        echo "FATAL: ${b} is dynamically linked:" >&2
        ldd "$path" >&2 || true
        exit 1
    fi
    sha256sum "$path" | awk -v n="$b" '{print $1}' >"${path}.sha256"
    echo "${b} binary sha256: $(cat "${path}.sha256")" >>"$provenance"
done

echo "=== done. artifacts in ${OUT_DIR}:"
ls -la "${OUT_DIR}"
