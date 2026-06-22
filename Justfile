# seal-bundled-deps Justfile.
#
# The only recipe here is `release`, which cuts a `bundled-deps-vN`
# tag. Pushing that tag triggers `.buildkite/pipelines/release.yml`,
# which builds the static dispatcher deps for x86_64 + aarch64 and
# publishes them as a GitHub Release that seal's own release build
# consumes.

# Default: show the recipe list.
default:
    @just --list

# Cut a bundled-deps release.
#
# Unlike a normal app release there's nothing to version-bump in the
# tree — the bundled dependency versions are pinned in
# `build/build-deps.sh` and recorded in each archive's PROVENANCE.txt.
# So this recipe just validates state, tags the current tip, advances
# `main`, and pushes both (the tag push fires the pipeline).
#
# Bump a bundled dependency by editing the pinned version(s) in
# `build/build-deps.sh`, landing that on `main`, then cutting the next
# tag here.
#
# Tag format: `bundled-deps-vN` (e.g. `bundled-deps-v1`). Pass either
# the full tag or just the number:
#   just release v1   →  bundled-deps-v1
#   just release 2    →  bundled-deps-v2
#   just release bundled-deps-v3
#
# Adapted from ~/repos/zireael's `release` recipe; simplified because
# there are no Cargo / package.json / Homebrew versions to bump.
[doc('Cut a bundled-deps release: validate, tag, advance main, push.')]
release VERSION:
    #!/usr/bin/env bash
    set -euo pipefail

    raw="{{ VERSION }}"
    # Normalize: accept `bundled-deps-vN`, `vN`, or bare `N`.
    case "$raw" in
        bundled-deps-v*) tag="$raw" ;;
        v[0-9]*)         tag="bundled-deps-$raw" ;;
        [0-9]*)          tag="bundled-deps-v$raw" ;;
        *)
            echo "error: VERSION must be bundled-deps-vN, vN, or N (got: $raw)" >&2
            exit 1
            ;;
    esac
    if [[ ! "$tag" =~ ^bundled-deps-v[0-9]+$ ]]; then
        echo "error: resolved tag '$tag' is not bundled-deps-vN" >&2
        exit 1
    fi

    # Require a clean working copy — a release should tag exactly
    # what's committed, not drag along uncommitted edits.
    if [ -n "$(jj diff --summary --ignore-working-copy 2>/dev/null)" ]; then
        echo "error: working copy @ has uncommitted changes; finalize them first" >&2
        exit 1
    fi

    # Require `main` to be an ancestor of `@` so the tag lands on top
    # of (or at) main, and advancing main forward is well-defined.
    if ! jj --ignore-working-copy log -r "main & ::@" -T 'change_id' --no-graph 2>/dev/null | grep -q .; then
        echo "error: @ is not a descendant of main (run \`jj rebase -d main\` first)" >&2
        exit 1
    fi

    # Refuse to re-tag an existing version.
    if jj --ignore-working-copy tag list -T 'name ++ "\n"' 2>/dev/null | grep -qx "$tag"; then
        echo "error: tag $tag already exists" >&2
        exit 1
    fi

    # Tag whichever commit is the tip being released. `@` is normally
    # an empty working-copy commit on top of the content; tag its
    # parent if `@` itself is empty, else tag `@`.
    if [ -z "$(jj diff -r @ --summary --ignore-working-copy 2>/dev/null)" ] \
        && jj --ignore-working-copy log -r '@ & empty()' -T 'change_id' --no-graph 2>/dev/null | grep -q .; then
        target="@-"
    else
        target="@"
    fi

    echo "==> Tagging $target with $tag..."
    jj tag set "$tag" -r "$target"
    echo

    echo "==> Advancing main to $target..."
    jj bookmark set main -r "$target"
    echo

    echo "==> Exporting refs to git..."
    jj --ignore-working-copy git export >/dev/null 2>&1 || true
    echo

    echo "==> Pushing main..."
    jj git push -b main
    echo

    echo "==> Pushing tag $tag (triggers the release pipeline)..."
    jj-hp push-tags "$tag"
    echo

    echo "✅ Done. The Buildkite pipeline builds + publishes the release for $tag."
