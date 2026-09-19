#!/usr/bin/env python3
"""Apply a patch exactly, tolerating only uniquely anchored outer-context drift."""

import re
import subprocess
import sys
from pathlib import Path


HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)\n$")


def compact_context(patch: str, source: Path) -> str:
    lines = patch.splitlines(keepends=True)
    output = []
    path = None
    index = 0
    while index < len(lines):
        line = lines[index]
        if line.startswith("--- a/"):
            path = source / line[6:].rstrip("\n")
        elif line == "--- /dev/null\n":
            path = None
        match = HUNK.match(line)
        if not match:
            output.append(line)
            index += 1
            continue
        end = index + 1
        while end < len(lines) and lines[end].startswith((" ", "+", "-", "\\")):
            end += 1
        body = lines[index + 1:end]
        # New files must still apply in full. No path searches or renames.
        if path is None:
            output.extend(lines[index:end])
            index = end
            continue
        if not path.is_file():
            raise ValueError(f"upstream moved or removed {path.relative_to(source)}")
        leading = 0
        while leading < len(body) and body[leading].startswith(" "):
            leading += 1
        trailing = 0
        while trailing < len(body) and body[-1-trailing].startswith(" "):
            trailing += 1
        front = max(0, leading - 1)
        back = max(0, trailing - 1)
        kept = body[front:len(body)-back if back else None]
        old = "".join(item[1:] for item in kept if item.startswith((" ", "-")))
        # Repeated anchors are an error even if git could choose the nearest
        # line number. Never silently accept changed code or discard a hunk.
        if not old or path.read_text().count(old) != 1:
            raise ValueError(f"changed or ambiguous patch anchor in {path.relative_to(source)}")
        old_count = sum(item.startswith((" ", "-")) for item in kept)
        new_count = sum(item.startswith((" ", "+")) for item in kept)
        output.append(
            f"@@ -{int(match[1])+front},{old_count} "
            f"+{int(match[3])+front},{new_count} @@{match[5]}\n"
        )
        output.extend(kept)
        index = end
    return "".join(output)


def apply(source: Path, patch: Path) -> None:
    content = patch.read_text()
    command = ["git", "-C", str(source), "apply", "--whitespace=nowarn"]
    check = subprocess.run(command + ["--check", "-"], input=content, text=True, capture_output=True)
    if check.returncode:
        content = compact_context(content, source)
        subprocess.run(command + ["--check", "-"], input=content, text=True, check=True)
        print(f"{patch.name}: using unique anchors after outer-context drift")
    subprocess.run(command + ["-"], input=content, text=True, check=True)


if __name__ == "__main__":
    try:
        apply(Path(sys.argv[1]), Path(sys.argv[2]))
    except (ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f"error: {error}")
