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

## Ordinary posix_spawn only

Every child goes through ordinary `posix_spawn()`. The build and package
checks reject fork/exec imports, and the host runtime checks also reject
`POSIX_SPAWN_SETEXEC`. `env`, `nice` and `nohup` spawn and wait through one
shared implementation. `timeout` uses the same spawn primitive with an
explicit child signal mask; the remaining launchers use Rust's spawn path.
No bootstrap forkfix or exec repair is required by these callsites.

Children inherit the caller's credentials. `fork()`, `setuid()`, `setgid()` and
`setgroups()` remain defined to fail, preventing Rust's unused fallback from
reaching those syscalls. `nice` still adjusts priority and `timeout` still
signals the child's process group.

### Compatibility costs

Replacing exec with spawn changes `env`, `nice` and `nohup` in observable ways:

- **An extra process stays alive.** The shell's job PID (including `$!`) is the
  waiting wrapper, not the command's PID. The command also has a different
  parent PID. Each nested wrapper adds a process and its resource overhead;
  scripts that depend on exec preserving PID identity need adjustment.
- **Controlling only the wrapper does not always control the command.**
  SIGKILL/SIGSTOP cannot be forwarded. Killing just the wrapper can leave the
  command running; stopping it can leave the command running too. Fault signals
  such as SIGSEGV and SIGABRT are also not relayed. Use process-group signals
  when controlling the whole job.
- **Signal delivery is not identical to exec.** The wrapper relays ordinary
  control signals and follows child stop/exit status, but adds delivery delay.
  A signal sent to the whole group can reach the child directly and again via
  the wrapper, so handlers must not assume exactly one delivery. Reported exit
  and signal status does not restore the original PID/job-control semantics.
- **Some descriptors stay open longer.** The waiting parent closes its copies
  of stdin, stdout and stderr. Other inherited descriptors remain open until
  it exits, which can delay EOF or release of descriptor-owned locks even if
  the command closes its copy.
- **SIGCHLD ignore is an exception to inheritance.** The wrapper installs a
  SIGCHLD handler before spawning so its child remains waitable. Spawn resets
  that caught handler to the default disposition in the child, even if SIGCHLD
  was originally ignored. Programs relying on that ignore must set it again.

These packages passed host regression tests and iOS build/package checks; this
change has not been installed and tested on a device. Those checks do not
establish that bootstrap-wide forkfix or exec repair hooks can be removed.

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

Needs Xcode (including LLDB), `rustup`, Python 3, `ldid`, `dpkg` and `clang++`. See [`AGENTS.md`](AGENTS.md)
for the contract this repository follows.

## License

The packaging in this repository is MIT. uutils coreutils itself is MIT, and
ships under its own terms.
