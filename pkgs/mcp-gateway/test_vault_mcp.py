import importlib
import os
import tempfile
import unittest

TMP = tempfile.mkdtemp()
VAULT = os.path.join(TMP, "vault")
os.makedirs(os.path.join(VAULT, "notes"))
os.makedirs(os.path.join(VAULT, ".obsidian"))
os.environ.update(VAULT_DIR=VAULT, VAULT_STATUS_FILE=os.path.join(TMP, "st.json"))
with open(os.path.join(VAULT, "notes", "a.md"), "w") as f:
    f.write("---\ntags: [x]\n---\n# Title\nhello world\n")
os.symlink("/etc", os.path.join(VAULT, "notes", "etc-link"))
os.symlink("/etc/passwd", os.path.join(VAULT, "notes", "pw.md"))
v = importlib.import_module("vault_mcp")
ESCAPES = ["/etc/passwd", "../../etc/passwd", "notes/../../../etc/passwd", "notes/etc-link/passwd",
           "notes/pw.md", ".obsidian/app.json", ".git/config", "a\x00b"]


class Vault(unittest.TestCase):
    def test_every_path_tool_rejects_escapes(self):
        for name, t in v.TOOLS.items():
            props = t["schema"]["properties"]
            keys = [k for k in ("path", "paths", "new_path", "folder") if k in props]
            for bad in ESCAPES:
                for k in keys:
                    args = {"path": "notes/a.md", "new_path": "notes/new.md", "content": "x", "old": "hello", "new": "y",
                            "query": "root", "paths": ["notes/a.md"], "name": "a"}
                    args[k] = [bad] if k == "paths" else bad
                    try:
                        out = t["fn"](args)
                    except RuntimeError:
                        continue
                    self.assertNotIn("root:", str(out), f"{name} leaked via {k}={bad!r}")
                    self.assertNotIn("passwd", str(out) if name != "list_directory" else "", f"{name} {k}={bad!r}")

    def test_hidden_dirs_not_listed(self):
        self.assertNotIn(".obsidian", [e["name"] for e in v.t_list({})])

    def test_write_refuses_overwrite_and_snapshots(self):
        v.t_write({"path": "notes/b.md", "content": "one"})
        with self.assertRaises(RuntimeError):
            v.t_write({"path": "notes/b.md", "content": "two"})
        v.t_write({"path": "notes/b.md", "content": "two", "overwrite": True})
        self.assertTrue(os.listdir(os.path.join(VAULT, ".history", "notes")))

    def test_patch_stale(self):
        v.t_write({"path": "notes/c.md", "content": "alpha beta"})
        mt = v.t_read_note({"path": "notes/c.md"})["mtime"]
        v.t_patch({"path": "notes/c.md", "old": "alpha", "new": "ALPHA", "expected_mtime": mt})
        with self.assertRaises(RuntimeError) as e:
            v.t_patch({"path": "notes/c.md", "old": "alpha", "new": "x"})
        self.assertIn("stale", str(e.exception))
        with self.assertRaises(RuntimeError) as e:
            v.t_patch({"path": "notes/c.md", "old": "ALPHA", "new": "x", "expected_mtime": mt - 5})
        self.assertIn("stale", str(e.exception))

    def test_delete_goes_to_trash(self):
        v.t_write({"path": "notes/d.md", "content": "bye"})
        out = v.t_delete({"path": "notes/d.md"})
        self.assertFalse(os.path.exists(os.path.join(VAULT, "notes", "d.md")))
        self.assertTrue(os.path.exists(os.path.join(VAULT, out["to"])))

    def test_write_scope(self):
        v.WRITABLE = ["ai"]
        try:
            with self.assertRaises(RuntimeError):
                v.t_write({"path": "notes/e.md", "content": "x"})
            v.t_write({"path": "ai/e.md", "content": "x"})
        finally:
            v.WRITABLE = []

    def test_size_caps(self):
        with self.assertRaises(RuntimeError):
            v.t_write({"path": "notes/big.md", "content": "x" * (v.MAX_BYTES + 1)})
        with self.assertRaises(RuntimeError):
            v.t_read_multiple({"paths": ["notes/a.md"] * (v.MAX_MULTI + 1)})


if __name__ == "__main__":
    unittest.main()
