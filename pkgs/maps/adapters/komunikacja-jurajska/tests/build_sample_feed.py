"""Builds the static zip from the recorded fixtures (what the crawler would have produced).

Usage: build_sample_feed.py out.zip
"""
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_adapter as t  # noqa: E402

with tempfile.TemporaryDirectory() as d:
    store = t.crawled(d)[3]
    s = store.s
    data, stats = t.gtfs.build(store, t.NOW, s["kp_stops"], s["kp_lines"], len(s["site_lines"]))
    with open(sys.argv[1], "wb") as f:
        f.write(data)
    print({k: v for k, v in stats.items() if k != "lines"})
