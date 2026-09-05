#!/usr/bin/env bash
# Audit the final executable, including the package after symredirect.
set -Eeuo pipefail

[[ "$#" -eq 1 ]] || { echo "usage: $0 <executable>" >&2; exit 64; }
symbols="$(nm -m "$1")"
forbidden="$(grep -E 'external _+(fork|vfork|exec[lv][epP]*|fexecve)([ $]|$)' <<<"$symbols" || true)"
[[ -z "$forbidden" ]] || {
    echo "error: $1 carries fork/exec symbols:" >&2
    printf '%s\n' "$forbidden" >&2
    exit 65
}
grep -qE 'external _posix_spawnp?( |$)' <<<"$symbols" || {
    echo "error: $1 does not import posix_spawn" >&2
    exit 65
}
if grep -qE '\(undefined\).*external _(setuid|seteuid|setreuid|setgid|setegid|setregid|setgroups|initgroups)( |$)' <<<"$symbols"; then
    echo "error: $1 imports a privilege-changing syscall" >&2
    exit 65
fi
echo "==> no fork/exec or credential-changing imports; posix_spawn is present" >&2
