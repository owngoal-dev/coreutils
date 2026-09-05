#!/usr/bin/env bash
#
# Prove ordinary posix_spawn use, without fork, exec, or SETEXEC.
#
# The iOS binary cannot be run here, but the patches key off
# `target_vendor = "apple"`, which is just as true for the host. So build the
# same prepared source for the host, check process behavior, and require a
# successful exit plus a posix_spawn hit under lldb for each process launcher.
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

"$repository_root/scripts/verify-process-symbols.sh" "$host_binary"
python3 "$repository_root/scripts/verify-spawn.py" "$host_binary"
