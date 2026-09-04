#!/usr/bin/env bash
#
# Cross-compile the uutils multi-call binary for iOS out of a prepared source
# tree, verify the result is really an iOS binary that never reaches fork(),
# and assemble a payload directory.
#
# Prints the payload directory on stdout (the last line). Its contents are
# exactly the tree that lands under the bootstrap prefix.

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

: "${CARGO_DIR:?}"
: "${CARGO_PACKAGE:?}"
: "${CARGO_BIN:?}"
: "${CARGO_FEATURES:?}"
: "${PROGRAM:?}"
: "${UTILS_DIR:?}"
: "${MIN_IOS:?}"
: "${ARCH:?}"
: "${RUST_TOOLCHAIN:?}"

cargo_root="$src_dir/$CARGO_DIR"
[[ -f "$cargo_root/Cargo.toml" ]] || {
    echo "error: $cargo_root is not a prepared Cargo tree (run scripts/prepare-source.sh)" >&2
    exit 66
}

sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"
[[ -d "$sdk_path" ]] || { echo "error: no iPhoneOS SDK; install Xcode" >&2; exit 69; }

# rustc's apple-ios target is aarch64-apple-ios, not arm64-apple-ios.
case "$ARCH" in
arm64) rust_target="aarch64-apple-ios" ;;
*)     rust_target="$ARCH-apple-ios" ;;
esac

echo "building $CARGO_PACKAGE ($CARGO_BIN) for $rust_target (iOS $MIN_IOS)" >&2
echo "  SDK:       $sdk_path" >&2
echo "  toolchain: $RUST_TOOLCHAIN" >&2
echo "  features:  $CARGO_FEATURES" >&2

# fork() audit.
#
# std only takes the posix_spawn() path while a Command carries no pre_exec
# closure and no uid/gid/groups override; ask for any of those and it falls back
# to fork() + exec(). This binary links the Objective-C runtime and Foundation,
# and forking such a process is not safe on iOS, so nothing here may reach
# fork(). All four of those knobs live on the CommandExt trait, so the import is
# the thing to watch: patches/0001 cfg-guards the one use upstream has (timeout)
# out of Apple builds. A new one appearing upstream must be handled the same way
# before it ships.
echo "==> fork() audit" >&2
fork_calls="$(grep -rn --include='*.rs' -E '\b(libc|unistd|nix::unistd)::(fork|vfork)\b|\bdaemon\(' "$cargo_root/src" || true)"
[[ -z "$fork_calls" ]] || {
    echo "error: prepared source calls fork() directly:" >&2
    sed 's/^/       /' <<<"$fork_calls" >&2
    exit 65
}

# CommandExt itself is fine -- chroot, nice, nohup and runcon use its exec(),
# which replaces the process image and never forks. It is these four builders
# that push std off posix_spawn(). Scan the files that pull the trait in.
patched_file="src/uu/timeout/src/platform/unix.rs"
fork_forcing='\.(pre_exec|before_exec|uid|gid|groups)\('
while read -r command_ext_user; do
    [[ -n "$command_ext_user" ]] || continue
    [[ "$command_ext_user" == "$patched_file" ]] && continue
    hits="$(grep -nE "$fork_forcing" "$cargo_root/$command_ext_user" || true)"
    [[ -z "$hits" ]] || {
        echo "error: $command_ext_user configures a Command in a way that forces fork():" >&2
        sed 's/^/       /' <<<"$hits" >&2
        echo "       guard it with #[cfg(not(target_vendor = \"apple\"))] in a patch" >&2
        exit 65
    }
done < <(grep -rl --include='*.rs' 'os::unix::process::CommandExt' "$cargo_root/src" | sed "s|^$cargo_root/||" | sort)

# timeout is the one upstream case, and patches/0001 compiles it out on Apple.
grep -qF '#[cfg(not(target_vendor = "apple"))]
use std::os::unix::process::CommandExt;' "$cargo_root/$patched_file" || {
    echo "error: $patched_file imports CommandExt on Apple targets" >&2
    echo "       patches/0001 did not apply the way this script expects" >&2
    exit 65
}
stray_pre_exec="$(grep -rn --include='*.rs' -E '\.(pre_exec|before_exec)\(' "$cargo_root/src" |
    grep -vF "$patched_file" || true)"
[[ -z "$stray_pre_exec" ]] || {
    echo "error: a pre_exec closure appeared outside $patched_file:" >&2
    sed 's/^/       /' <<<"$stray_pre_exec" >&2
    exit 65
}
echo "    no fork() path compiled for $rust_target" >&2

command -v rustup >/dev/null || { echo "error: rustup is not installed" >&2; exit 69; }
rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal >&2
rustup target add "$rust_target" --toolchain "$RUST_TOOLCHAIN" >&2

export SDKROOT="$sdk_path"
export IPHONEOS_DEPLOYMENT_TARGET="$MIN_IOS"
unset MACOSX_DEPLOYMENT_TARGET
# Stop pkg-config from feeding macOS .pc files into an iOS link.
export PKG_CONFIG_ALLOW_CROSS=1
unset PKG_CONFIG_PATH PKG_CONFIG_LIBDIR || true

mkdir -p "$scratch_dir"
cargo_home="$scratch_dir/cargo-home"
mkdir -p "$cargo_home"
export CARGO_HOME="$cargo_home"
export CARGO_TARGET_DIR="$scratch_dir/target"
# rustc embeds source paths (panic locations, debug info) for the checkout and
# every registry crate. Remap them so the binary does not carry the build
# machine's directories. Upstream's .cargo/config.toml sets rustflags only for
# redox, aarch64 linux and msvc, so exporting RUSTFLAGS drops nothing here.
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$src_dir=/src --remap-path-prefix=$scratch_dir=/build"

# Host rustc would happily emit a darwin Mach-O if the target flag is dropped.
# The vtool check below is the backstop; this is the front.
(
    cd "$cargo_root"
    cargo +"$RUST_TOOLCHAIN" build \
        --release \
        --target "$rust_target" \
        --no-default-features \
        --features "$CARGO_FEATURES" \
        --package "$CARGO_PACKAGE" \
        --bin "$CARGO_BIN"
) >&2

executable="$CARGO_TARGET_DIR/$rust_target/release/$CARGO_BIN"
[[ -f "$executable" ]] || { echo "error: build produced no $executable" >&2; exit 65; }

build_version="$(vtool -show-build "$executable" 2>/dev/null)"
grep -qE '^ *platform (IOS|2)$' <<<"$build_version" || {
    echo "error: $executable is not an iOS binary:" >&2
    sed 's/^/       /' <<<"$build_version" >&2
    exit 65
}

architectures="$(lipo -archs "$executable")"
[[ "$architectures" == "$ARCH" ]] || {
    echo "error: expected a $ARCH binary, got '$architectures'" >&2
    exit 65
}

while read -r dependency; do
    case "$dependency" in
    @*) ;;
    /usr/lib/* | /System/Library/Frameworks/*) ;;
    *)
        echo "error: $executable depends on a path iOS does not provide: $dependency" >&2
        exit 65
        ;;
    esac
done < <(otool -L "$executable" | tail -n +2 | awk '{print $1}')

# The other half of the fork() audit, on the Mach-O this time. patches/0002
# defines fork() rather than importing it, and under the crate's `lto = "fat"`
# profile that definition is inlined into std's unused fallback, so the symbol
# should be gone from the binary entirely.
#
# _pthread_atfork stays and is fine: it is the rand crate registering a handler
# that reseeds its RNG in a forked child (rand::rngs::adapter::reseeding). It
# only registers; with no fork() it can never run.
fork_imports="$(nm -m "$executable" | grep -E 'external _(fork|vfork)( |$)' || true)"
[[ -z "$fork_imports" ]] || {
    echo "error: $executable still carries a fork symbol:" >&2
    sed 's/^/       /' <<<"$fork_imports" >&2
    exit 65
}
nm -m "$executable" | grep -qE 'external _posix_spawnp?( |$)' || {
    echo "error: $executable does not import posix_spawn" >&2
    exit 65
}
echo "==> no _fork/_vfork in the Mach-O; process spawning is posix_spawn only" >&2

# No privilege escalation. Children come from posix_spawn() and inherit the
# credentials this process was launched with; nothing re-assumes an identity.
# patches/0003 drops chroot, the only utility that called these.
#
# _setpgid stays: `timeout` puts the child in its own process group so it can
# signal the whole group on expiry, which is what GNU timeout does and costs no
# privilege. _setsid is an import std carries for a Command option no utility
# sets.
escalation="$(nm -u "$executable" |
    grep -E '^_(setuid|seteuid|setreuid|setgid|setegid|setregid|setgroups|initgroups)$' || true)"
[[ -z "$escalation" ]] || {
    echo "error: $executable imports a privilege-changing syscall:" >&2
    sed 's/^/       /' <<<"$escalation" >&2
    echo "       children inherit credentials through posix_spawn; nothing escalates" >&2
    exit 65
}
echo "==> no setuid/setgid/setgroups; credentials are inherited, never assumed" >&2

# Anything newer than the deployment target is weak-linked and NULL on an older
# device. There is nothing to guard as long as this stays empty.
weak_symbols="$(nm -m "$executable" 2>/dev/null | grep 'weak external' | awk '{print $NF}' | sort -u || true)"
[[ -z "$weak_symbols" ]] || {
    echo "error: $executable weak-links symbols newer than iOS $MIN_IOS:" >&2
    sed 's/^/       /' <<<"$weak_symbols" >&2
    echo "       each one must be null-checked in source" >&2
    exit 65
}

# Which utilities the build actually contains. Same derivation upstream's
# GNUmakefile uses, so it follows the feature set instead of a hardcoded list.
mapfile -t utilities < <(
    cd "$cargo_root" &&
        cargo +"$RUST_TOOLCHAIN" tree \
            --depth 1 \
            --no-default-features \
            --features "$CARGO_FEATURES" \
            --format '{p}' \
            --prefix none 2>/dev/null |
        sed -E -n 's/^uu_([^ ]+).*/\1/p' |
        sort -u
)
((${#utilities[@]} > 50)) || {
    echo "error: only ${#utilities[@]} utilities resolved from features '$CARGO_FEATURES'" >&2
    exit 65
}
# `test` also installs as `[`, the way GNU and upstream's makefile ship it.
if printf '%s\n' "${utilities[@]}" | grep -qx test; then
    utilities+=('[')
fi

payload="$scratch_dir/payload"
rm -rf -- "$payload"
mkdir -p "$payload/usr/bin" "$payload/$UTILS_DIR"
/usr/bin/ditto "$executable" "$payload/usr/bin/$PROGRAM"

# usr/libexec/uutils/bin/<util> -> ../../../bin/<program>. The multi-call binary
# dispatches on argv[0] alone on Apple targets (src/common/validation.rs), so a
# symlink is enough; nothing reads current_exe().
depth="$(awk -F/ '{print NF}' <<<"$UTILS_DIR")"
relative_binary="$(printf '../%.0s' $(seq 1 "$depth"))usr/bin/$PROGRAM"
for utility in "${utilities[@]}"; do
    ln -s "$relative_binary" "$payload/$UTILS_DIR/$utility"
done

{
    echo "built $PROGRAM: $architectures, iOS $MIN_IOS minimum, $(
        du -h "$payload/usr/bin/$PROGRAM" | cut -f1 | tr -d ' '
    )"
    echo "utilities (${#utilities[@]}), symlinked into $UTILS_DIR:"
    printf '%s\n' "${utilities[@]}" | sort | paste -sd' ' - | fold -sw 72 | sed 's/^/  /'
    echo "system dependencies:"
    otool -L "$payload/usr/bin/$PROGRAM" | tail -n +2 | awk '{print "  " $1}'
} >&2

printf '%s\n' "$payload"
