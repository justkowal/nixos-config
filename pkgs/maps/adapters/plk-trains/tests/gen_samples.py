"""Builds gtfs.zip, trip-updates.pb and alerts.pb from the fixtures, for the validators.

usage: python tests/gen_samples.py OUTDIR
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from test_adapter import SPEC, TODAY, CFG, build_static, fx, rt, tempfile  # noqa: E402,F401

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
blob, index, stats = build_static(tempfile.mkdtemp())
open(os.path.join(out, "gtfs.zip"), "wb").write(blob)
ts = 1_792_000_000
# 2026-10-21 08:26 UTC-ish snapshot; fixtures' operating dates are 2026-10-20..21
tu, _ = rt.build_trip_updates(fx("operations")["trains"], index, ts)
open(os.path.join(out, "trip-updates.pb"), "wb").write(tu)
al, _ = rt.build_alerts(fx("disruptions"), index, ts)
open(os.path.join(out, "alerts.pb"), "wb").write(al)
print(stats)
