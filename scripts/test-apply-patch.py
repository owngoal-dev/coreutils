#!/usr/bin/env python3
"""Exercise context drift, rejection, and atomicity against real git apply."""
import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("patcher", Path(__file__).with_name("apply-patch.py"))
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)

PATCH = """diff --git a/example b/example
--- a/example
+++ b/example
@@ -1,7 +1,7 @@
 // unrelated old comment
 opening
 anchor before
-old_call();
+new_call();
 anchor after
 closing
 // another old comment
"""
ORIGINAL = "// unrelated old comment\nopening\nanchor before\nold_call();\nanchor after\nclosing\n// another old comment\n"


class ApplyTests(unittest.TestCase):
    def run_patch(self, text, succeeds):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            target = root / "example"
            target.write_text(text)
            patch = root / "change.patch"
            patch.write_text(PATCH)
            if succeeds:
                patcher.apply(root, patch)
                self.assertEqual(target.read_text(), text.replace("old_call();", "new_call();"))
            else:
                with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                    patcher.apply(root, patch)
                self.assertEqual(target.read_text(), text)

    def test_exact(self):
        self.run_patch(ORIGINAL, True)

    def test_unrelated_comment_drift(self):
        self.run_patch(ORIGINAL.replace("old comment", "new comment"), True)

    def test_changed_code_rejected(self):
        self.run_patch(ORIGINAL.replace("old_call", "different_call"), False)

    def test_ambiguous_anchor_rejected(self):
        self.run_patch(ORIGINAL.replace("old comment", "new comment") * 2, False)

    def test_adjacent_semantic_change_rejected(self):
        self.run_patch(ORIGINAL.replace("anchor before", "different guard"), False)


if __name__ == "__main__":
    unittest.main()
