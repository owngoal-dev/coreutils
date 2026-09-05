#!/usr/bin/env python3
"""Bounded behavior checks for the Apple env/nice/nohup spawn wrapper."""
import os
import platform
import re
import shlex
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import tempfile
import time


PROBE = r'''
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>

static volatile sig_atomic_t received;
static void handler(int sig) { received = sig; }

int main(int argc, char **argv) {
    if (argc < 2) return 99;
    if (!strcmp(argv[1], "flags")) {
        posix_spawnattr_t attr;
        if (posix_spawnattr_init(&attr)) return 99;
        int result = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETEXEC);
        posix_spawnattr_destroy(&attr);
        return result; /* Configure only: never spawn with SETEXEC. */
    }
    if (!strcmp(argv[1], "exit")) return atoi(argv[2]);
    if (!strcmp(argv[1], "args")) {
        for (int i = 0; i < argc; i++) printf("%s\n", argv[i]);
        return 0;
    }
    if (!strcmp(argv[1], "inspect")) {
        struct sigaction hup, pipe;
        sigset_t mask;
        sigaction(SIGHUP, NULL, &hup);
        sigaction(SIGPIPE, NULL, &pipe);
        sigprocmask(SIG_BLOCK, NULL, &mask);
        printf("%d %d %d %d %s\n", hup.sa_handler == SIG_IGN,
               pipe.sa_handler == SIG_IGN, sigismember(&mask, SIGUSR1),
               getpriority(PRIO_PROCESS, 0), getenv("SPAWN_PROBE") ?: "absent");
        return 0;
    }
    if (!strcmp(argv[1], "signal")) {
        int sig = argc > 2 ? atoi(argv[2]) : SIGTERM;
        signal(sig, SIG_DFL);
        raise(sig);
        return 99;
    }
    if (!strcmp(argv[1], "eof")) {
        close(STDOUT_FILENO);
        sleep(2);
        return 0;
    }
    if (!strcmp(argv[1], "stop")) {
        printf("%d\n", getpid()); fflush(stdout);
        raise(SIGSTOP);
        puts("continued");
        return 0;
    }
    if (!strcmp(argv[1], "ignoreterm")) {
        signal(SIGTERM, SIG_IGN);
        for (;;) pause();
    }
    if (!strcmp(argv[1], "wait")) {
        signal(SIGUSR1, handler);
        sigset_t mask;
        sigemptyset(&mask);
        sigaddset(&mask, SIGUSR1);
        sigprocmask(SIG_BLOCK, &mask, NULL);
        printf("%d\n", getpid()); fflush(stdout);
        sigemptyset(&mask);
        while (!received) sigsuspend(&mask);
        return 42;
    }
    return 99;
}
'''


def readable(stream):
    with selectors.DefaultSelector() as selector:
        selector.register(stream, selectors.EVENT_READ)
        assert selector.select(5), "timed out waiting for child output"


def main():
    binary = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix="uutils-spawn-") as temporary:
        work = Path(temporary)
        source = work / "probe.c"
        source.write_text(PROBE)
        probe = work / "probe"
        subprocess.run(["clang", "-Wall", "-Werror", str(source), "-o", str(probe)], check=True)
        noexec = work / "noexec"
        noexec.write_text("not executable\n")
        plain = work / "plain"
        plain.write_text("printf 'plain-script\\n'\n")
        plain.chmod(0o755)

        def run(args, expected=0, **kwargs):
            result = subprocess.run([str(binary), *map(str, args)], cwd=work,
                                    capture_output=True, timeout=10, **kwargs)
            assert result.returncode == expected, (args, result.returncode, result.stderr)
            return result.stdout

        for utility in ("env", "nice", "nohup"):
            run([utility, probe, "exit", 37], 37)
            run([utility, "./missing"], 127)
            run([utility, noexec], 126)
            assert run([utility, plain]) == b"plain-script\n"
            for sig in (signal.SIGTERM, signal.SIGKILL):
                run([utility, probe, "signal", sig], -sig)
            info = run([utility, probe, "inspect"]).decode().split()
            if utility == "nohup":
                assert info[0] == "1", info
            if utility == "nice":
                assert int(info[3]) == min(19, os.getpriority(os.PRIO_PROCESS, 0) + 10), info

        assert run(["env", "-a", "renamed", probe, "args", "", "a b", "日本語"]) == (
            "renamed\nargs\n\na b\n日本語\n".encode())
        assert run(["env", "-i", "--ignore-signal=PIPE", "--block-signal=USR1",
                    "SPAWN_PROBE=kept", probe, "inspect"]).decode().split()[1:] == [
                        "1", "1", str(os.getpriority(os.PRIO_PROCESS, 0)), "kept"]
        assert run(["env", "-C", work, "/bin/pwd"]).strip() == str(work.resolve()).encode()
        # A fast child must remain waitable even if the wrapper inherited CHLD ignore.
        run(["env", "--ignore-signal=CHLD", probe, "exit", 23], 23)

        for utility, options in [("env", []), ("nice", []), ("nohup", []),
                                 ("env", ["--ignore-signal=USR1"]),
                                 ("env", ["--block-signal=USR1"])]:
            for sent, expected in [(signal.SIGUSR1, 42), (signal.SIGTERM, -signal.SIGTERM)]:
                completed = False
                process = subprocess.Popen([str(binary), utility, *options, str(probe), "wait"],
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                           start_new_session=True)
                try:
                    readable(process.stdout)
                    child_pid = int(process.stdout.readline())
                    assert child_pid != process.pid, "spawn unexpectedly replaced the parent"
                    process.send_signal(sent)
                    assert process.wait(timeout=5) == expected, (utility, options, sent)
                    try:
                        os.kill(child_pid, 0)
                    except ProcessLookupError:
                        pass
                    else:
                        raise AssertionError("wrapper left its child alive or unreaped")
                    completed = True
                finally:
                    if not completed:
                        try:
                            os.killpg(process.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        process.wait(timeout=5)
                    process.stdout.close()
                    process.stderr.close()

        process = subprocess.Popen([str(binary), "env", str(probe), "stop"],
                                   stdout=subprocess.PIPE, start_new_session=True)
        try:
            readable(process.stdout)
            process.stdout.readline()
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                pid, status = os.waitpid(process.pid, os.WUNTRACED | os.WNOHANG)
                if pid:
                    assert os.WIFSTOPPED(status), status
                    break
                time.sleep(0.01)
            else:
                raise AssertionError("wrapper did not follow child stop")
            process.send_signal(signal.SIGCONT)
            assert process.communicate(timeout=5)[0] == b"continued\n"
            assert process.returncode == 0
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)

        process = subprocess.Popen([str(binary), "env", str(probe), "eof"], stdout=subprocess.PIPE)
        try:
            readable(process.stdout)
            assert process.stdout.read() == b"" and process.poll() is None, "parent retained stdout"
            assert process.wait(timeout=5) == 0
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            process.stdout.close()

        for options, expected in [([], 124), (["--foreground"], 124), (["--preserve-status"], 143)]:
            started = time.monotonic()
            run(["timeout", *options, "0.1", "/bin/sleep", "3"], expected)
            assert time.monotonic() - started < 1.5, "timeout inherited a blocked termination signal"
        run(["timeout", "--foreground", "-k", "0.1", "0.1", probe, "ignoreterm"], 137)
        assert run(["timeout", "1", probe, "inspect"]).decode().split()[2] == "0"
        # sysctl only spawns when the host has no utmpx BOOT_TIME record.
        # This smoke check cannot require that host-dependent fallback.
        assert run(["uptime", "-s"]).strip()
        (work / "lines.txt").write_text("b\na\nc\n")
        probes = [
            ["env", "SPAWN_PROBE=1", "/bin/echo", "spawned"],
            ["nice", "-n", "5", "/bin/echo", "spawned"],
            ["nohup", "/bin/echo", "spawned"],
            # LLDB introduces a HUP into Darwin's sigwait. Disable the timer
            # while tracing the same spawn path; native tests cover expiry.
            ["timeout", "--foreground", "0", "/bin/echo", "spawned"],
            ["sort", "--compress-program=gzip", "-S", "1", "lines.txt"],
            ["split", "--filter=/usr/bin/tee", "-l", "1", "lines.txt"],
            ["install", "-s", "--strip-program=/usr/bin/true", "lines.txt", "installed.txt"],
            ["env", str(plain)],
            ["setexec-control", "flags"],
        ]
        flags_register = "x1" if platform.machine() == "arm64" else "rsi"
        for utility, *arguments in probes:
            entry = work / utility
            if not entry.exists():
                entry.symlink_to(probe if utility == "setexec-control" else binary)
            # Exercise the installed argv[0] entry before tracing the same file.
            subprocess.run([str(entry), *arguments], cwd=work, capture_output=True, timeout=10, check=True)
            commands = [
                "settings set auto-confirm true",
                "settings set target.disable-aslr false",
                # Resolve shared-cache addresses after dyld has finished loading.
                "breakpoint set -n main",
                "process launch --no-stdio -- " + shlex.join(arguments),
                "breakpoint delete 1",
                "breakpoint set -n fork -n vfork -n execve -n execvp -n execvP -n execv -n execl -n execlp -n execle -n execvpe -n fexecve",
                "breakpoint set -n posix_spawn -n posix_spawnp",
                "breakpoint command add -o continue 3",
                "breakpoint set -n posix_spawnattr_setflags",
                # Read registers in LLDB's Python, without evaluating code in the
                # inferior. Return true to stop on Darwin's SETEXEC (0x0040).
                "breakpoint command add -s python -o 'flags = frame.FindRegister(\"" + flags_register + "\").GetValueAsUnsigned(); print(\"SPAWN_FLAGS\", flags); return bool(flags & 0x0040)' 4",
                "continue",
                'script print("FORBIDDEN_HITS", lldb.target.FindBreakpointByID(2).GetHitCount())',
                'script print("SPAWN_HITS", lldb.target.FindBreakpointByID(3).GetHitCount())',
                "quit",
            ]
            command = ["lldb", "--batch"]
            for item in commands:
                command.extend(["-o", item])
            with subprocess.Popen([*command, str(entry)], cwd=work, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, text=True) as debugger:
                try:
                    output = debugger.communicate(timeout=30)[0]
                except subprocess.TimeoutExpired:
                    debugger.send_signal(signal.SIGINT)
                    try:
                        output = debugger.communicate(timeout=5)[0]
                    except subprocess.TimeoutExpired:
                        debugger.kill()
                        output = debugger.communicate()[0]
                    raise AssertionError(f"lldb timed out:\n{output}")
            result = debugger
            assert result.returncode == 0, output
            assert re.search(r"^FORBIDDEN_HITS 0$", output, re.M), output
            flags = [int(value) for value in re.findall(r"^SPAWN_FLAGS ([0-9]+)$", output, re.M)]
            if utility == "setexec-control":
                assert flags == [0x0040] and "stop reason = breakpoint 4." in output, output
                print("  SETEXEC negative control: flag detected before the setter ran", flush=True)
                continue
            assert flags and all(value & 0x0040 == 0 for value in flags), output
            assert re.search(r"^SPAWN_HITS [1-9][0-9]*$", output, re.M), output
            assert re.search(r"Process [0-9]+ exited with status = 0 ", output), output
            if utility == "sort":
                assert run(probes[4]) == b"a\nb\nc\n"
            print(f"  {utility}: posix_spawn reached, no fork/exec/SETEXEC, exited 0", flush=True)

        print("spawn behavior: argv/env/cwd, errors, scripts, signals, job control and pipe EOF passed")


if __name__ == "__main__":
    main()
