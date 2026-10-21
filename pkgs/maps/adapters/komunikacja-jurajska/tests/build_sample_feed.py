"""Builds the static zip from the recorded fixtures (what the crawler would have produced).

Usage: build_sample_feed.py out.zip
"""
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_adapter as t  # noqa: E402

with tempfile.TemporaryDirectory() as d:
    _, _, store, _ = t.crawled(d)
    data, stats = t.gtfs.build(store, t.NOW, store.coverage())
    with open(sys.argv[1], "wb") as f:
        f.write(data)
    print(stats)
