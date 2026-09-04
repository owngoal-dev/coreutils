[uutils coreutils](https://github.com/uutils/coreutils) — the GNU core utilities reimplemented in Rust — built for jailbroken iOS.

## Which one do I download?

The architecture field names the **bootstrap layout, not the CPU**. Both packages carry the same arm64 binary.

| your bootstrap | download |
| -------------- | -------- |
| rootless (Dopamine, palera1n rootless) | `@PACKAGE_ID@_@VERSION@_iphoneos-arm64.deb` |
| roothide (RootHide Dopamine) | `@PACKAGE_ID@_@VERSION@_iphoneos-arm64e.deb` |

Not sure? Ask the device: `dpkg --print-architecture`.

Requires **iOS @MIN_IOS_MAJOR@ or later**. Or add the [OwnGoal Studio repository](https://github.com/owngoal-dev/OwnGoalPackages) and let your package manager pick.

## This does not replace your coreutils

`apt`, `dpkg` and Sileo all depend on the GNU `coreutils` your bootstrap ships, and their maintainer scripts run the very tools that a replacement would swap out. So this package declares no `Provides`, `Conflicts` or `Replaces`, installs nothing into `usr/bin` except the multi-call binary itself, and adds nothing to `PATH`.

Everything lands in `@UTILS_DIR@` under your bootstrap prefix instead. Two ways to use it:

```sh
export PATH="$UUTILS_BIN:$PATH"   # this shell only; $UUTILS_BIN comes from /etc/profile.d/uutils.sh
coreutils ls -l                   # or reach any utility without touching PATH
```

Put that `export` in your shell's rc file to make it stick, and delete the line to go back.

## About this build

Upstream [`uutils/coreutils@@UPSTREAM_SHORT@`](https://github.com/uutils/coreutils/commit/@UPSTREAM_REF@), built from the `feat_os_unix_musl` utility set, plus three patches that make it safe on iOS: `timeout` spawns without a `pre_exec` closure so `std` stays on `posix_spawn()`; `fork()`, `setuid()`, `setgid()` and `setgroups()` are defined to fail rather than imported; and `chroot` is dropped. Forking a process with the Objective-C runtime loaded is not safe on iOS, and the build refuses a binary that imports any of those symbols. See [`patches/`](https://github.com/owngoal-dev/coreutils/tree/@TAG@/patches).

Nothing escalates privilege either: children inherit the credentials the shell already had, and the build refuses a binary importing `setuid`, `setgid` or `setgroups`.

Not included: `chroot` (the only utility calling those), `stdbuf` (needs a cdylib link that `ld64` rejects, and `DYLD_INSERT_LIBRARIES` does not apply to a platform-signed process), `chcon` and `runcon` (SELinux). `getent` is not part of uutils; the GNU package on your bootstrap keeps providing it.

Verify your download against `SHA256SUMS`.

**Full changelog**: https://github.com/owngoal-dev/coreutils/commits/@TAG@
