const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
global.window = {};
eval(fs.readFileSync(path.join(__dirname, "../static/fleet.js"), "utf8"));
eval(fs.readFileSync(path.join(__dirname, "../static/traffic.js"), "utf8"));
const T = window.Traffic;

let seed = 7; const rng = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296);
const feat = (cls, n = 2000, extra = {}) => ({ properties: { class: cls, ...extra }, geometry: { type: "LineString", coordinates: [[19.9, 50.06], [19.9 + n / 71500, 50.06]] } });
const anchor = { lon: 19.9, lat: 50.06 };

test("time of day: rush hours beat midday, midday beats night", () => {
  const f = T.timeFactor;
  assert.ok(f(8) > f(12.5) && f(12.5) > f(3), `${f(8)} ${f(12.5)} ${f(3)}`);
  assert.ok(f(16.5) > 0.9 && f(3) < 0.15 && f(27) === f(3));
  assert.ok(T.density("primary", 8) > T.density("minor", 8) * 3);
});

test("lanes: two directions unless one way, tunnels and aisles skipped, right-hand offset", () => {
  const l = T.lanesFromFeatures([feat("primary"), feat("residential", 500, { oneway: 1 }), feat("primary", 500, { brunnel: "tunnel" }), feat("service", 100, { service: "parking_aisle" }), feat("path")], anchor);
  assert.equal(l.length, 3);
  const east = l.find((x) => x.key.endsWith(">") && x.cls === "primary");
  assert.ok(east.Y[0] < 0, "eastbound traffic keeps to the south side");
  assert.ok(Math.abs(east.len - 2000) < 40);
});

test("vehicles queue behind each other and never overlap or reverse", () => {
  const t = new T.Traffic(rng); t.hour = 8;
  t.setLanes(T.lanesFromFeatures([feat("primary", 1500)], anchor), anchor);
  const lane = [...t.lanes.values()][0];
  lane.veh.length = 0;
  lane.veh.push({ s: 700, v: 0, type: "truck", len: 9, v0f: 1, tint: [0, 0, 0] });  // a stopped truck
  for (let i = 0; i < 8; i++) lane.veh.push({ s: 600 - i * 40, v: 13, type: "sedan", len: 4.75, v0f: 1, tint: [0, 0, 0] });
  for (let f = 0; f < 60 * 60; f++) {
    t.step(1 / 30); lane.veh[0].s = 700; lane.veh[0].v = 0;  // the obstacle stays put
    for (let i = 1; i < lane.veh.length; i++) { const a = lane.veh[i - 1], b = lane.veh[i]; assert.ok(a.s - a.len - b.s > 0.2 || a.s <= 0, `overlap at frame ${f}`); }
    lane.acc = 0;
  }
  const stopped = lane.veh.filter((v) => v.v < 0.3);
  assert.ok(stopped.length >= 8, "the queue formed behind the obstacle");
  assert.ok(lane.veh.every((v) => v.v >= 0));
});

test("steady inflow matches the class and the hour", () => {
  const count = (hour) => { const t = new T.Traffic(rng); t.hour = hour; t.setLanes(T.lanesFromFeatures([feat("secondary", 4000, { oneway: 1 })], anchor), anchor); for (let i = 0; i < 1800; i++) t.step(0.1); return [...t.lanes.values()][0].veh.length; };
  const rush = count(8), night = count(3);
  assert.ok(rush > night * 3, `rush ${rush} night ${night}`);
  assert.ok(rush > 30 && rush < 110, `rush ${rush} vehicles on 4 km`);
});

test("write emits only vehicles inside the bounds, with fades at lane ends", () => {
  const t = new T.Traffic(rng); t.hour = 9; t.setLanes(T.lanesFromFeatures([feat("primary", 1000, { oneway: 1 })], anchor), anchor);
  const lane = [...t.lanes.values()][0]; lane.veh.length = 0;
  lane.veh.push({ s: 500, v: 10, type: "hatch", len: 4, v0f: 1, tint: [1, 2, 3] }, { s: 3, v: 10, type: "suv", len: 4.7, v0f: 1, tint: [4, 5, 6] });
  lane.veh.reverse();
  const A = t.anchor, got = [];
  t.write(A.mx, A.my, A.k, A.mx - 1, A.mx + 1, A.my - 1, A.my + 1, (...a) => got.push(a));
  assert.equal(got.length, 2);
  const mid = got.find((g) => g[0] === "hatch"), edge = got.find((g) => g[0] === "suv");
  assert.ok(mid[5] === 1 && edge[5] < 0.5);
  assert.ok(Math.abs(mid[3] - 1) < 1e-6, "forward vector points east");
  got.length = 0;
  t.write(A.mx, A.my, A.k, A.mx + 1, A.mx + 2, A.my - 1, A.my + 1, (...a) => got.push(a));
  assert.equal(got.length, 0);
});

test("simulating a city's worth of lanes is cheap", () => {
  const feats = []; for (let i = 0; i < 400; i++) feats.push({ properties: { class: ["primary", "secondary", "tertiary", "residential"][i % 4] }, geometry: { type: "LineString", coordinates: [[19.9 + (i % 20) * 0.002, 50.06 + Math.floor(i / 20) * 0.002], [19.9 + (i % 20) * 0.002 + 0.006, 50.06 + Math.floor(i / 20) * 0.002 + 0.003]] } });
  const t = new T.Traffic(rng); t.hour = 8; t.setLanes(T.lanesFromFeatures(feats, anchor), anchor);
  for (let i = 0; i < 300; i++) t.step(1 / 30);
  const t0 = process.hrtime.bigint(); for (let i = 0; i < 300; i++) t.step(1 / 30);
  const ms = Number(process.hrtime.bigint() - t0) / 1e6 / 300;
  console.log(`# traffic: ${ms.toFixed(3)} ms per step, ${t.n} vehicles`);
  assert.ok(ms < 2.5, `${ms} ms`);  // 3400 vehicles is about ten times a real view
});

test("vehicles transfer smoothly between connected lanes instead of disappearing", () => {
  const f1 = { properties: { class: "primary", oneway: 1 }, geometry: { type: "LineString", coordinates: [[19.9, 50.06], [19.9 + 200 / 71500, 50.06]] } };
  const f2 = { properties: { class: "primary", oneway: 1 }, geometry: { type: "LineString", coordinates: [[19.9 + 200 / 71500, 50.06], [19.9 + 400 / 71500, 50.06]] } };
  const t = new T.Traffic(rng);
  t.setLanes(T.lanesFromFeatures([f1, f2], anchor), anchor);
  const lanes = [...t.lanes.values()];
  const l1 = lanes.find((l) => l.hasNext);
  const l2 = lanes.find((l) => l.hasPrev);
  assert.ok(l1 && l2, "lanes are connected");
  l1.veh.length = 0;
  l2.veh.length = 0;

  // Case 1: room on l2 -> vehicle transfers smoothly
  l1.veh.push({ s: l1.len - 5, v: 10, type: "sedan", len: 4.75, v0f: 1, tint: [0, 0, 0], spawn: 1 });
  t.step(1.0);
  assert.equal(l1.veh.length, 0, "vehicle transferred out of l1");
  assert.equal(l2.veh.length, 1, "vehicle transferred into l2");
  assert.ok(l2.veh[0].s >= 0 && l2.veh[0].s <= 25, `vehicle is at start of l2: ${l2.veh[0].s}`);

  // Case 2: l2 is congested -> vehicle waits at intersection without vanishing
  l1.veh.push({ s: l1.len - 5, v: 10, type: "sedan", len: 4.75, v0f: 1, tint: [0, 0, 0], spawn: 1 });
  l2.veh[0].s = 2.0; // car blocking start of l2
  l2.veh[0].v = 0;
  t.step(1.0);
  assert.equal(l1.veh.length, 1, "vehicle still exists on l1");
  assert.equal(l1.veh[0].s, l1.len, "vehicle holds at end of l1");
  assert.equal(l1.veh[0].v, 0, "vehicle comes to a stop");
});

