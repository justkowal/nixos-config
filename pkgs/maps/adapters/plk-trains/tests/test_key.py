import unittest

from plk_trains.client import NoKey, parse_key

FAKE = "TESTKEY_" + "a1B2c3D4e5F6g7H8" * 3  # synthetic, never a real key


class KeyFile(unittest.TestCase):
    def test_bare_key(self):
        self.assertEqual(parse_key(FAKE + "\n"), FAKE)

    def test_portal_download_format(self):
        raw = f"API Key: {FAKE}\n\nGenerated: 9/10/2026, 11:49:30 AM\n\nIMPORTANT: Keep this key secure.\nUse it in the header: X-API-Key: {FAKE}\n"
        self.assertEqual(parse_key(raw), FAKE)

    def test_labelled_line_only(self):
        self.assertEqual(parse_key(f"X-API-Key: {FAKE}"), FAKE)

    def test_garbage_is_rejected_without_echo(self):
        secret_looking = "some words and a secret-ish value hunter2 hunter2 hunter2"
        with self.assertRaises(NoKey) as cm:
            parse_key(secret_looking)
        self.assertNotIn("hunter2", str(cm.exception))

    def test_empty(self):
        with self.assertRaises(NoKey):
            parse_key("  \n")


if __name__ == "__main__":
    unittest.main()
