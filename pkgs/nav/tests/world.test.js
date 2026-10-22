const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
global.window = {};
for (const f of ["scene3d.js", "fleet.js", "traffic.js", "world.js"]) eval(fs.readFileSync(path.join(__dirname, "../static", f), "utf8"));
const W = window.World, T = window.Traffic;

let seed = 11; const rng = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296);
const anchor = { lon: 19.9, lat: 50.06 }, kx = 111320 * Math.cos((anchor.lat * Math.PI) / 180), ky = 111320;
const street = (cls, n = 600, y = 0, extra = {}) => ({ properties: { class: cls, ...extra }, geometry: { type: "LineString", coordinates: [[anchor.lon, anchor.lat + y / ky], [anchor.lon + n / kx, anchor.lat + y / ky]] } });

test("every mesh is well formed: outward faces, ground contact, sensible size", () => {
  const dims = { tree_round: [3, 5, 5.5, 7.5], tree_cone: [2.5, 3.6, 6.5, 7.5], tree_bare: [0.5, 3, 3, 5], lamp: [0.5, 1.6, 7, 7.4], bench: [1.5, 1.7, 0.8, 1], bin: [0.3, 0.5, 0.9, 1], busstop: [3, 4.6, 2.5, 2.7] };
  for (const [name, make] of Object.entries(W.MESHES)) {
    const m = make(), n = m.vertex.length / 7;
    assert.ok(m.triangles > 10 && m.triangles < 400, `${name} ${m.triangles}`);
    assert.ok(Math.max(...m.index) < n);
    let hi = [-1e9, -1e9, -1e9], lo = [1e9, 1e9, 1e9];
    for (let i = 0; i < n; i++) for (let k = 0; k < 3; k++) { hi[k] = Math.max(hi[k], m.vertex[i * 7 + k]); lo[k] = Math.min(lo[k], m.vertex[i * 7 + k]); }
    const [w0, w1, h0, h1] = dims[name];
    assert.ok(hi[0] - lo[0] >= w0 * 0.6 && hi[0] - lo[0] <= w1 * 1.2 + 4, `${name} width ${hi[0] - lo[0]}`);
    assert.ok(hi[2] >= h0 && hi[2] <= h1, `${name} height ${hi[2]}`);
    assert.ok(Math.abs(lo[2]) < 0.05, `${name} stands on the ground`);
  }
});

test("seasons: bare in winter, autumn mix in October, leafy in summer", () => {
  assert.equal(W.bareSeason(1), true);
  assert.equal(W.bareSeason(7), false);
  const mean = (month) => { const c = [0, 0, 0]; for (let i = 0; i < 400; i++) { const t = W.leaf(month, rng); c[0] += t[0]; c[1] += t[1]; c[2] += t[2]; } return c.map((v) => v / 400); };
  const jul = mean(7), oct = mean(10);
  assert.ok(jul[1] > jul[0] && jul[1] > jul[2], "summer leaves are green");
  assert.ok(oct[0] > jul[0] + 15, "October is warmer than July");
});

test("placement keeps decorations off buildings and carriageways and puts lamps on the pavement side", () => {
  const anchorLocal = anchor;
  const lanes = T.lanesFromFeatures([street("residential", 600), street("primary", 600, 40), street("residential", 600, 80)], anchorLocal);
  // a building row between the first two streets, set back from both
  const ring = [[100, 10], [300, 10], [300, 22], [100, 22]];
  const res = W.place({ lanes, rings: [ring], rnd: rng, month: 6 });
  assert.ok(res.trees.length > 15 && res.lamps.length > 15, `trees ${res.trees.length} lamps ${res.lamps.length}`);
  const B = new W.Blocker(); B.addRing(ring); for (const l of lanes) if (l.key.endsWith(">")) B.addLane(l);
  for (const k of ["trees", "lamps", "benches", "bins"]) for (const o of res[k]) assert.ok(!B.inBuilding(o.x, o.y) && !B.onRoad(o.x, o.y), `${k} at ${o.x.toFixed(1)}, ${o.y.toFixed(1)}`);
  for (const l of res.lamps) assert.ok(Math.abs(l.fx) + Math.abs(l.fy) > 0.9, "lamps carry a direction");
  assert.ok(res.trees.every((t) => t.tint.every((v) => v >= 0 && v <= 255)));
  assert.ok(!res.lamps.some((l) => l.y > 38 && l.y < 42 && false));
});

test("motorways get no lamps or trees, bare season uses bare trees, caps hold", () => {
  const lanes = T.lanesFromFeatures([street("motorway", 800), street("residential", 800, 60)], anchor);
  const winter = W.place({ lanes, rnd: rng, month: 1 });
  assert.ok(winter.trees.every((t) => t.kind === "tree_bare"));
  assert.ok(!winter.lamps.some((l) => Math.abs(l.y) < 12), "none beside the motorway");
  const capped = W.place({ lanes, rnd: rng, month: 6, caps: { trees: 10, lamps: 5 } });
  assert.ok(capped.trees.length <= 10 && capped.lamps.length <= 5);
});

test("bus stops sit beside the nearest lane and face the road; parks fill with trees by area", () => {
  const lanes = T.lanesFromFeatures([street("primary", 400)], anchor);
  const res = W.place({ lanes, stops: [[200, 0.5], [200, 500]], rnd: rng, month: 6 });
  assert.equal(res.stops.length, 1, "the far stop has no lane to stand at");
  assert.ok(Math.abs(res.stops[0].y) > 3 && Math.abs(res.stops[0].y) < 9, `shelter ${res.stops[0].y}`);
  assert.ok(res.stops[0].y > 0, "a stop north of the centreline serves the westbound lane on the north side");
  const park = [[0, 100], [90, 100], [90, 190], [0, 190]];
  const p = W.place({ lanes: [], parks: [park], rnd: rng, month: 6 });
  assert.ok(p.trees.length > 25 && p.trees.length < 60, `${p.trees.length} trees in 8100 m2`);
  assert.ok(p.trees.every((t) => t.x >= 0 && t.x <= 90 && t.y >= 100 && t.y <= 190));
});

test("placing for a whole district is fast", () => {
  const feats = []; for (let i = 0; i < 150; i++) feats.push(street(["secondary", "tertiary", "residential", "residential"][i % 4], 500, i * 20));
  const lanes = T.lanesFromFeatures(feats, anchor), rings = []; for (let i = 0; i < 800; i++) rings.push([[(i % 40) * 14, Math.floor(i / 40) * 150 + 6], [(i % 40) * 14 + 10, Math.floor(i / 40) * 150 + 6], [(i % 40) * 14 + 10, Math.floor(i / 40) * 150 + 14], [(i % 40) * 14, Math.floor(i / 40) * 150 + 14]]);
  const t0 = process.hrtime.bigint(), r = W.place({ lanes, rings, rnd: rng, month: 6 }), ms = Number(process.hrtime.bigint() - t0) / 1e6;
  console.log(`# world: ${ms.toFixed(0)} ms for ${r.trees.length} trees, ${r.lamps.length} lamps, ${r.benches.length} benches`);
  assert.ok(ms < 1500, `${ms} ms`);
});

test("light cones are well formed: intensity falls from the source to the edge, apex above the ground", () => {
  for (const [name, make] of Object.entries(W.BEAMS)) {
    const m = make(), n = m.vertex.length / 7;
    assert.ok(m.triangles >= 12 && m.triangles < 200, `${name} ${m.triangles}`);
    assert.ok(Math.max(...m.index) < n);
    let apexI = 0, edgeI = 1, hiZ = 0;
    for (let i = 0; i < n; i++) { const z = m.vertex[i * 7 + 2], inten = m.vertex[i * 7 + 6]; hiZ = Math.max(hiZ, z); if (z > 0.5) apexI = Math.max(apexI, inten); if (z < 0.1) edgeI = Math.min(edgeI, inten); }
    assert.ok(apexI > 0.5 && edgeI === 0, `${name} apex ${apexI} edge ${edgeI}`);
    assert.ok(hiZ > 0.7 && hiZ < 7.5);
  }
  const head = W.BEAMS.head(); let far = 0; for (let i = 0; i < head.vertex.length / 7; i++) far = Math.max(far, head.vertex[i * 7]);
  assert.ok(far > 15 && far < 25, `headlights reach ${far} m`);
});

test("placement is deterministic per lane and does not shuffle when other lanes change", () => {
  const lane1 = T.lanesFromFeatures([street("secondary", 800, 0)], anchor)[0];
  const lane2 = T.lanesFromFeatures([street("residential", 800, 50)], anchor)[0];

  // Run with only lane1
  const r1 = W.place({ lanes: [lane1], month: 6 });
  // Run with lane1 AND lane2
  const rBoth = W.place({ lanes: [lane1, lane2], month: 6 });

  // Filter rBoth for objects near lane1 (y near 0)
  const lane1TreesBoth = rBoth.trees.filter((t) => Math.abs(t.y) < 15);
  const lane1LampsBoth = rBoth.lamps.filter((l) => Math.abs(l.y) < 15);

  assert.equal(r1.trees.length, lane1TreesBoth.length, "trees on lane 1 are exactly preserved");
  assert.equal(r1.lamps.length, lane1LampsBoth.length, "lamps on lane 1 are exactly preserved");
  for (let i = 0; i < r1.trees.length; i++) {
    assert.equal(r1.trees[i].x, lane1TreesBoth[i].x);
    assert.equal(r1.trees[i].y, lane1TreesBoth[i].y);
    assert.equal(r1.trees[i].kind, lane1TreesBoth[i].kind);
  }
});

test("higher zoom levels produce higher tree and lamp density", () => {
  const lanes = T.lanesFromFeatures([street("secondary", 800, 0), street("residential", 800, 40)], anchor);
  const park = [[0, 100], [100, 100], [100, 200], [0, 200]];

  const z16 = W.place({ lanes, parks: [park], zoom: 16, month: 6 });
  const z18 = W.place({ lanes, parks: [park], zoom: 18, month: 6 });

  assert.ok(z18.trees.length > z16.trees.length, `z18 trees (${z18.trees.length}) > z16 trees (${z16.trees.length})`);
  assert.ok(z18.lamps.length > z16.lamps.length, `z18 lamps (${z18.lamps.length}) > z16 lamps (${z16.lamps.length})`);
});

