#!/usr/bin/env bash
#
# Stage, ad-hoc sign, and build one .deb from a payload directory that
# build-ios.sh assembled. Called once per bootstrap layout; the payload is the
# same both times, only the install prefix, the architecture label and whether
# RootHide's symredirect rewrites the binary differ.

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
: "${MIN_IOS:?}"
: "${UPSTREAM_REF:?}"

package_id="${PACKAGE_ID:-wiki.qaq.uutils}"
control_template="$repository_root/packaging/DEBIAN/control"
entitlements="$repository_root/packaging/${PROGRAM}.entitlements"
profile_template="$repository_root/packaging/profile.d/coreutils.sh"
getent_template="$repository_root/packaging/getent.sh"
preinst_template="$repository_root/packaging/DEBIAN/preinst"
postrm_template="$repository_root/packaging/DEBIAN/postrm"

for input in "$control_template" "$entitlements" "$profile_template" "$getent_template" \
    "$preinst_template" "$postrm_template"; do
    [[ -f "$input" ]] || { echo "error: missing packaging input: $input" >&2; exit 66; }
done

[[ -d "$payload" ]] || { echo "error: no payload directory at $payload" >&2; exit 66; }
[[ -f "$payload/usr/bin/$PROGRAM" ]] || { echo "error: payload has no usr/bin/$PROGRAM" >&2; exit 66; }
[[ -L "$payload/usr/bin/ls" ]] || { echo "error: payload has no usr/bin/ls symlink" >&2; exit 66; }

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
installed_profile="$installed_root/etc/profile.d/coreutils.sh"
installed_getent="$installed_root/usr/bin/getent"
mkdir -p "$debian" "$installed_root" "$(dirname "$installed_profile")"

# The payload is already laid out as usr/bin/...; the whole tree moves under the
# bootstrap prefix. ditto keeps the per-utility symlinks as symlinks. Nothing in
# it names a path: the utilities are symlinks to a sibling and the binary reads
# no files of its own.
/usr/bin/ditto "$payload" "$installed_root"

# Same path and content the GNU coreutils package used, so a login shell behaves
# the way it did. Taking the file over is what Replaces: coreutils is for.
/usr/bin/ditto "$profile_template" "$installed_profile"

# getent is not a uutils utility, but the GNU package this replaces carried
# Procursus' build of it and the shells look it up. Ship a stand-in rather than
# quietly removing it.
sed -e "1s|^#!/bin/sh$|#!$install_prefix/bin/sh|" \
    -e "s|@PACKAGE_ID@|$package_id|g" "$getent_template" >"$installed_getent"
head -n1 "$installed_getent" | grep -qxF "#!$install_prefix/bin/sh" || {
    echo "error: getent interpreter does not match package layout" >&2
    exit 65
}
if grep -q '@[A-Z_]*@' "$installed_getent"; then
    echo "error: getent stand-in still holds an unsubstituted placeholder" >&2
    exit 65
fi
bash -n "$installed_getent" || { echo "error: getent stand-in does not parse" >&2; exit 65; }

find "$installed_root" -type d -exec chmod 0755 {} +
find "$installed_root" -type f -exec chmod 0644 {} +
chmod 0755 "$installed_binary" "$installed_getent"

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

# symredirect rewrites import table entries, so re-prove the gates on the bytes
# that actually ship.
"$repository_root/scripts/verify-process-symbols.sh" "$installed_binary"

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
require_true com.apple.private.security.storage.AppBundles
require_true com.apple.private.security.storage.AppDataContainers
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
    "$control_template" >"$debian/control"
chmod 0644 "$debian/control"
if grep -q '@[A-Z_]*@' "$debian/control"; then
    echo "error: control still holds unsubstituted placeholders:" >&2
    grep -n '@[A-Z_]*@' "$debian/control" | sed 's/^/       /' >&2
    exit 65
fi

# The takeover has to be declared, and each of these three fields is load-bearing
# in a different direction.
#
# Replaces: coreutils   lets dpkg unpack these files *over* the GNU package's
#                       copies and hand the paths over, with nothing deleted, so
#                       rm never leaves PATH. This is the whole mechanism.
# Conflicts: coreutils  is the front door lock. Resolving this package from a
#                       repository would mean removing coreutils, which apt,
#                       dpkg and Sileo depend on, so they refuse -- which is the
#                       point: nobody installs this by accident. The supported
#                       install is deliberate:
#                           dpkg -i --force-conflicts <deb>
#                       Feeding the .deb to `apt install` instead is treated as
#                       an explicit request and DOES remove coreutils first,
#                       which wedges dpkg. That is a loaded gun by design.
# Provides: coreutils   must NOT be here. Alongside the Replaces it tells apt
#                       this package obsoletes the GNU one, and apt then removes
#                       it even without the Conflicts.
grep -qE "^Replaces:( |.*, )coreutils(,|$)" "$debian/control" || {
    echo "error: control must declare Replaces: coreutils" >&2
    exit 65
}
grep -qE "^Conflicts:( |.*, )coreutils(,|$)" "$debian/control" || {
    echo "error: control must declare Conflicts: coreutils" >&2
    echo "       without it a package manager will install this by accident" >&2
    exit 65
}
if grep -qE "^Provides:( |.*, )coreutils( \(|,|$)" "$debian/control"; then
    echo "error: control declares Provides: coreutils" >&2
    echo "       apt reads Provides + Replaces as 'obsoletes' and removes the GNU" >&2
    echo "       package rather than letting this one overwrite its files" >&2
    exit 65
fi

# The maintainer scripts are what make the package removable at all. preinst
# stashes the GNU binaries before the takeover; postrm copies them back the
# moment dpkg deletes ours, because dpkg needs rm in PATH and rm is one of the
# files it just deleted. The stash lives outside this package's file list on
# purpose, so dpkg does not remove it first. @PREFIX@ is all that is
# substituted.
for script in preinst postrm; do
    sed -e "s|@PREFIX@|$install_prefix|g" "$repository_root/packaging/DEBIAN/$script" >"$debian/$script"
    chmod 0755 "$debian/$script"
    if grep -q '@[A-Z_]*@' "$debian/$script"; then
        echo "error: $script still holds an unsubstituted placeholder" >&2
        exit 65
    fi
    sh -n "$debian/$script" || { echo "error: $script does not parse" >&2; exit 65; }
done
grep -qF "PREFIX=$install_prefix" "$debian/postrm" || {
    echo "error: postrm does not carry the install prefix" >&2
    exit 65
}

dpkg-deb --root-owner-group -Zzstd -b "$staging" "$temporary_deb" >/dev/null

for script in preinst postrm; do
    dpkg-deb --ctrl-tarfile "$temporary_deb" | tar -t | grep -qx "./$script" || {
        echo "error: the built package carries no $script; removing it would strip the device" >&2
        exit 65
    }
done

[[ "$(dpkg-deb -f "$temporary_deb" Package)" == "$package_id" ]]
[[ "$(dpkg-deb -f "$temporary_deb" Version)" == "$version" ]]
[[ "$(dpkg-deb -f "$temporary_deb" Architecture)" == "$architecture" ]]
contents="$(dpkg-deb --contents "$temporary_deb")"
for path in \
    "$install_prefix/usr/bin/$PROGRAM" \
    "$install_prefix/usr/bin/ls" \
    "$install_prefix/usr/bin/timeout" \
    "$install_prefix/usr/bin/getent" \
    "$install_prefix/usr/bin/[" \
    "$install_prefix/etc/profile.d/coreutils.sh"; do
    grep -qF ".$path" <<<"$contents" || {
        echo "error: package is missing $path" >&2
        exit 65
    }
done

# Field 6 is the entry's own path for both files and symlinks; $NF would be the
# symlink target.
stray="$(awk '$1 !~ /^d/ {print $6}' <<<"$contents" |
    grep -vE "^\.$install_prefix/(usr/bin/|etc/profile\.d/coreutils\.sh$)" || true)"
[[ -z "$stray" ]] || {
    echo "error: package installs files outside usr/bin and etc/profile.d:" >&2
    sed 's/^/       /' <<<"$stray" >&2
    exit 65
}

utility_count="$(awk '$1 ~ /^l/ {print $6}' <<<"$contents" | grep -c . || true)"
mv -f "$temporary_deb" "$output_deb"
echo "packaged $package_id $version ($architecture, prefix '${install_prefix:-/}'): $output_deb"
echo "  $utility_count utilities in $install_prefix/usr/bin, unpacked over the GNU package"
shasum -a 256 "$output_deb"
