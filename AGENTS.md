# uutils coreutils — Agent Notes

[uutils coreutils](https://github.com/uutils/coreutils) is packaged for
jailbroken iOS 15+, for both roothide and rootless bootstraps, **as a
replacement for the GNU coreutils the bootstrap ships**.

This is a packaging repository, not a fork. It fetches a pinned upstream
commit, applies `patches/`, and cross-compiles one arm64 multi-call binary that
backs both packages.

## Hard rules

- **Three fields, each load-bearing in a different direction.** Get any of them
  wrong and the failure mode is a device with no coreutils and no way for apt to
  install the fix.
  - `Replaces: coreutils` is the mechanism. It lets dpkg unpack these files
    *over* the GNU package's copies and hand the paths over, with nothing
    deleted, so `rm` never leaves PATH. dpkg says so out loud:
    `Replacing files in old package coreutils (9.5) ...`
  - `Conflicts: coreutils` is the front door lock, and it is deliberate.
    Resolving this package from a repository would mean removing something
    `apt`, `dpkg` and Sileo all depend on, so they refuse — which is the point:
    nobody installs it by accident. The supported install is an explicit
    `dpkg -i --force-conflicts <deb>`.
  - `Provides: coreutils` must **not** be there. Alongside the `Replaces` it
    tells apt this package *obsoletes* the GNU one, and apt removes it even with
    no `Conflicts` in sight. Only the aliases the GNU package also provided are
    kept (`md5sum`, `sha1sum`, `dirname`, `kill`, `mktemp`).

  `make check` and `package-deb.sh` enforce all three.
- **Never install this with apt.** apt handed a local `.deb` treats it as an
  explicit request and honours the `Conflicts` by removing coreutils first:

  ```
  Removing coreutils (9.5) ...
  dpkg: warning: 'rm' not found in PATH or not executable
  dpkg: error: 1 expected program not found in PATH or not executable
  ```

  dpkg keeps a short list of programs it expects in PATH, `rm` is on it, and the
  transaction dies halfway with the device stripped. `dpkg -i --force-conflicts`
  skips the resolution and goes straight to the unpack.
- **Simulate before installing.** `install-device.sh` asks
  `apt-get install --simulate` what apt would have done and reports it, then
  installs with `dpkg -i --force-conflicts` regardless. The simulation costs
  nothing and it is how a change in apt's resolution shows up as a line in the
  log rather than as a device to repair by hand over SSH.
- **Replacing coreutils means dpkg's own tools change underneath it.** Every
  maintainer script on the system runs `rm`, `mv`, `chmod`, `install`, `test`
  and `sort` from this package; if one of them misbehaves, apt cannot install
  the fix. So the device test is not "do the utilities run" — it is
  `apt-get update`, then a real package installed and removed, after the swap.
  `install-device.sh` stashes the GNU binaries in
  `/var/mobile/gnu-coreutils-backup` before it starts, and asserts afterwards
  that `rm` is still on PATH. Going back is **not** a one-liner: once `Replaces`
  has taken the paths, reinstalling coreutils only prints `Replaced by files in
  installed package wiki.qaq.uutils` and skips them — verified on device. That
  is what `preinst` and `postrm` are for. `preinst` stashes the GNU binaries
  into `usr/libexec/uutils/gnu-backup`, deliberately outside this package's file
  list so dpkg will not delete it, and `postrm` copies them back the moment dpkg
  deletes ours. Without that pair the package installs and cannot be removed.
- **Do not silently drop something the GNU package provided.** It carried
  Procursus' `getent`, which is not a uutils utility and which `zsh`, `bash`,
  `fish` and `ex-vi` look up; `packaging/getent.sh` stands in for it. It also
  owned `/etc/profile.d/coreutils.sh`, so this package ships that same path with
  the same content. The stand-in is pure shell built-ins on purpose: `awk` and
  `grep` are separate packages a bootstrap need not have, and it has to work on
  a system whose coreutils just changed.
- **Nothing may reach `fork()`.** This binary loads the Objective-C runtime and
  Foundation, and forking such a process is not safe on iOS. Three gates, all
  automatic:
  - `build-ios.sh` audits the prepared source: no direct `fork`/`vfork`/`daemon`
    call, and no `pre_exec`, `before_exec`, `uid`, `gid` or `groups` on a
    `Command` — those five are what make `std` fall back to `fork()` + `exec()`
    instead of `posix_spawn()`. It scans the files importing
    `std::os::unix::process::CommandExt`; importing the trait is fine on its
    own, because `chroot`, `nice`, `nohup` and `runcon` only want its `exec()`,
    which replaces the process image and never forks. `timeout` is the one
    upstream case and must stay guarded by `#[cfg(not(target_vendor =
    "apple"))]`.
  - `build-ios.sh` and `package-deb.sh` reject a Mach-O carrying `_fork` or
    `_vfork` and require `posix_spawn`.
  - `verify-no-fork.sh` builds the same prepared source for the host — the
    patches key off `target_vendor = "apple"`, which is equally true there — and
    runs `env`, `nice`, `timeout` and `sort --compress-program` under lldb with
    breakpoints on `fork` and `vfork`. `make build` runs it.
  `_pthread_atfork` stays and is expected: it is the `rand` crate registering a
  reseeding handler that can never fire.
- **Nothing escalates privilege.** Children come from `posix_spawn()` and
  inherit the credentials this process was launched with; no utility re-assumes
  an identity. `build-ios.sh` and `package-deb.sh` reject a Mach-O importing
  `setuid`, `seteuid`, `setreuid`, `setgid`, `setegid`, `setregid`, `setgroups`
  or `initgroups`, and `patches/0003` drops `chroot` from the feature set
  because it was the only caller (and on iOS it needs root and a root
  filesystem view the bootstrap does not have). Lowering is fine and stays:
  `nice` reduces its own priority, and `timeout` calls `setpgid` so it can
  signal the child's process group on expiry, exactly as GNU does. `_setsid` is
  an import `std` carries for a `Command` option no utility sets.
- Pin `UPSTREAM_REF` to the full commit behind the newest stable upstream
  release. The daily workflow updates the pin, proves the patches apply, then
  tags and releases it.
- Keep upstream changes as small patches under `patches/`; never vendor source.
  Dependency patches live in `patches/dependencies/` and are applied to the
  crate the lockfile already pinned, unpacked from the registry cache and handed
  back with `--config patch.crates-io.<crate>.path=...` — the same shape codex
  uses for `rusty_v8`, and the reason there is still no fork of anything here.
- `iphoneos-arm64` means rootless and installs under `/var/jb`;
  `iphoneos-arm64e` means roothide and installs unprefixed, where dpkg maps the
  tree into the randomized jbroot. Both CPU slices are plain arm64.
- **The roothide binary must go through `symredirect`, the rootless one must
  not.** RootHide shows its jbroot as `/` to the shell; a plain binary opens the
  real iOS root. For file utilities that is not cosmetic — `ls /etc` has to mean
  what the shell means. `package-deb.sh` runs RootHide's pinned rewriter on the
  arm64e binary before signing and proves the `libvrootapi` load command exists,
  and proves it is absent on arm64.
- `configuration/version.txt` is the only package-version source, and
  `prepare-source.sh` refuses a tree whose Cargo workspace version disagrees.

- `CLAUDE.md` must remain a symlink to `AGENTS.md`.
- Test by installing a package, never by copying the binary to `/var/mobile`: a
  copied binary runs with its entitlements ignored.
- Before any push or release, read the diff, staged package tree, and binary
  strings for credentials, private paths, device identifiers, hostnames, and
  addresses. Publish only through the Release workflow.

## Port

Upstream needs very little to build for iOS: it has 120 `target_vendor =
"apple"` cfgs and no `target_os = "macos"` ones, so iOS takes the Apple paths
already there; its locales are `include_str!`-embedded, so no runtime data file
and no bootstrap-path derivation; and it calls `fork()` nowhere.

- `0001-ios-timeout-spawn-without-pre-exec.patch` — `timeout` was the only
  place attaching a `pre_exec` closure to a `Command`, which is what pushes
  `std` off `posix_spawn()` onto `fork()` + `exec()`. Compiled out on Apple.
  `posix_spawn()` already clears the child's signal mask and resets SIGPIPE;
  what is given up is inherited state (a SIGPIPE ignore, a closed stdin, or a
  SIGTTIN/SIGTTOU ignore that `timeout`'s *own* parent had set) being fixed up
  in the child.
- `0002-ios-deny-fork-and-credential-syscalls.patch` — defines `fork()`,
  `setuid()`, `setgid()` and `setgroups()` in the binary instead of importing
  them, each returning `EPERM`, so `std`'s unused fork fallback (and the child
  half that would apply a `Command`'s uid/gid/groups) cannot call the real ones.
  Under upstream's `lto = "fat"` profile the definitions inline and the imports
  disappear from the Mach-O entirely, which is what the symbol gates check.
- `0003-ios-drop-chroot-no-privilege-escalation.patch` — removes `chroot` from
  `feat_require_unix_core`. Cargo features cannot be subtracted, so the list
  itself is patched; a daily rebase surfaces it if upstream reshapes the set.
- `dependencies/xattr-0001-support-ios.patch` — the `xattr` crate's platform
  table lists macOS but not iOS, so it compiles its `unsupported` fallback and
  every call fails at runtime. That surfaces as `cp: setting attributes for
  '...': unsupported platform` — i.e. `cp -a` is broken without this. iOS has
  the same Darwin `getxattr`/`setxattr`, so the fix is the platform list, the
  `rustix` target gate in `Cargo.toml`, and keying `ENOATTR` on
  `target_vendor = "apple"` rather than `target_os = "macos"`.

`stdbuf` is excluded via upstream's own `feat_os_unix_musl` set: it links a
cdylib whose command line carries GNU ld's `-z defs`, which `ld64` rejects, and
`DYLD_INSERT_LIBRARIES` does not apply to a platform-signed process, so it could
not work on iOS anyway. `chcon`/`runcon` need SELinux.

## Layout

```
<prefix>/usr/bin/coreutils          the multi-call binary
<prefix>/usr/bin/<util>             ~106 symlinks -> coreutils, beside it
<prefix>/usr/bin/getent             POSIX-sh stand-in, not a uutils utility
<prefix>/etc/profile.d/coreutils.sh the GNU package's file, taken over verbatim
```

Dispatch is pure `argv[0]` on Apple targets (`src/common/validation.rs` only
consults the kernel's `execfn` on Linux), so symlinks are enough and nothing
reads `current_exe()`. The utility list is derived from `CARGO_FEATURES` with
the same `cargo tree` query upstream's `GNUmakefile` uses, so it follows the
feature set instead of a hardcoded list; `test` also installs as `[`.

## Build and verify

```sh
make check         # scripts, config, patch set, takeover declaration
make debs          # both packages + SHA256SUMS; runs the fork verifier
make install       # apt-swap it onto a device and smoke-test, apt included
```

`make install` takes `DEVICE_HOST`, `DEVICE_PORT`, `DEVICE_USER` and
`DEVICE_SUDO_PASSWORD`. Over USB, forward sshd first: `iproxy 4422:22 &`.

## OwnGoalPackages

Release first, then add the manifest entry: the APT build fails if an entry has
no release. Tag `vX.Y.Z`, non-draft, non-prerelease; assets ending in
`iphoneos-arm64.deb` / `iphoneos-arm64e.deb` plus `SHA256SUMS` of bare names.
