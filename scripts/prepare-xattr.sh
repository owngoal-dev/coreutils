#!/usr/bin/env bash
#
# Unpack the exact `xattr` crate the lockfile pins and teach it about iOS.
#
# iOS has Darwin's getxattr/setxattr/listxattr/removexattr, byte for byte the
# same as macOS, but the crate's platform table lists only macos. Unpatched, it
# compiles its `unsupported` fallback and every call fails at runtime -- which
# is what `cp -a` reports as
#
#   cp: setting attributes for '...': unsupported platform
#
# Cargo cannot subtract or amend a registry dependency in place, so the source
# is taken from the registry cache (the .crate tarball cargo already verified
# against the lockfile checksum), patched, and handed back through
# `--config patch.crates-io.xattr.path=...`. No fork, no vendored tree: the
# patch applies to a byte-identical copy of the published crate.
#
# Prints the patched source directory on stdout (the last line).

set -Eeuo pipefail

if [[ "$#" -ne 3 ]]; then
    echo "usage: $0 <cargo-root> <cargo-home> <work-dir>" >&2
    exit 64
fi

cargo_root="$1"
cargo_home="$2"
work_dir="$3"
repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
patch_file="$repository_root/patches/dependencies/xattr-0001-support-ios.patch"

[[ -f "$patch_file" ]] || { echo "error: missing $patch_file" >&2; exit 66; }
[[ -f "$cargo_root/Cargo.lock" ]] || { echo "error: no Cargo.lock in $cargo_root" >&2; exit 66; }

version="$(
    awk '
        $0 == "name = \"xattr\"" { in_xattr = 1; next }
        in_xattr && $1 == "version" { gsub(/"/, "", $3); print $3; exit }
    ' "$cargo_root/Cargo.lock"
)"
[[ -n "$version" ]] || { echo "error: Cargo.lock pins no xattr version" >&2; exit 65; }

export CARGO_HOME="$cargo_home"
mkdir -p "$cargo_home" "$work_dir"

# Populate the registry cache if this is a cold build.
tarball=""
for attempt in 1 2; do
    tarball="$(find "$cargo_home/registry/cache" -name "xattr-$version.crate" -print -quit 2>/dev/null || true)"
    [[ -n "$tarball" ]] && break
    ((attempt == 1)) || break
    echo "fetching dependencies to populate the registry cache" >&2
    (cd "$cargo_root" && cargo fetch) >&2
done
[[ -n "$tarball" ]] || {
    echo "error: xattr-$version.crate is not in $cargo_home/registry/cache" >&2
    exit 66
}

source_dir="$work_dir/xattr-$version"
stamp_file="$source_dir/.owngoal-xattr-stamp"
stamp="$(shasum -a 256 "$patch_file" "$tarball" | shasum -a 256 | cut -d ' ' -f 1)"

if [[ -f "$stamp_file" && "$(cat "$stamp_file")" == "$stamp" ]]; then
    printf '%s\n' "$source_dir"
    exit 0
fi

rm -rf -- "$source_dir"
tar -xzf "$tarball" -C "$work_dir"
[[ -d "$source_dir" ]] || { echo "error: $tarball did not unpack to $source_dir" >&2; exit 65; }

git -C "$source_dir" init --quiet
if ! git -C "$source_dir" apply --whitespace=nowarn "$patch_file"; then
    echo "error: $(basename "$patch_file") does not apply to xattr $version" >&2
    echo "       the lockfile moved to a version the patch was not written for" >&2
    exit 65
fi

grep -qF '"macos"; "ios"' "$source_dir/src/sys/mod.rs" || {
    echo "error: patched xattr still does not list ios as supported" >&2
    exit 65
}

printf '%s\n' "$stamp" >"$stamp_file"
echo "patched xattr $version for iOS" >&2
printf '%s\n' "$source_dir"
