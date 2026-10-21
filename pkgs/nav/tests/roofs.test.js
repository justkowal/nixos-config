const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
global.window = {};
eval(fs.readFileSync(path.join(__dirname, "../static/roofs.js"), "utf8"));
const R = window.Roofs;

const anchor = { lon: 19.9, lat: 50.05 }, ky = 111320, kx = 111320 * Math.cos((50.05 * Math.PI) / 180);
// a rectangle of L x W metres turned by `deg`, as [lon, lat], optionally clockwise
function rect(L, W, deg, cw = false) {
  const a = (deg * Math.PI) / 180, pts = [[-L / 2, -W / 2], [L / 2, -W / 2], [L / 2, W / 2], [-L / 2, W / 2]].map(([u, v]) => [u * Math.cos(a) - v * Math.sin(a), u * Math.sin(a) + v * Math.cos(a)]);
  if (cw) pts.reverse();
  const ll = pts.map(([x, y]) => [anchor.lon + x / kx, anchor.lat + y / ky]);
  return [...ll, ll[0]];
}
function stats(tris) {
  let up = 0, bad = 0, zmax = 0, n = 0;
  for (let i = 0; i < tris.v.length; i += 21) {
    const a = [tris.v[i], tris.v[i + 1], tris.v[i + 2]], b = [tris.v[i + 7], tris.v[i + 8], tris.v[i + 9]], c = [tris.v[i + 14], tris.v[i + 15], tris.v[i + 16]];
    const cz = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
    const nz = tris.v[i + 5];
    if (nz > 1e-6) up += cz / 2;
    if (nz < -1e-6) bad++;
    zmax = Math.max(zmax, a[2], b[2], c[2]); n++;
    const cx = (a[0] + b[0] + c[0]) / 3, cy = (a[1] + b[1] + c[1]) / 3;
    stats.cent = stats.cent || [];
  }
  return { up, bad, zmax, n };
}

test("oriented rectangle finds the long axis whatever the turn", () => {
  for (const deg of [0, 30, 100, -65]) {
    const o = R.obb(R.toLocal(rect(20, 8, deg), anchor));
    assert.ok(Math.abs(o.L - 20) < 0.2 && Math.abs(o.W - 8) < 0.2, `${deg}: ${o.L} x ${o.W}`);
    assert.ok(Math.hypot(o.cx, o.cy) < 0.2);
    const a = ((Math.atan2(o.ay, o.ax) * 180) / Math.PI - deg + 720) % 180;
    assert.ok(a < 1 || a > 179, `axis ${a}`);
  }
});

test("gabled, hipped and skillion roofs face up and out, cover the footprint exactly and reach the stated height", () => {
  for (const kind of ["gabled", "hipped", "skillion"]) for (const deg of [0, 37, 200]) for (const cw of [false, true]) {
    const t = new R.Tris();
    assert.ok(R.addRoof(t, kind, R.toLocal(rect(18, 9, deg, cw), anchor), 10, 4, null), kind);
    const s = stats(t);
    assert.equal(s.bad, 0, `${kind} has downward faces`);
    assert.ok(Math.abs(s.up - 162) < 1, `${kind} ${deg} covers ${s.up.toFixed(1)} of 162 m2`);
    assert.ok(Math.abs(s.zmax - 14) < 1e-6, `${kind} peak ${s.zmax}`);
  }
});

test("pyramidal roofs fit convex footprints and refuse concave ones, domes need room", () => {
  const sq = R.toLocal(rect(10, 10, 15), anchor), t = new R.Tris();
  assert.ok(R.addRoof(t, "pyramidal", sq, 5, 0, null));
  assert.ok(Math.abs(stats(t).up - 100) < 0.5 && stats(t).bad === 0);
  const L = [[0, 0], [10, 0], [10, 4], [4, 4], [4, 10], [0, 10]];
  assert.equal(R.addRoof(new R.Tris(), "pyramidal", L, 5, 3, null), false);
  assert.equal(R.addRoof(new R.Tris(), "gabled", L, 5, 3, null), false, "an L shaped footprint keeps its flat cap");
  const d = new R.Tris();
  assert.ok(R.addRoof(d, "dome", sq, 5, 4, null));
  const s = stats(d);
  assert.ok(s.bad === 0 && Math.abs(s.zmax - 9) < 0.01 && s.up > 60 && s.up < 100, `dome covers ${s.up}`);
  assert.equal(R.addRoof(new R.Tris(), "dome", R.toLocal(rect(2, 2, 0), anchor), 5, 1, null), false);
});

test("default heights scale with the building span and stay sane", () => {
  assert.ok(R.defaultRise("gabled", 8) > 2 && R.defaultRise("gabled", 8) < 4);
  assert.equal(R.defaultRise("gabled", 40), 7);
  assert.ok(R.defaultRise("pyramidal", 10) > 3);
});

test("build groups roofs by colour and skips unknown shapes", () => {
  const ways = [
    { shape: "gabled", pts: rect(14, 7, 10), mat: "roof_tiles" }, { shape: "gabled", pts: rect(14, 7, 80), col: "#336699" },
    { shape: "hipped", pts: rect(12, 8, 0) }, { shape: "flat", pts: rect(12, 8, 0) }, { shape: "gabled", pts: [[1, 1]] },
  ];
  const { meshes, used } = R.build(ways, anchor, () => 9);
  assert.equal(used, 3);
  assert.deepEqual([...meshes.keys()].sort(), ["#336699", "#a8573f", "#b4604a"]);
  for (const m of meshes.values()) { assert.equal(m.vertex.length / 7, m.index.length); assert.equal(m.triangles * 3, m.index.length); }
  assert.equal(R.colorOf({ col: "Red" }), "#a8483a");
  assert.equal(R.colorOf({ col: "nonsense", mat: "slate" }), "#565c64");
});
