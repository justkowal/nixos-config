import base64
import os
import tempfile
import unittest

os.environ["UPEL_TOKEN_FILE"] = os.path.join(tempfile.mkdtemp(), "token")

import agh_mcp  # noqa: E402

PROGRAMME_HTML = """
<h1 id="syl-major-name"><span class="visually-hidden">Major </span>Computer Physics</h1>
<div role="doc-subtitle">2025/2026, First-cycle (engineer) programme</div>
<button id="nav-tab-info">Course description</button>
<button id="nav-tab-9">Semester 3</button>
<div id="nav-tab-info-panel"><table><tr><td>x</td></tr></table></div>
<div id="nav-tab-9-panel"><table>
<tr><th>Name</th><th>Hours</th></tr>
<tr><td><button data-syllabus-id="2c49874b-a480-4580-9970-6f0e25b144d8">
  Object Oriented Programming
</button><dl><dd>ECTS points: 6</dd></dl></td>
<td>Lectures: 30 <br> Laboratory classes: 30 <br></td><td>6</td>
<td>Completing the classes</td><td>Obligatory</td></tr>
</table></div>
"""


class Programme(unittest.TestCase):
    def parse(self):
        p = agh_mcp.ProgrammePage()
        p.feed(PROGRAMME_HTML)
        return p

    def test_title_and_tabs(self):
        p = self.parse()
        self.assertEqual(p.title, "Computer Physics")
        self.assertEqual(p.tabs["9"], "Semester 3")

    def test_subject_row(self):
        (row,) = self.parse().rows
        self.assertEqual(row["name"], "Object Oriented Programming")
        self.assertEqual(row["semester"], "9")
        self.assertEqual(row["hours"], "Lectures: 30 ; Laboratory classes: 30")
        self.assertEqual((row["ects"], row["verification"], row["mandatoriness"]), ("6", "Completing the classes", "Obligatory"))

    def test_default_programme_is_computer_physics_2025(self):
        self.assertEqual(agh_mcp.programme_path(), "/en/1/2/21/1/4/17/236")


class Document(unittest.TestCase):
    def test_text(self):
        p = agh_mcp.DocumentText()
        p.feed("<style>.x{}</style><h1>Course</h1><table><tr><td>Lectures:</td><td>30</td></tr></table><p>Goal  one</p>")
        self.assertEqual(p.text(), "Course\nLectures: | 30\nGoal one")


class Callback(unittest.TestCase):
    def test_token_is_field_one(self):
        raw = base64.urlsafe_b64encode(b"sig:::THETOKEN:::private").decode().rstrip("=")
        self.assertEqual(agh_mcp.write_token_from_callback(f"moodlemobile://token={raw}"), 0)
        self.assertEqual(agh_mcp.read_token_file(), "THETOKEN")
        self.assertEqual(oct(os.stat(agh_mcp.TOKEN_FILE).st_mode & 0o777), "0o600")

    def test_garbage_is_rejected(self):
        self.assertEqual(agh_mcp.write_token_from_callback("nothing here"), 1)


class Grades(unittest.TestCase):
    def test_plain_strips_moodle_icons(self):
        raw = '<i class="icon" title="Zaliczone"></i>100,00 % (bardzo dobry - 5,0)'
        self.assertEqual(agh_mcp.plain(raw), "100,00 % (bardzo dobry - 5,0)")
        self.assertIsNone(agh_mcp.plain(None))


class Protocol(unittest.TestCase):
    def test_unknown_tool(self):
        with self.assertRaises(KeyError):
            agh_mcp.call_tool("nope", {})

    def test_every_tool_is_read_only_listed(self):
        self.assertIn("syllabus_subject", agh_mcp.TOOLS)
        self.assertIn("assignments", agh_mcp.TOOLS)


if __name__ == "__main__":
    unittest.main()
