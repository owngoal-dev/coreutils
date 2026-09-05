#!/usr/bin/env bash
# Fetch and build RootHide's pinned Mach-O import rewriter.

set -Eeuo pipefail

if [[ "$#" -ne 1 ]]; then
    echo "usage: $0 <work-dir>" >&2
    exit 64
fi

work_dir="$1"
repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

# shellcheck source=../configuration/upstream.env
source "$repository_root/configuration/upstream.env"
: "${SYMREDIRECT_REPO:?}" "${SYMREDIRECT_REF:?}"

for tool in clang++ git; do
    command -v "$tool" >/dev/null || { echo "error: $tool is not installed" >&2; exit 69; }
done

mkdir -p "$work_dir"
if [[ ! -d "$work_dir/.git" ]]; then
    git -C "$work_dir" init --quiet
    git -C "$work_dir" remote add origin "$SYMREDIRECT_REPO"
fi
git -C "$work_dir" remote set-url origin "$SYMREDIRECT_REPO"

if [[ "$(git -C "$work_dir" rev-parse HEAD 2>/dev/null || true)" != "$SYMREDIRECT_REF" ]]; then
    echo "fetching symredirect at $SYMREDIRECT_REF" >&2
    shared_source="${ROOTHIDE_SOURCE:-$repository_root/../libroothide}"
    if git -C "$shared_source" cat-file -e "$SYMREDIRECT_REF^{commit}" 2>/dev/null; then
        git -C "$work_dir" fetch --quiet --depth 1 --force "$shared_source" "$SYMREDIRECT_REF"
    else
        git -C "$work_dir" fetch --quiet --depth 1 --force origin "$SYMREDIRECT_REF"
    fi
    git -C "$work_dir" checkout --quiet --detach FETCH_HEAD
fi

[[ "$(git -C "$work_dir" rev-parse HEAD)" == "$SYMREDIRECT_REF" ]] || {
    echo "error: symredirect checkout does not match pinned commit" >&2
    exit 65
}
git -C "$work_dir" diff --quiet HEAD -- symredirect.cpp vroot.h || {
    echo "error: symredirect source differs from pinned commit" >&2
    exit 65
}

clang++ -std=c++11 -O2 -w -o "$work_dir/symredirect-host" "$work_dir/symredirect.cpp"
"$work_dir/symredirect-host" >/dev/null
printf '%s\n' "$work_dir/symredirect-host"
