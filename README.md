# uutils coreutils for jailbroken iOS

[uutils coreutils](https://github.com/uutils/coreutils) — the GNU core
utilities reimplemented in Rust — cross-compiled for iOS 15+ and packaged for
both roothide and rootless bootstraps from one arm64 build. It **replaces** the
GNU coreutils your bootstrap ships.

Install from the [OwnGoal Studio repository](https://apt.owngoal.dev), or grab
a `.deb` from [Releases](https://github.com/owngoal-dev/coreutils/releases).

| bootstrap | architecture field | installs under |
| --------- | ------------------ | -------------- |
| rootless (Dopamine, palera1n rootless) | `iphoneos-arm64` | `/var/jb` |
| roothide (RootHide Dopamine) | `iphoneos-arm64e` | the randomized jbroot |

The architecture field names the **layout, not the CPU**. Both packages carry
the same arm64 binary. Ask the device which it wants: `dpkg --print-architecture`.

## Installing

The package declares `Conflicts: coreutils` so no package manager installs it by
accident — resolving it from a repository would mean removing something apt and
dpkg themselves depend on, and they refuse. Installing is deliberate:

```sh
sudo dpkg -i --force-conflicts wiki.qaq.uutils_0.11.0_iphoneos-arm64.deb
```

> **Never `apt install` this .deb.** apt treats a local file as an explicit
> request, honours the conflict, and removes coreutils first — which deletes
> `rm`, the one program dpkg insists on finding in `PATH`, and the transaction
> dies with the device holding no coreutils at all.

Removing it works normally — the package's `postrm` restores the GNU binaries
from the stash its `preinst` made, so `rm` is in place before anything needs it:

```sh
sudo dpkg --remove wiki.qaq.uutils
sudo apt-get install --reinstall coreutils system-cmds
```

While it is installed apt refuses to do anything else — the `Conflicts` is
standing, by design. Use `dpkg -i` / `dpkg --remove` until you remove it.

## How the swap stays safe

Three fields, each doing a different job:

```
Replaces:  coreutils, system-cmds, ...   the mechanism: unpack over, delete nothing
Conflicts: coreutils, ...                the lock: no package manager does this by accident
Provides:  md5sum, sha1sum, dirname, kill, mktemp
```

`Provides: coreutils` is deliberately **absent** — alongside the `Replaces` it
would tell apt this package obsoletes the GNU one, and apt would remove it. The
GNU package staying registered is what keeps `apt`, `dpkg`, Sileo and
`darwintools` satisfied.

Nothing the GNU package gave you disappears quietly: `/etc/profile.d/coreutils.sh`
ships with the same content, and `getent` — which is not a uutils utility, but
which `zsh`, `bash` and `fish` look up — is replaced by a small POSIX-sh
stand-in.

```
<prefix>/usr/bin/coreutils          multi-call binary
<prefix>/usr/bin/<util>             ~106 symlinks to it, right beside it
<prefix>/usr/bin/getent             stand-in
<prefix>/etc/profile.d/coreutils.sh taken over verbatim
```

`coreutils ls -l` reaches any utility without going through PATH.

## No fork(), no privilege escalation

Forking a process that has the Objective-C runtime and Foundation loaded is not
safe on iOS. Every child goes through `posix_spawn()`, and `fork()`, `setuid()`,
`setgid()` and `setgroups()` are *defined to fail* rather than imported — the
build refuses a binary that carries any of them, and `make build` proves it by
running the utilities that spawn under lldb with a breakpoint on `fork`.
Children inherit the credentials the shell already had. Lowering still works:
`nice` reduces its own priority, `timeout` signals the child's process group.

## Not included

`chroot` (needs root and the credential syscalls this binary denies), `stdbuf`
(its helper library would have to be injected into a platform-signed process),
`chcon` and `runcon` (SELinux).

## Build it yourself

```sh
make check     # scripts, config, patch set, takeover declaration
make debs      # both packages + SHA256SUMS
make install   # apt-swap it onto a device over SSH, then smoke-test
```

Needs Xcode, `rustup`, `ldid`, `dpkg` and `clang++`. See [`AGENTS.md`](AGENTS.md)
for the contract this repository follows.

## License

The packaging in this repository is MIT. uutils coreutils itself is MIT, and
ships under its own terms.
