import datetime
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import hours as h  # noqa: E402

D = lambda day, hh, mm=0: datetime.datetime(2026, 10, 19 + day, hh, mm)  # 2026-10-19 is a Monday


class Hours(unittest.TestCase):
    def test_weekday_rule_and_off_days(self):
        raw = "Mo-Fr 08:00-18:00; Sa 09:00-14:00; Su off"
        self.assertEqual(h.state(raw, D(0, 10))["text"], "Open until 18:00")
        self.assertEqual(h.state(raw, D(0, 19))["text"], "Closed, opens tomorrow 08:00")
        self.assertEqual(h.state(raw, D(5, 15))["text"], "Closed, opens Mon 08:00")
        self.assertEqual(h.state(raw, D(6, 12))["open"], False)
        self.assertEqual(h.state(raw, D(0, 7, 30))["text"], "Closed, opens 08:00")

    def test_time_lists_and_24_7(self):
        raw = "Mo-Su 10:00-14:00,16:00-22:00"
        self.assertEqual(h.state(raw, D(2, 15))["text"], "Closed, opens 16:00")
        self.assertEqual(h.state(raw, D(2, 17))["text"], "Open until 22:00")
        self.assertEqual(h.state("24/7", D(3, 3))["open"], True)

    def test_overnight_span_belongs_to_both_days(self):
        raw = "Fr,Sa 20:00-03:00"
        self.assertTrue(h.state(raw, D(4, 23))["open"])
        self.assertEqual(h.state(raw, D(5, 1))["text"], "Open until 03:00")
        self.assertTrue(h.state(raw, D(6, 2))["open"])
        self.assertFalse(h.state(raw, D(6, 4))["open"])

    def test_later_rule_overrides_and_holidays_are_ignored(self):
        raw = "Mo-Su 09:00-17:00; We 09:00-12:00; PH off"
        self.assertEqual(h.state(raw, D(2, 13))["open"], False)
        self.assertEqual(h.state(raw, D(1, 13))["open"], True)

    def test_unsupported_text_is_none(self):
        for raw in ("Apr-Oct Mo-Fr 08:00-18:00", "sunrise-sunset", "by appointment", "", None, "Mo-Fr 8-18"):
            self.assertEqual(h.state(raw, D(0, 10)), {"open": None, "text": "", "week": []}, raw)

    def test_week_listing(self):
        w = h.state("Mo-Fr 08:00-18:00; Sa 09:00-14:00", D(0, 10))["week"]
        self.assertEqual(w[0], "Mon 08:00-18:00")
        self.assertEqual(w[6], "Sun closed")


if __name__ == "__main__":
    unittest.main()
