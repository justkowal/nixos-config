import csv, io, json, os, sys, tempfile, zipfile
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import derive_shapes as d


def line(*pts, **props):
    return {"type": "Feature", "properties": props, "geometry": {"type": "LineString", "coordinates": [list(p) for p in pts]}}


# a dogleg rail line A-J-B plus a yard spur that must be ignored
RAIL = [line((19.0, 50.0), (19.0, 50.05), (19.05, 50.05), railway="rail"), line((19.0, 50.0), (19.02, 50.0), railway="rail", service="yard")]


def make_zip(path, with_shape=False):
    def w(z, name, rows):
        o = io.StringIO(); c = csv.writer(o, lineterminator="\n"); [c.writerow(r) for r in rows]; z.writestr(name, o.getvalue())
    with zipfile.ZipFile(path, "w") as z:
        w(z, "routes.txt", [["route_id", "route_type"], ["r", 2]])
        w(z, "stops.txt", [["stop_id", "stop_lat", "stop_lon"], ["a", 50.0001, 19.0001], ["b", 50.0501, 19.0499], ["far", 50.3, 19.9]])
        w(z, "trips.txt", [["route_id", "trip_id", "shape_id"], ["r", "t1", "keep" if with_shape else ""], ["r", "t2", ""], ["r", "t3", ""]])
        w(z, "stop_times.txt", [["trip_id", "stop_sequence", "stop_id"], ["t1", 1, "a"], ["t1", 2, "b"], ["t2", 1, "a"], ["t2", 2, "b"], ["t3", 1, "a"], ["t3", 2, "far"]])
        if with_shape:
            w(z, "shapes.txt", [["shape_id", "shape_pt_lat", "shape_pt_lon", "shape_pt_sequence"], ["keep", 50, 19, 1], ["keep", 50.1, 19.1, 2]])


def run(with_shape):
    t = tempfile.mkdtemp(); zin, zout = f"{t}/in.zip", f"{t}/out.zip"
    make_zip(zin, with_shape)
    rep = d.derive(zin, zout, "x", f"{t}/r.json", lines_for=lambda p, m, b: RAIL)
    z = zipfile.ZipFile(zout)
    rows = lambda n: list(csv.DictReader(io.TextIOWrapper(z.open(n))))
    return rep, rows("trips.txt"), rows("shapes.txt")


def test_dogleg_followed_not_straight():
    rep, trips, shapes = run(False)
    t = {r["trip_id"]: r["shape_id"] for r in trips}
    assert t["t1"].startswith("derived-") and t["t1"] == t["t2"]
    pts = [(float(r["shape_pt_lon"]), float(r["shape_pt_lat"])) for r in shapes if r["shape_id"] == t["t1"]]
    assert (19.0, 50.05) in pts, "line must pass the corner"
    assert rep["routed_segments"] >= 1


def test_unsnappable_stop_falls_back_to_straight():
    rep, trips, shapes = run(False)
    assert rep["straight_segments"] == 1 and rep["partial"] == 1


def test_existing_shape_kept():
    rep, trips, shapes = run(True)
    t = {r["trip_id"]: r["shape_id"] for r in trips}
    assert t["t1"] == "keep" and any(r["shape_id"] == "keep" for r in shapes)
    assert t["t2"].startswith("derived-")


def test_yard_spur_ignored():
    adj = d.build_graph(RAIL, "rail")
    assert (19.02, 50.0) not in adj
