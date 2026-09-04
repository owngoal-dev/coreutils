#!/usr/bin/env bash
#
# Stage, ad-hoc sign, and build one .deb from a payload directory that
# build-ios.sh assembled. Called once per bootstrap layout; the payload is the
# same both times, only the install prefix and the architecture label differ.

set -Eeuo pipefail

if [[ "$#" -ne 5 ]]; then
    echo "usage: $0 <payload-dir> <output-deb> <version> <architecture> <install-prefix>" >&2
    echo "note: install-prefix is empty for roothide and /var/jb for rootless" >&2
    exit 64
fi

payload="$1"
output_deb="$2"
version="$3"
architecture="$4"
install_prefix="$5"

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

# shellcheck source=../configuration/upstream.env
source "$repository_root/configuration/upstream.env"

: "${PROGRAM:?}"
: "${UTILS_DIR:?}"
: "${MIN_IOS:?}"
: "${UPSTREAM_REF:?}"

package_id="${PACKAGE_ID:-wiki.qaq.uutils}"
control_template="$repository_root/packaging/DEBIAN/control"
entitlements="$repository_root/packaging/${PROGRAM}.entitlements"
profile_template="$repository_root/packaging/uutils.sh"

for input in "$control_template" "$entitlements" "$profile_template"; do
    [[ -f "$input" ]] || { echo "error: missing packaging input: $input" >&2; exit 66; }
done

[[ -d "$payload" ]] || { echo "error: no payload directory at $payload" >&2; exit 66; }
[[ -f "$payload/usr/bin/$PROGRAM" ]] || { echo "error: payload has no usr/bin/$PROGRAM" >&2; exit 66; }
[[ -d "$payload/$UTILS_DIR" ]] || { echo "error: payload has no $UTILS_DIR" >&2; exit 66; }

[[ "$output_deb" == *.deb ]] || { echo "error: output must end in .deb" >&2; exit 64; }
[[ "$package_id" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || { echo "error: invalid package id" >&2; exit 64; }
[[ "$version" =~ ^[0-9A-Za-z.+:~_-]+$ ]] || { echo "error: invalid version" >&2; exit 64; }
[[ "$architecture" =~ ^[A-Za-z0-9][A-Za-z0-9-]+$ ]] || { echo "error: invalid architecture" >&2; exit 64; }
[[ "$install_prefix" =~ ^(/[A-Za-z0-9][A-Za-z0-9._-]*)*$ ]] || { echo "error: invalid install prefix" >&2; exit 64; }

for tool in ldid dpkg-deb; do
    command -v "$tool" >/dev/null || { echo "error: $tool is not installed" >&2; exit 69; }
done

vtool -show-build "$payload/usr/bin/$PROGRAM" 2>/dev/null | grep -qE '^ *platform (IOS|2)$' || {
    echo "error: $payload/usr/bin/$PROGRAM is not an iOS binary" >&2
    exit 65
}

output_name="$(basename "$output_deb")"
mkdir -p "$(dirname "$output_deb")"
output_directory="$(cd -- "$(dirname -- "$output_deb")" && pwd -P)"
output_deb="$output_directory/$output_name"

staging="$(mktemp -d "${TMPDIR:-/tmp}/${PROGRAM}-deb.XXXXXX")"
temporary_deb="$output_directory/.$output_name.tmp.$$"
signed_entitlements="$(mktemp "${TMPDIR:-/tmp}/${PROGRAM}-entitlements.XXXXXX")"
trap 'rm -rf -- "$staging"; rm -f -- "$temporary_deb" "$signed_entitlements"' EXIT
chmod 0755 "$staging"

debian="$staging/DEBIAN"
installed_root="$staging$install_prefix"
installed_binary="$installed_root/usr/bin/$PROGRAM"
installed_profile="$installed_root/etc/profile.d/uutils.sh"
mkdir -p "$debian" "$installed_root" "$(dirname "$installed_profile")"

# The payload is already laid out as usr/...; the whole tree moves under the
# bootstrap prefix. ditto keeps the per-utility symlinks as symlinks. Nothing in
# the tree names a path, so no substitution is needed inside it.
/usr/bin/ditto "$payload" "$installed_root"

# The profile snippet only exports the directory; it does not touch PATH. Going
# through uutils has to be the user's decision, because usr/bin here still holds
# the GNU coreutils that apt, dpkg and Sileo depend on.
sed -e "s|@PREFIX@|$install_prefix|g" -e "s|@UTILS_DIR@|$UTILS_DIR|g" \
    "$profile_template" >"$installed_profile"
if grep -q '@[A-Z_]*@' "$installed_profile"; then
    echo "error: $installed_profile still holds an unsubstituted placeholder" >&2
    exit 65
fi
grep -qF "$install_prefix/$UTILS_DIR" "$installed_profile" || {
    echo "error: profile snippet does not name $install_prefix/$UTILS_DIR" >&2
    exit 65
}

find "$installed_root" -type d -exec chmod 0755 {} +
find "$installed_root" -type f -exec chmod 0644 {} +
chmod 0755 "$installed_binary"

# RootHide presents its randomized jbroot as / to the shell, but a plain binary
# opens the real iOS root. For file utilities that is not a detail: `ls /etc`
# has to mean what the shell means. RootHide's own tool rewrites the
# path-related imports; rootless resolves /var/jb literally and must not have it.
is_roothide=false
[[ "$architecture" == iphoneos-arm64e ]] && is_roothide=true

if $is_roothide; then
    symredirect="$("$repository_root/scripts/prepare-symredirect.sh" "$repository_root/build/symredirect")"
    "$symredirect" "$installed_binary"
    otool -L "$installed_binary" | grep -qF '@loader_path/.jbroot/usr/lib/libvrootapi.dylib' || {
        echo "error: roothide binary does not load libvrootapi after symredirect" >&2
        exit 65
    }
else
    if otool -L "$installed_binary" | grep -qF 'libvrootapi.dylib'; then
        echo "error: rootless binary unexpectedly loads libvrootapi" >&2
        exit 65
    fi
fi

# symredirect rewrites import table entries, so re-prove the fork gate on the
# bytes that actually ship.
if nm -m "$installed_binary" | grep -qE 'external _(fork|vfork)( |$)'; then
    echo "error: staged binary carries a fork symbol" >&2
    nm -m "$installed_binary" | grep -E 'external _(fork|vfork)( |$)' >&2
    exit 65
fi

# Signing is last: symredirect rewrites the Mach-O, so it has to run first.
ldid -S"$entitlements" -Cadhoc "$installed_binary"

require_true() {
    [[ "$(/usr/libexec/PlistBuddy -c "Print :$1" "$signed_entitlements" 2>/dev/null || true)" == true ]] || {
        echo "error: signed binary is missing entitlement: $1" >&2
        exit 65
    }
}
ldid -e "$installed_binary" >"$signed_entitlements"
require_true platform-application
require_true com.apple.private.security.no-sandbox
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.private.security.container-required' \
    "$signed_entitlements" 2>/dev/null || true)" == false ]] || {
    echo "error: $installed_binary needs com.apple.private.security.container-required = false" >&2
    exit 65
}

installed_size="$(du -sk "$installed_root" | awk '{print $1}')"
upstream_label="${UPSTREAM_REPO##*/}@${UPSTREAM_REF:0:12}"
sed \
    -e "s|@PACKAGE_ID@|$package_id|g" \
    -e "s|@VERSION@|$version|g" \
    -e "s|@ARCHITECTURE@|$architecture|g" \
    -e "s|@INSTALLED_SIZE@|$installed_size|g" \
    -e "s|@MIN_IOS@|$MIN_IOS|g" \
    -e "s|@UPSTREAM@|$upstream_label|g" \
    -e "s|@UTILS_PATH@|$install_prefix/$UTILS_DIR|g" \
    "$control_template" >"$debian/control"
chmod 0644 "$debian/control"
if grep -q '@[A-Z_]*@' "$debian/control"; then
    echo "error: control still holds unsubstituted placeholders:" >&2
    grep -n '@[A-Z_]*@' "$debian/control" | sed 's/^/       /' >&2
    exit 65
fi

# This package coexists with the GNU coreutils the bootstrap ships. Declaring
# any of these would make apt remove it, and apt, dpkg and Sileo depend on it.
for field in Provides Conflicts Replaces; do
    if grep -q "^$field:" "$debian/control"; then
        echo "error: control declares $field; this package must not replace GNU coreutils" >&2
        exit 65
    fi
done

dpkg-deb --root-owner-group -Zzstd -b "$staging" "$temporary_deb" >/dev/null

[[ "$(dpkg-deb -f "$temporary_deb" Package)" == "$package_id" ]]
[[ "$(dpkg-deb -f "$temporary_deb" Version)" == "$version" ]]
[[ "$(dpkg-deb -f "$temporary_deb" Architecture)" == "$architecture" ]]
contents="$(dpkg-deb --contents "$temporary_deb")"
for path in \
    "$install_prefix/usr/bin/$PROGRAM" \
    "$install_prefix/etc/profile.d/uutils.sh" \
    "$install_prefix/$UTILS_DIR/ls" \
    "$install_prefix/$UTILS_DIR/timeout" \
    "$install_prefix/$UTILS_DIR/["; do
    grep -qF ".$path" <<<"$contents" || {
        echo "error: package is missing $path" >&2
        exit 65
    }
done

# Nothing outside these three paths, so an install can never shadow usr/bin.
# Field 6 is the entry's own path for both files and symlinks; $NF would be the
# symlink target.
stray="$(awk '$1 !~ /^d/ {print $6}' <<<"$contents" |
    grep -vE "^\.$install_prefix/(usr/bin/$PROGRAM|etc/profile\.d/uutils\.sh|$UTILS_DIR/)" || true)"
[[ -z "$stray" ]] || {
    echo "error: package installs files outside $UTILS_DIR:" >&2
    sed 's/^/       /' <<<"$stray" >&2
    exit 65
}

utility_count="$(awk '$1 !~ /^d/ {print $6}' <<<"$contents" |
    grep -cF ".$install_prefix/$UTILS_DIR/" || true)"
mv -f "$temporary_deb" "$output_deb"
echo "packaged $package_id $version ($architecture, prefix '${install_prefix:-/}'): $output_deb"
echo "  $utility_count utilities symlinked into $install_prefix/$UTILS_DIR"
shasum -a 256 "$output_deb"
