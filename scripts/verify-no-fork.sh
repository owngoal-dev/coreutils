#!/usr/bin/env bash
#
# Prove at runtime that nothing spawns through fork().
#
# The iOS binary cannot be run here, but the patches key off
# `target_vendor = "apple"`, which is just as true for the host. So build the
# same prepared source for the host and step on fork()/vfork() with lldb while
# every utility that starts a process does its thing. A hit means the Apple
# spawn path regressed and the iOS build would fork on device.
#
# Fast after the first run: the host target directory is cached beside the iOS
# one, and only what changed recompiles.

set -Eeuo pipefail

if [[ "$#" -ne 2 ]]; then
    echo "usage: $0 <src-dir> <scratch-dir>" >&2
    exit 64
fi

src_dir="$1"
scratch_dir="$2"
repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

# shellcheck source=../configuration/upstream.env
source "$repository_root/configuration/upstream.env"

: "${CARGO_DIR:?}" "${CARGO_PACKAGE:?}" "${CARGO_BIN:?}" "${CARGO_FEATURES:?}" "${RUST_TOOLCHAIN:?}"

command -v lldb >/dev/null || { echo "error: lldb is not installed (Xcode command line tools)" >&2; exit 69; }

cargo_root="$src_dir/$CARGO_DIR"
host_dir="$scratch_dir/host"
mkdir -p "$host_dir"

export CARGO_HOME="$scratch_dir/cargo-home"
export CARGO_TARGET_DIR="$host_dir/target"
unset SDKROOT IPHONEOS_DEPLOYMENT_TARGET

xattr_source="$("$repository_root/scripts/prepare-xattr.sh" "$cargo_root" "$CARGO_HOME" "$scratch_dir/dependencies")"

echo "building $CARGO_BIN for the host to exercise the Apple spawn path" >&2
(
    cd "$cargo_root"
    cargo +"$RUST_TOOLCHAIN" build \
        --release \
        --no-default-features \
        --features "$CARGO_FEATURES" \
        --package "$CARGO_PACKAGE" \
        --bin "$CARGO_BIN" \
        --config "patch.crates-io.xattr.path='$xattr_source'"
) >&2

host_binary="$CARGO_TARGET_DIR/release/$CARGO_BIN"
[[ -f "$host_binary" ]] || { echo "error: host build produced no $host_binary" >&2; exit 65; }

# The multi-call binary dispatches on argv[0], so each probe runs through the
# name it would have on device.
probe_dir="$host_dir/bin"
rm -rf -- "$probe_dir"
mkdir -p "$probe_dir"
/usr/bin/ditto "$host_binary" "$probe_dir/$CARGO_BIN"
for utility in env nice timeout sort; do
    ln -sf "$CARGO_BIN" "$probe_dir/$utility"
done

work_dir="$host_dir/work"
rm -rf -- "$work_dir"
mkdir -p "$work_dir"
printf 'b\na\nc\n' >"$work_dir/lines.txt"

probes=(
    "timeout 5 /bin/echo spawned"
    "env PROBE=1 /bin/echo spawned"
    "nice -n 5 /bin/echo spawned"
    "sort --compress-program=gzip -S 1 lines.txt"
)

status=0
for probe in "${probes[@]}"; do
    utility="${probe%% *}"
    arguments="${probe#* }"
    output="$(
        cd "$work_dir" && lldb -b \
            -o 'settings set target.process.stop-on-exec false' \
            -o 'breakpoint set -n fork' \
            -o 'breakpoint set -n vfork' \
            -o "run $arguments" \
            -o 'quit' \
            "$probe_dir/$utility" 2>&1
    )"
    if grep -q 'stop reason = breakpoint' <<<"$output"; then
        printf '  %-46s FORKED\n' "$probe" >&2
        sed 's/^/      /' <<<"$output" >&2
        status=1
    else
        printf '  %-46s no fork\n' "$probe" >&2
    fi
done

((status == 0)) || {
    echo "error: a utility reached fork() on an Apple target" >&2
    exit 65
}

# Same check the other way round: the child really did start.
"$probe_dir/timeout" 5 /bin/echo spawned >/dev/null || {
    echo "error: timeout could not start a child at all" >&2
    exit 65
}
[[ "$("$probe_dir/timeout" 1 /bin/sleep 5 >/dev/null 2>&1; echo $?)" == 124 ]] || {
    echo "error: timeout did not report 124 on expiry" >&2
    exit 65
}

echo "no fork(): every probe spawned through posix_spawn" >&2
