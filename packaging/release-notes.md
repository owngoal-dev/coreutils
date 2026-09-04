[uutils coreutils](https://github.com/uutils/coreutils) — the GNU core utilities reimplemented in Rust — built for jailbroken iOS, **replacing** the GNU coreutils your bootstrap ships.

## Which one do I download?

The architecture field names the **bootstrap layout, not the CPU**. Both packages carry the same arm64 binary.

| your bootstrap | download |
| -------------- | -------- |
| rootless (Dopamine, palera1n rootless) | `@PACKAGE_ID@_@VERSION@_iphoneos-arm64.deb` |
| roothide (RootHide Dopamine) | `@PACKAGE_ID@_@VERSION@_iphoneos-arm64e.deb` |

Not sure? Ask the device: `dpkg --print-architecture`.

Requires **iOS @MIN_IOS_MAJOR@ or later**. Or add the [OwnGoal Studio repository](https://github.com/owngoal-dev/OwnGoalPackages) and let your package manager pick.

## This takes over coreutils — on purpose, and only if you ask

Installing it unpacks over the GNU coreutils in `usr/bin`: one multi-call binary with a symlink per utility beside it. The GNU `coreutils` package stays registered and keeps whatever this one does not ship, so `apt`, `dpkg`, Sileo and `darwintools` — all of which depend on it — are undisturbed.

The package declares `Conflicts: coreutils` so that **no package manager installs it by accident**. Resolving it from a repository would mean removing something apt and dpkg themselves need, and they will refuse. Installing it is a deliberate act:

```sh
sudo dpkg -i --force-conflicts @PACKAGE_ID@_@VERSION@_iphoneos-arm64.deb
```

> **Do not run `apt install` on this .deb.** apt treats a local file as an explicit request, honours the conflict, and removes coreutils *first* — which deletes `rm`, the one program dpkg insists on finding in `PATH`. The transaction then dies with your device holding no coreutils at all. If that happens, the GNU binaries are stashed in `usr/libexec/uutils/gnu-backup`; copy them back to `usr/bin` over SSH.

**Removing it** works normally — verified on device:

```sh
sudo dpkg --remove @PACKAGE_ID@                            # postrm puts the GNU binaries back
sudo apt-get install --reinstall coreutils system-cmds     # and dpkg's bookkeeping with them
```

The package's `preinst` stashes the GNU binaries before the takeover and its `postrm` copies them back the moment dpkg deletes this package's files, so `rm` is in place before anything needs it.

While it is installed, apt refuses to do anything else — that is the `Conflicts` doing its job, and it clears the moment you remove this package. Use `dpkg -i` / `dpkg --remove` in the meantime.

## No fork(), no privilege escalation

Every child goes through `posix_spawn()`; `fork()`, `setuid()`, `setgid()` and `setgroups()` are defined to fail rather than imported, and the build refuses a binary that carries any of them. Children inherit the credentials the shell already had. Lowering still works — `nice` reduces its own priority, `timeout` signals the child's process group.

## About this build

Upstream [`uutils/coreutils@@UPSTREAM_SHORT@`](https://github.com/uutils/coreutils/commit/@UPSTREAM_REF@), built from the `feat_os_unix_musl` utility set, plus the patches in [`patches/`](https://github.com/owngoal-dev/coreutils/tree/@TAG@/patches): `timeout` spawns without a `pre_exec` closure; `fork()` and the credential syscalls are denied; `chroot` is dropped; and the `xattr` crate is taught that iOS has Darwin's extended attributes, without which `cp -a` fails with *unsupported platform*.

Not included: `chroot` (needs root and the denied syscalls), `stdbuf` (its helper library would have to be injected into a platform-signed process), `chcon` and `runcon` (SELinux). `getent` is not a uutils utility — the GNU package carried Procursus' build of it, so a small POSIX-sh stand-in ships in its place for the `passwd`, `group`, `hosts`, `services` and `protocols` lookups the shells do.

Verify your download against `SHA256SUMS`.

**Full changelog**: https://github.com/owngoal-dev/coreutils/commits/@TAG@
