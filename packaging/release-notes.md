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

## Ordinary spawn, no fork or exec

Every child goes through `posix_spawn()`; `fork()`, `setuid()`, `setgid()` and `setgroups()` are defined to fail rather than imported, and the build refuses a binary that carries any of them. Children inherit the credentials the shell already had. Lowering still works — `nice` reduces its own priority, `timeout` signals the child's process group.

`env`, `nice` and `nohup` now spawn and wait instead of calling exec. The build rejects exec imports and checks that launchers never request `POSIX_SPAWN_SETEXEC`. `timeout` explicitly unblocks its termination signals in the child so expiry stops the command promptly.

The exec replacement has compatibility costs for `env`, `nice` and `nohup`:

- A waiting wrapper remains alive: the shell's job PID is the wrapper, the command has its own PID, and nested wrappers add process overhead.
- SIGKILL/SIGSTOP sent only to the wrapper cannot be forwarded; the command may keep running. Fault signals such as SIGSEGV/SIGABRT are not relayed either. Use process-group signals for the whole job, while accounting for possible duplicate delivery when the child receives both the group signal and the wrapper's relay.
- Only the waiting parent's stdin/stdout/stderr copies close after spawn. Other inherited descriptors can keep pipes or descriptor-owned locks alive until the wrapper exits.
- The wrapper installs a SIGCHLD handler before spawning to keep its child waitable. Spawn resets that handler to default in the child, replacing any originally inherited SIGCHLD ignore; programs relying on that ignore must set it again.

Child exit/signal status is preserved, but PID identity and signal timing are not equivalent to exec. Host regressions and iOS build/package checks passed; this change has not been installed and tested on a device, and does not establish that bootstrap-wide repair hooks can be removed.

## About this build

Upstream [`uutils/coreutils@@UPSTREAM_SHORT@`](https://github.com/uutils/coreutils/commit/@UPSTREAM_REF@), built from the `feat_os_unix_musl` utility set, plus the patches in [`patches/`](https://github.com/owngoal-dev/coreutils/tree/@TAG@/patches): `timeout` spawns without a `pre_exec` closure; `fork()` and the credential syscalls are denied; `chroot` is dropped; and the `xattr` crate is taught that iOS has Darwin's extended attributes, without which `cp -a` fails with *unsupported platform*.

Not included: `chroot` (needs root and the denied syscalls), `stdbuf` (its helper library would have to be injected into a platform-signed process), `chcon` and `runcon` (SELinux). `getent` is not a uutils utility — the GNU package carried Procursus' build of it, so a small POSIX-sh stand-in ships in its place for the `passwd`, `group`, `hosts`, `services` and `protocols` lookups the shells do.

Verify your download against `SHA256SUMS`.

**Full changelog**: https://github.com/owngoal-dev/coreutils/commits/@TAG@

This packaging revision updates RootHide compatibility checks and signing.
CLI startup passes bootstrap paths to payloads that use the physical filesystem;
RootHide virtual-filesystem utilities retain their official import rewriting.
RootHide device validation is pending; a successful build is not a claim that
all interactive runtime paths have been tested.
