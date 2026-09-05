#!/usr/bin/env bash
#
# Install one .deb onto a jailbroken device over SSH and smoke-test it.
#
# This package takes over the bootstrap's GNU coreutils in usr/bin. The
# interesting part of the test is therefore not that the utilities run, it is
# that apt and dpkg still work afterwards, since their maintainer scripts run
# the very tools that were just swapped out -- and that `rm` never left PATH
# during the transaction, which is the failure mode a Conflicts-based swap has.
#
#   DEVICE_HOST  default 127.0.0.1
#   DEVICE_PORT  default 4422
#   DEVICE_USER  default mobile
#   DEVICE_SUDO_PASSWORD  only needed where sudo is not already passwordless
#
# Over USB, forward the device's sshd first:  iproxy 4422:22 &

set -Eeuo pipefail

if [[ "$#" -ne 1 ]]; then
    echo "usage: $0 <deb|package-directory>" >&2
    exit 64
fi

target="$1"
[[ -e "$target" ]] || { echo "error: no such package or directory: $target" >&2; exit 66; }

device_host="${DEVICE_HOST:-127.0.0.1}"
device_port="${DEVICE_PORT:-4422}"
device_user="${DEVICE_USER:-mobile}"
sudo_password="${DEVICE_SUDO_PASSWORD:-}"

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../configuration/upstream.env
source "$repository_root/configuration/upstream.env"
: "${PROGRAM:?}"
package_id_expected="${PACKAGE_ID:-wiki.qaq.uutils}"
package_version_expected="$(tr -d '[:space:]' <"$repository_root/configuration/version.txt")"

ssh_options=(
    -o BatchMode=yes
    -o ConnectTimeout=10
    -o StrictHostKeyChecking=accept-new
    -p "$device_port"
)
remote="$device_user@$device_host"

on_device() { ssh "${ssh_options[@]}" "$remote" "$@"; }

if ! on_device true 2>/dev/null; then
    echo "error: cannot reach $remote on port $device_port" >&2
    echo "hint: over USB, forward the device's sshd first:  iproxy $device_port:22 &" >&2
    exit 69
fi

device_architecture="$(on_device 'dpkg --print-architecture')"

if [[ -d "$target" ]]; then
    deb="$target/${package_id_expected}_${package_version_expected}_${device_architecture}.deb"
    [[ -f "$deb" ]] || {
        echo "error: expected current package $deb" >&2
        exit 66
    }
else
    deb="$target"
fi

package_architecture="$(dpkg-deb -f "$deb" Architecture)"
if [[ "$package_architecture" != "$device_architecture" ]]; then
    echo "error: this device installs '$device_architecture' packages, not '$package_architecture'" >&2
    case "$device_architecture" in
    iphoneos-arm64) echo "hint: build the rootless package:  make deb-rootless" >&2 ;;
    iphoneos-arm64e) echo "hint: build the roothide package:  make deb-roothide" >&2 ;;
    esac
    exit 65
fi

package_id="$(dpkg-deb -f "$deb" Package)"
package_version="$(dpkg-deb -f "$deb" Version)"
echo "installing $package_id $package_version ($package_architecture) on $remote"

staged="/tmp/$(basename "$deb")"
scp -q -P "$device_port" -o BatchMode=yes "$deb" "$remote:$staged"
trap 'on_device "rm -f '"$staged"'" >/dev/null 2>&1 || true' EXIT

if on_device 'sudo -n true' 2>/dev/null; then
    run_privileged() { on_device "sudo -n $1"; }
elif [[ -n "$sudo_password" ]]; then
    run_privileged() {
        printf '%s\n' "$sudo_password" | ssh "${ssh_options[@]}" "$remote" "sudo -S -p '' $1"
    }
else
    echo "error: sudo on the device needs a password; set DEVICE_SUDO_PASSWORD" >&2
    exit 77
fi

prefix=""
[[ "$package_architecture" == "iphoneos-arm64" ]] && prefix="/var/jb"

# Keep a copy of the GNU binaries before the swap. If the replacement is broken
# the device still has a way back that does not depend on anything in usr/bin.
echo "==> backing up the GNU coreutils binaries"
run_privileged "mkdir -p /var/mobile/gnu-coreutils-backup"
run_privileged "sh -c 'for p in \$(dpkg -L coreutils | grep \"^$prefix/usr/bin/\"); do [ -f \"\$p\" ] && cp -p \"\$p\" /var/mobile/gnu-coreutils-backup/; done; true'"
backed_up="$(on_device "ls /var/mobile/gnu-coreutils-backup | wc -l" | tr -d '[:space:]')"
echo "    $backed_up binaries in /var/mobile/gnu-coreutils-backup"

# dpkg, not apt. The package conflicts with coreutils on purpose so that no
# package manager installs it by accident, and apt handed a local .deb treats
# that as an explicit request: it removes coreutils first, which deletes rm --
# the one program dpkg insists on finding in PATH -- and the transaction dies
# with the device holding no coreutils at all. --force-conflicts skips that
# resolution entirely and goes straight to the unpack, where Replaces hands the
# paths over with nothing deleted.
#
# Prove that first, without touching anything: if apt would remove coreutils,
# say so and stop.
echo "==> what apt would do if it were let near this (must not be used)"
plan="$(on_device "apt-get install --simulate --allow-downgrades $staged" 2>&1 || true)"
if grep -q '^Remv coreutils' <<<"$plan"; then
    echo "    apt would remove coreutils -- as expected; installing with dpkg instead"
fi

echo "==> dpkg unpacks over the GNU coreutils"
run_privileged "dpkg -i --force-conflicts $staged" 2>&1 | tail -12

echo "==> both packages are registered and this one owns usr/bin"
on_device "dpkg -l coreutils 2>/dev/null | grep -q '^ii'" || {
    echo "error: the GNU coreutils package should still be registered" >&2
    exit 65
}
on_device "dpkg -l $package_id 2>/dev/null | grep -q '^ii'" || {
    echo "error: $package_id did not install" >&2
    exit 65
}
on_device "dpkg -S $prefix/usr/bin/ls" | grep -qF "$package_id:" || {
    echo "error: $prefix/usr/bin/ls is not owned by $package_id" >&2
    on_device "dpkg -S $prefix/usr/bin/ls" >&2
    exit 65
}
on_device "command -v ls" | grep -qxF "$prefix/usr/bin/ls" || {
    echo "error: ls on PATH is not $prefix/usr/bin/ls" >&2
    exit 65
}
ls_version="$(on_device "ls --version")"
case $ls_version in
*uutils*) ;;
*)
    echo "error: ls on PATH is not uutils" >&2
    sed 's/^/       /' <<<"$ls_version" | head -n2 >&2
    exit 65
    ;;
esac
on_device "test -L $prefix/usr/bin/ls" || {
    echo "error: $prefix/usr/bin/ls is not a symlink to the multi-call binary" >&2
    exit 65
}
on_device "readlink $prefix/usr/bin/ls" | grep -qxF "$PROGRAM" || {
    echo "error: $prefix/usr/bin/ls does not point at $PROGRAM" >&2
    exit 65
}

echo "==> rm never left PATH, which is what wedges dpkg"
on_device "command -v rm" | grep -qxF "$prefix/usr/bin/rm" || {
    echo "error: rm is not on PATH after the takeover" >&2
    exit 65
}

echo "==> nothing else came loose"
on_device "dpkg-query -W -f='\${Provides}' $package_id" | grep -q 'coreutils' && {
    echo "error: the package provides coreutils; apt will obsolete the GNU one next time" >&2
    exit 65
}
for dependent in apt dpkg org.coolstar.sileo; do
    on_device "dpkg -l $dependent 2>/dev/null | grep -q '^ii'" || continue
    on_device "dpkg -s $dependent >/dev/null" || {
        echo "error: $dependent is no longer satisfied" >&2
        exit 65
    }
done

# apt refuses to do anything while the declared conflict with coreutils stands.
# That is the front door lock working, not a fault -- but it means the proof
# that dpkg survives having its own tools swapped has to go through dpkg.
echo "==> apt refuses while the conflict stands, by design"
apt_refusal="$(run_privileged "apt-get install -y tree" 2>&1 || true)"
grep -q 'Conflicts: coreutils' <<<"$apt_refusal" || {
    echo "error: apt did not refuse; the Conflicts: coreutils lock is not in effect" >&2
    sed 's/^/       /' <<<"$apt_refusal" | tail -6 >&2
    exit 65
}

echo "==> dpkg still installs and removes packages with uutils underneath it"
run_privileged "sh -c 'cd /tmp && apt-get download tree'" >/dev/null 2>&1 || {
    echo "error: could not fetch a package to test with" >&2
    exit 65
}
run_privileged "sh -c 'dpkg -i /tmp/tree_*.deb'" >/dev/null || {
    echo "error: dpkg -i failed after the swap" >&2
    exit 65
}
on_device "tree --version >/dev/null" || { echo "error: the installed package does not run" >&2; exit 65; }
run_privileged "dpkg -r tree" >/dev/null || {
    echo "error: dpkg -r failed after the swap" >&2
    exit 65
}
run_privileged "sh -c 'rm -f /tmp/tree_*.deb'" >/dev/null 2>&1 || true
echo "    install and remove of a real package both completed"

echo "==> utilities"
on_device "echo uutils-ok" >/dev/null
on_device "printf 'b\\na\\nc\\n' | sort | tr -d '\\n'" | grep -qxF abc || {
    echo "error: sort did not work" >&2
    exit 65
}
# Quote the path: the device's login shell may be zsh, which globs a bare `[`.
on_device "'$prefix/usr/bin/[' -d '$prefix/usr/bin' ]" || {
    echo "error: the [ alias did not work" >&2
    exit 65
}
on_device "$PROGRAM ls -d / >/dev/null" || {
    echo "error: 'coreutils ls' did not work" >&2
    exit 65
}

echo "==> cp -a preserves attributes instead of failing on xattr"
on_device "cd /tmp && rm -rf uutest && mkdir uutest && cd uutest && echo x >a && cp -a a b && rm -rf /tmp/uutest" || {
    echo "error: cp -a failed; the xattr dependency patch is not in this build" >&2
    exit 65
}

echo "==> spawning a child (this is the fork() path on a bad build)"
on_device "env UUTILS_PROBE=1 printenv UUTILS_PROBE" | grep -qxF 1 || {
    echo "error: env could not start a child" >&2
    exit 65
}
on_device "timeout 5 echo spawned" | grep -qxF spawned || {
    echo "error: timeout could not start a child" >&2
    exit 65
}
on_device "timeout 1 sleep 5; test \$? -eq 124" || {
    echo "error: timeout did not report 124 on expiry" >&2
    exit 65
}
# nohup went untested through several rounds and was broken the whole time:
# upstream detaches from the launchd console on Apple targets, which always
# fails on iOS, so every nohup died before running anything. patches/0004.
nohup_output="$(on_device "cd /tmp && rm -f uutils-nohup && nohup echo spawned >uutils-nohup 2>&1; cat uutils-nohup; rm -f uutils-nohup")"
[[ "$nohup_output" == "spawned" ]] || {
    echo "error: nohup did not run its command; it printed '$nohup_output'" >&2
    exit 65
}

echo "==> the getent stand-in answers what the shells ask it"
getent_passwd="$(on_device "getent passwd $device_user")"
case $getent_passwd in
"$device_user":*) ;;
*)
    echo "error: getent passwd $device_user returned '$getent_passwd'" >&2
    exit 65
    ;;
esac
getent_group="$(on_device "getent group")"
case $getent_group in
*:*) ;;
*)
    echo "error: getent group dumped nothing" >&2
    exit 65
    ;;
esac

# Source the file directly rather than through `sh -l`: whether a given shell
# reads /etc/profile for a non-interactive login is its own business, and what
# is being tested here is the file this package ships.
echo "==> the profile snippet still does what the GNU one did"
on_device ". $prefix/etc/profile.d/coreutils.sh; test -n \"\$LS_COLORS\"" || {
    echo "error: $prefix/etc/profile.d/coreutils.sh did not set LS_COLORS" >&2
    exit 65
}

echo "==> the package carries its own way out"
on_device "test -x $prefix/usr/libexec/uutils/gnu-backup/cp" || {
    echo "error: preinst did not stash a working cp; removing this package would" >&2
    echo "       strip usr/bin with no way back" >&2
    exit 65
}
stashed="$(on_device "ls $prefix/usr/libexec/uutils/gnu-backup | wc -l" | tr -d '[:space:]')"
((stashed > 50)) || {
    echo "error: only $stashed binaries stashed for postrm to restore" >&2
    exit 65
}
echo "    $stashed GNU binaries stashed for postrm"

echo
echo "installed and smoke-tested $package_id $package_version on $remote"
echo "to go back:"
echo "  sudo dpkg --remove $package_id            # postrm puts the GNU binaries back"
echo "  sudo apt-get install --reinstall coreutils system-cmds   # and dpkg's bookkeeping"
echo "if that ever fails, the GNU binaries are also in /var/mobile/gnu-coreutils-backup"
