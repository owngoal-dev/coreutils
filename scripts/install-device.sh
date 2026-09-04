#!/usr/bin/env bash
#
# Install one .deb onto a jailbroken device over SSH and smoke-test it.
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
: "${UTILS_DIR:?}"
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

run_privileged "dpkg -i $staged"

prefix=""
[[ "$package_architecture" == "iphoneos-arm64" ]] && prefix="/var/jb"
bin_dir="$prefix/$UTILS_DIR"

echo "==> installed layout"
on_device "test -x '$prefix/usr/bin/$PROGRAM'" || {
    echo "error: $prefix/usr/bin/$PROGRAM is missing or not executable" >&2
    exit 65
}
on_device "test -r '$prefix/etc/profile.d/uutils.sh'" || {
    echo "error: the profile snippet is missing" >&2
    exit 65
}
utility_count="$(on_device "ls '$bin_dir' | wc -l" | tr -d '[:space:]')"
((utility_count > 50)) || {
    echo "error: only $utility_count utilities landed in $bin_dir" >&2
    exit 65
}
echo "    $utility_count utilities in $bin_dir"

echo "==> GNU coreutils is still the one on PATH"
on_device "command -v ls" | grep -qxF "$prefix/usr/bin/ls" || {
    echo "error: ls on PATH is not $prefix/usr/bin/ls; this package must not take over" >&2
    on_device "command -v ls" >&2
    exit 65
}
on_device "dpkg -S $prefix/usr/bin/ls" | grep -q '^coreutils:' || {
    echo "error: $prefix/usr/bin/ls is no longer owned by the GNU coreutils package" >&2
    exit 65
}

echo "==> multi-call entry point"
on_device "$prefix/usr/bin/$PROGRAM --version" | head -n1
on_device "$prefix/usr/bin/$PROGRAM ls -d / >/dev/null" || {
    echo "error: 'coreutils ls' failed on device" >&2
    exit 65
}

echo "==> utilities through the symlinks"
on_device "$bin_dir/echo uutils-ok" | grep -qxF uutils-ok || {
    echo "error: echo through the symlink did not work" >&2
    exit 65
}
on_device "printf 'b\\na\\nc\\n' | $bin_dir/sort | tr -d '\\n'" | grep -qxF abc || {
    echo "error: sort through the symlink did not work" >&2
    exit 65
}
# Quote the path: the device's login shell may be zsh, which globs a bare `[`.
on_device "'$bin_dir/[' -d '$bin_dir' ]" || {
    echo "error: the [ alias did not work" >&2
    exit 65
}

echo "==> paths resolve the way the shell sees them"
on_device "$bin_dir/ls -d '$prefix/usr/bin' >/dev/null" || {
    echo "error: uutils ls cannot see $prefix/usr/bin; roothide path redirection is wrong" >&2
    exit 65
}
on_device "test \"\$($bin_dir/readlink -f '$bin_dir/ls')\" = \"\$($bin_dir/readlink -f '$prefix/usr/bin/$PROGRAM')\"" || {
    echo "error: the utility symlinks do not resolve to the installed binary" >&2
    exit 65
}

echo "==> spawning a child (this is the fork() path on a bad build)"
on_device "$bin_dir/env UUTILS_PROBE=1 $bin_dir/printenv UUTILS_PROBE" | grep -qxF 1 || {
    echo "error: env could not start a child" >&2
    exit 65
}
on_device "$bin_dir/timeout 5 $bin_dir/echo spawned" | grep -qxF spawned || {
    echo "error: timeout could not start a child" >&2
    exit 65
}
on_device "$bin_dir/timeout 1 $prefix/usr/bin/sleep 5; test \$? -eq 124" || {
    echo "error: timeout did not report 124 on expiry" >&2
    exit 65
}
on_device "$bin_dir/nohup $bin_dir/echo spawned >/tmp/uutils-nohup 2>/dev/null; grep -qxF spawned /tmp/uutils-nohup; rm -f /tmp/uutils-nohup" || {
    echo "error: nohup could not start a child" >&2
    exit 65
}

echo "==> \$UUTILS_BIN opt-in"
on_device "sh -lc 'test \"\$UUTILS_BIN\" = \"$bin_dir\"'" || {
    echo "error: /etc/profile.d/uutils.sh does not export UUTILS_BIN=$bin_dir" >&2
    exit 65
}
on_device "sh -lc 'PATH=\"\$UUTILS_BIN:\$PATH\"; ls --version'" | head -n1 | grep -q uutils || {
    echo "error: prepending \$UUTILS_BIN to PATH does not select uutils ls" >&2
    exit 65
}

echo "installed and smoke-tested $package_id $package_version on $remote"
