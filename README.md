# uutils coreutils for jailbroken iOS

[uutils coreutils](https://github.com/uutils/coreutils) — the GNU core
utilities reimplemented in Rust — cross-compiled for iOS 15+ and packaged for
both roothide and rootless bootstraps from one arm64 build.

Install from the [OwnGoal Studio repository](https://apt.owngoal.dev), or grab
a `.deb` from [Releases](https://github.com/owngoal-dev/coreutils/releases).

| bootstrap | architecture field | installs under |
| --------- | ------------------ | -------------- |
| rootless (Dopamine, palera1n rootless) | `iphoneos-arm64` | `/var/jb` |
| roothide (RootHide Dopamine) | `iphoneos-arm64e` | the randomized jbroot |

The architecture field names the **layout, not the CPU**. Both packages carry
the same arm64 binary. Ask the device which it wants: `dpkg --print-architecture`.

## It sits beside your coreutils, it does not replace them

`apt`, `dpkg` and Sileo depend on the GNU `coreutils` your bootstrap ships, and
their maintainer scripts run the very tools a replacement would swap out — a
bad swap leaves you unable to install the fix. So this package declares no
`Provides`, `Conflicts` or `Replaces`, puts nothing in `usr/bin` except the
multi-call binary, and adds nothing to `PATH`.

```
<prefix>/usr/bin/coreutils              multi-call binary
<prefix>/usr/libexec/uutils/bin/<util>  ~106 symlinks into it
<prefix>/etc/profile.d/uutils.sh        exports UUTILS_BIN
```

Two ways to use it:

```sh
coreutils ls -l                    # no PATH change at all
export PATH="$UUTILS_BIN:$PATH"    # this shell prefers uutils; new shells do not
```

Put the `export` in your shell's rc file to keep it, delete the line to go back.

## No fork()

Forking a process that has the Objective-C runtime and Foundation loaded is not
safe on iOS. Every child these utilities start goes through `posix_spawn()`, and
the build refuses a binary that so much as imports `_fork`. Two patches get it
there — `timeout` spawns without a `pre_exec` closure, and `fork()` is defined
to fail rather than imported — and `make build` proves it by running the
utilities that spawn under lldb with a breakpoint on `fork`.

## No privilege escalation either

Children are started with `posix_spawn()` and inherit the credentials the shell
already had; nothing in the binary re-assumes an identity. `chroot` is dropped
because it was the only utility calling `setuid()`, `setgid()` and
`setgroups()` — and the build refuses a binary that imports any of them.
Lowering is still fine: `nice` reduces its own priority, `timeout` puts the
child in its own process group so it can signal it.

## Not included

`chroot` (privilege escalation, see above), `stdbuf` (its cdylib link is
rejected by `ld64`, and `DYLD_INSERT_LIBRARIES` does not apply to a
platform-signed process), `chcon` and `runcon` (SELinux). `getent` is not a
uutils utility; the GNU package keeps providing it.

## Build it yourself

```sh
make check     # scripts, config, patch set
make debs      # both packages + SHA256SUMS
make install   # onto a device over SSH, then smoke-test
```

Needs Xcode, `rustup`, `ldid`, `dpkg` and `clang++`. See [`AGENTS.md`](AGENTS.md)
for the contract this repository follows.

## License

The packaging in this repository is MIT. uutils coreutils itself is MIT, and
ships under its own terms.
