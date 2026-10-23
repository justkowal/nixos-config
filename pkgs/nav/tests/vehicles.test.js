// Controller tests for static/vehicles.js with a fake clock: node --test tests/
const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

let now = 1000;
global.performance = { now: () => now * 1000 };
const realDate = Date.now;
Date.now = () => 1.7e12 + now * 1000;

function decode(str) {
  let i = 0, lat = 0, lon = 0;
  const out = [];
  while (i < str.length) {
    let b, s = 0, r = 0;
    do { b = str.charCodeAt(i++) - 63; r |= (b & 31) << s; s += 5; } while (b >= 32);
    lat += r & 1 ? ~(r >> 1) : r >> 1;
    s = 0; r = 0;
    do { b = str.charCodeAt(i++) - 63; r |= (b & 31) << s; s += 5; } while (b >= 32);
    lon += r & 1 ? ~(r >> 1) : r >> 1;
    out.push([lon / 1e5, lat / 1e5]);
  }
  return out;
}
function encode(pts) {
  let out = "", plat = 0, plon = 0;
  for (const [lo, la] of pts) {
    for (const [cur, prev] of [[Math.round(la * 1e5), plat], [Math.round(lo * 1e5), plon]]) {
      const d = cur - prev;
      let v = d < 0 ? ~(d << 1) : d << 1;
      while (v >= 32) { out += String.fromCharCode((32 | (v & 31)) + 63); v >>= 5; }
      out += String.fromCharCode(v + 63);
    }
    plat = Math.round(la * 1e5); plon = Math.round(lo * 1e5);
  }
  return out;
}
global.document = {
  createElement: () => ({
    getContext: () => ({ clearRect() {}, fillText() {}, strokeText() {}, measureText: () => ({ width: 10 }) }),
    width: 256,
    height: 256
  }),
  body: { append() {} },
  querySelector: () => null
};
global.getComputedStyle = () => ({ getPropertyValue: () => "" });
global.matchMedia = () => ({ matches: false });
global.window = {
  App: {
    api: (...args) => (window.App._api ? window.App._api(...args) : Promise.resolve({})),
    h: (t, p, ...k) => ({ style: { setProperty() {} }, setAttribute() {}, addEventListener() {}, append() {} }),
    icon: () => ({}),
    $: (sel) => ({ style: { setProperty() {} }, setAttribute() {}, addEventListener() {}, append() {}, textContent: "" }),
    store: { get: (k, d) => d, set() {} },
    decode,
    providerOf: () => null
  }
};
global.requestAnimationFrame = () => {};
eval(fs.readFileSync(path.join(__dirname, "../static/scene3d.js"), "utf8"));
eval(fs.readFileSync(path.join(__dirname, "../static/fleet.js"), "utf8"));
eval(fs.readFileSync(path.join(__dirname, "../static/sched.js"), "utf8"));
eval(fs.readFileSync(path.join(__dirname, "../static/vehicles.js"), "utf8"));
const Veh = window.Vehicles;

const LAT = 50.0, KX = 111320 * Math.cos((LAT * Math.PI) / 180);
const lonAt = (m) => 19 + m / KX;
function shape(sig = []) {
  return { points: encode([[lonAt(0), LAT], [lonAt(4000), LAT]]), stops: [], sig };
}
function fresh(id, sig) {
  Veh._V.clear();
  const rep = { id, lat: LAT, lon: lonAt(0), hd: 90, sp: 10, ts: 1.7e9, line: "7", mode: "BUS", ag: "x", trip: "t:1", to: "X", st: null, sn: null };
  Veh._ingest([rep], 1.7e9);
  Veh._attach(Veh._V.get(id), shape(sig));
  return rep;
}
// the true vehicle drives at `speed`; the feed reports its position every `every` s with `lag` s of age
function run(id, rep, seconds, { speed = 10, every = 5, lag = 1, hold = () => false } = {}) {
  const v = Veh._V.get(id), trace = [];
  let truth = 0, nextReport = 0, serverClock = 1.7e9;
  for (let t = 0; t < seconds; t += 0.05) {
    now += 0.05; serverClock += 0.05;
    if (!hold(t)) truth += speed * 0.05;
    if (t >= nextReport) {
      nextReport += every;
      Veh._ingest([{ ...rep, lon: lonAt(truth - speed * lag), sp: hold(t) ? 0 : speed, ts: serverClock - lag }], serverClock);
    }
    Veh._step(v, 0.05, performance.now() / 1000);
    trace.push({ t, s: v.s, vel: v.vel, truth });
  }
  return { v, trace };
}

test("tracks a steadily moving vehicle without jumps or reversing", () => {
  const rep = fresh("a");
  const { trace } = run("a", rep, 120);
  for (let i = 1; i < trace.length; i++) assert.ok(trace[i].s >= trace[i - 1].s - 1e-9, "never moves backward");
  for (let i = 1; i < trace.length; i++) assert.ok(trace[i].s - trace[i - 1].s < 1.2, "no jump larger than 24 m/s");
  const end = trace[trace.length - 1];
  assert.ok(Math.abs(end.s - end.truth) < 30, `ended ${end.s - end.truth} m from the truth`);
});

test("stops for a simulated red light and then catches up", () => {
  const id = "b";
  // find a moment where the light at 1500 m is red for the next 25 s, so the approach (about 20 s away) meets it
  const rep = fresh(id, [1500]);
  const v = Veh._V.get(id);
  let found = false;
  for (let k = 0; k < 400 && !found; k++) { now += 1; found = Veh._red(v.shape, 0); }
  assert.ok(found, "a red phase exists");
  // reposition the vehicle 200 m before the light, as truth
  Object.assign(v, { s: 1300, sRep: 1300, vel: 10, tRep: performance.now() / 1000 });
  rep.lon = lonAt(1300);
  let stoppedFor = 0, minGap = 1e9, trace = [];
  let truth = 1300, serverClock = 1.7e9 + now, nextReport = 0;
  for (let t = 0; t < 90; t += 0.05) {
    now += 0.05; serverClock += 0.05; truth += 10 * 0.05;
    if (t >= nextReport) { nextReport += 5; Veh._ingest([{ ...rep, lon: lonAt(truth - 10), sp: 10, ts: serverClock - 1 }], serverClock); }
    Veh._step(v, 0.05, performance.now() / 1000);
    if (v.s < 1500 && v.vel < 0.2) stoppedFor += 0.05;
    if (v.s > 1496 && v.s < 1504 && !trace.length) trace.push(v.vel);
    trace.push(v.s);
  }
  assert.ok(stoppedFor >= 4, `stood at the light for ${stoppedFor.toFixed(1)} s`);
  assert.ok(Math.abs(v.s - truth) < 40, `caught up, ${(truth - v.s).toFixed(0)} m behind`);
});

function mismatch(jump) {
  const rep = fresh("c" + jump);
  const id = "c" + jump, v = Veh._V.get(id);
  Object.assign(v, { s: 100, sRep: 100, vel: 8, vRep: 8, tRep: performance.now() / 1000 });
  now += 1;
  Veh._ingest([{ ...rep, lon: lonAt(100 + jump), sp: 0, ts: 1.7e9 + 1e6 }], 1.7e9 + 1e6);  // the feed says it is `jump` m ahead and standing
  let maxStep = 0, last = v.s, minAlpha = 1;
  for (let i = 0; i < 1800; i++) { now += 0.05; const r = Veh._step(v, 0.05, performance.now() / 1000); maxStep = Math.max(maxStep, v.s - last); minAlpha = Math.min(minAlpha, r); last = v.s; }
  return { v, maxStep, minAlpha };
}
test("a few hundred metres of mismatch glide at a capped speed and converge", () => {
  const { v, maxStep, minAlpha } = mismatch(500);
  assert.ok(maxStep <= 5.2, `largest per-frame step ${maxStep.toFixed(1)} m`);
  assert.ok(minAlpha > 0.5, "stays visible");
  assert.ok(Math.abs(v.s - 600) < 20, "converged on the reported position");
});

test("a huge mismatch fades out, jumps and fades in", () => {
  const { v, maxStep, minAlpha } = mismatch(1500);
  assert.ok(minAlpha < 0.2, `went transparent for the jump (min alpha ${minAlpha.toFixed(2)})`);
  assert.ok(maxStep > 500, "the jump happened while invisible");
  assert.ok(Math.abs(v.s - 1600) < 20, "and it ends where the feed says");
  const after = Veh._step(v, 0.05, performance.now() / 1000);
  assert.ok(after > 0.9, "fully visible again");
});

test("halts when the feed says the vehicle stopped, without overshooting", () => {
  const rep = fresh("d");
  const { trace } = run("d", rep, 140, { hold: (t) => t > 60 });
  const stopAt = trace.find((p) => p.t >= 60).truth;
  const end = trace[trace.length - 1];
  assert.ok(end.vel < 0.3, "standing at the end");
  assert.ok(end.s - stopAt < 60, `overshoot ${(end.s - stopAt).toFixed(0)} m`);
  assert.ok(end.s - stopAt > -40, "and not far short of it");
});

test("stale vehicles stop and models differ by mode", () => {
  const rep = fresh("e");
  const v = Veh._V.get("e");
  now += 300;  // no reports for 300 s
  for (let i = 0; i < 600; i++) { now += 0.05; Veh._step(v, 0.05, performance.now() / 1000); }
  assert.ok(v.vel < 0.1, "stale vehicle came to rest");
  const mk = (mode, ag, id = "a") => Veh._model({ mode, ag, id, color: "#123456" });
  assert.equal(mk("BUS", "x").cars.length >= 1, true);
  assert.equal(mk("TRAM", "x").cars.length, 5, "default tram: three bodies and two bellows");
  assert.deepEqual(mk("RAIL", "PKP Intercity").cars.map((c) => c.mesh).slice(-1), ["loco"]);
  assert.ok([3, 4].includes(mk("RAIL", "Koleje Śląskie").cars.length));
  const offs = mk("TRAM", "x").cars.map((c) => c.c);
  assert.deepEqual(offs, [...offs].sort((a, b) => a - b), "cars are ordered rear to front");
  const meshes = new Set(); for (let i = 0; i < 300; i++) for (const m of [mk("BUS", "MPK w Krakowie", "b" + i), mk("TRAM", "MPK w Krakowie", "t" + i)]) m.cars.forEach((c) => meshes.add(c.mesh));
  assert.ok(meshes.has("bus18F") && meshes.has("busMid") && meshes.has("bus12") && meshes.has("tram105"), "a Krakow fleet shows several model families: " + [...meshes]);
});

test("simulating 700 vehicles for a frame costs well under a millisecond", () => {
  // 700 vehicles on 1000 point shapes, 2 of 3 with 40 signals, stepped at 60 fps
  const N = 700, pts = [];
  for (let i = 0; i < 1000; i++) pts.push([lonAt(i * 8), LAT + Math.sin(i / 40) * 0.0004]);
  const info = { points: encode(pts), stops: [], sig: Array.from({ length: 40 }, (_, i) => 150 + i * 190) };
  Veh._V.clear();
  const reps = [];
  for (let i = 0; i < N; i++) reps.push({ id: "p" + i, lat: LAT, lon: lonAt(i * 11 % 6000), hd: 90, sp: 6 + (i % 8), ts: 1.7e9, line: String(i % 40), mode: i % 5 === 0 ? "TRAM" : "BUS", ag: "x", trip: "t:" + i, to: "X", st: null, sn: null });
  Veh._ingest(reps, 1.7e9);
  for (const v of Veh._V.values()) Veh._attach(v, info);
  const vs = [...Veh._V.values()];
  for (let f = 0; f < 120; f++) { now += 1 / 60; for (const v of vs) Veh._step(v, 1 / 60, performance.now() / 1000); }  // warm up the JIT
  const t0 = process.hrtime.bigint(), FRAMES = 600;
  for (let f = 0; f < FRAMES; f++) { now += 1 / 60; const t = performance.now() / 1000; for (let i = 0; i < vs.length; i++) Veh._step(vs[i], 1 / 60, t); }
  const msPerFrame = Number(process.hrtime.bigint() - t0) / 1e6 / FRAMES;
  console.log(`# simulation: ${msPerFrame.toFixed(3)} ms per frame for ${N} vehicles`);
  assert.ok(msPerFrame < 1.5, `${msPerFrame.toFixed(2)} ms per frame`);
});

test("riding: the passenger's GPS pulls the vehicle under the dot, and a far-away fix is ignored", () => {
  const rep = fresh("r1");
  const v = Veh._V.get("r1");
  Object.assign(v, { s: 1000, sRep: 1000, vel: 10, vRep: 10, tRep: performance.now() / 1000 - 12 });
  global.window.App._api = () => Promise.resolve({ vehicles: [], now: 0 });
  v.mx = (lonAt(1000) + 180) / 360; v.my = 0.5 - Math.log(Math.tan(Math.PI / 4 + (LAT * Math.PI) / 360)) / (2 * Math.PI);
  assert.equal(Veh.rideSync("t:1", { lat: LAT, lon: lonAt(1000 + 5000), acc: 10, speed: 9 }), false, "5 km away is not this vehicle");
  assert.equal(Veh.rideSync("t:1", { lat: LAT, lon: lonAt(1200), acc: 80, speed: 9 }), false, "a poor fix is not trusted");
  assert.equal(Veh.rideSync("t:1", { lat: LAT, lon: lonAt(1200), acc: 10, speed: 9 }), true);
  assert.ok(Math.abs(v.sRep - 1200) < 3, `reported position moved to the GPS fix, ${v.sRep}`);
  let last = v.s;
  for (let i = 0; i < 400; i++) { now += 0.05; Veh._step(v, 0.05, performance.now() / 1000); assert.ok(v.s >= last - 1e-9); last = v.s; }
  assert.ok(v.s > 1200 && v.s < 1200 + 9 * 21, "the drawn vehicle caught up to the passenger without going backwards");
});

test("scheduled trips fade in smoothly before start and fade out at end", () => {
  const sh = shape([]);
  const st = [[0, 100, 130], [1000, 200, 220]];
  // sd = 1e9, so at epoch 1e9 + t, local trip time is t
  const v = {
    id: "S:test", sched: { sd: 1e9, st, hint: { i: 0 } },
    shape: Veh._build(sh), s: 0, vel: 0, hx: 0, hy: 1, seg: 0, seg0: 0,
  };
  global.Date.now = () => 1e12; // base epoch 1e9

  // 15s before first arrival (first = 100, t = 85): before fade threshold (< 10s)
  Date.now = () => (1e9 + 85) * 1000;
  assert.equal(Veh._step(v, 0.1, 1000), 0, "invisible well before trip");

  // 5s before first arrival (t = 95): half faded in
  Date.now = () => (1e9 + 95) * 1000;
  const aPre = Veh._step(v, 0.1, 1000);
  assert.ok(Math.abs(aPre - 0.5) < 0.05, `fading in before arrival: ${aPre}`);

  // During dwell at first stop (t = 110): fully opaque
  Date.now = () => (1e9 + 110) * 1000;
  assert.equal(Veh._step(v, 0.1, 1000), 1, "fully visible during trip");

  // 10s after last arrival (last = 200, t = 210): half faded out
  Date.now = () => (1e9 + 210) * 1000;
  const aPost = Veh._step(v, 0.1, 1000);
  assert.ok(Math.abs(aPost - 0.5) < 0.05, `fading out after last stop: ${aPost}`);

  // 25s after last arrival (t = 225): completely faded out
  Date.now = () => (1e9 + 225) * 1000;
  assert.equal(Veh._step(v, 0.1, 1000), 0, "transparent once trip is finished");
});

test("stale vehicles fade smoothly toward STALE_DROP without popping", () => {
  const rep = fresh("stale_test");
  const v = Veh._V.get("stale_test");
  const t0 = performance.now() / 1000;
  v.tRep = t0;
  v.vRep = 0;
  v.s = 0;
  v.sRep = 0;

  // At 200s (before STALE_DIM=240): full opacity
  let a200 = Veh._step(v, 0.05, t0 + 200);
  assert.equal(a200, 1.0, "full opacity before STALE_DIM");

  // At 240s: starts decay at 1.0 (no cliff)
  let a240 = Veh._step(v, 0.05, t0 + 240);
  assert.equal(a240, 1.0, "1.0 at STALE_DIM start of decay");

  // At 570s (midpoint of 240..900): 0.5
  let a570 = Veh._step(v, 0.05, t0 + 570);
  assert.ok(Math.abs(a570 - 0.5) < 0.02, `smooth midpoint fade: ${a570}`);

  // At 900s (STALE_DROP): 0.0
  let a900 = Veh._step(v, 0.05, t0 + 900);
  assert.ok(a900 <= 1e-6, "completely faded out at STALE_DROP");
});

test("showProvider queries agency vehicles, fits bounds, and clearHighlight resets", async () => {
  let fitArgs = null;
  const fakeMap = {
    getZoom: () => 10,
    getCenter: () => ({ lng: 19.1, lat: 50.1 }),
    fitBounds: (b, opts) => { fitArgs = { b, opts }; },
    flyTo: () => {},
    easeTo: () => {},
    triggerRepaint: () => {},
    getContainer: () => ({ clientWidth: 800, clientHeight: 600 }),
    getSource: () => null,
    addSource: () => {},
    getLayer: () => null,
    addLayer: () => {},
    getStyle: () => ({ layers: [] }),
    setLayoutProperty: () => {},
    touchPitch: { disable: () => {}, enable: () => {} },
    on: () => {},
    isStyleLoaded: () => true,
    setMaxPitch: () => {},
    dragRotate: { enable: () => {} },
    easeTo: () => {},
  };
  Veh.init(fakeMap);

  window.App._api = async (endpoint, params) => {
    if (endpoint === "vehicles" && params?.agency === "Jurajska") {
      return {
        now: 1.7e9,
        vehicles: [
          { id: "kj-1", trip: "t1", line: "101", lat: 50.6, lon: 19.3, ag: "Komunikacja Jurajska" },
          { id: "kj-2", trip: "t2", line: "102", lat: 50.8, lon: 19.5, ag: "Komunikacja Jurajska" }
        ]
      };
    }
    return { vehicles: [] };
  };

  try {
    const prov = { match: "Jurajska", name: "Komunikacja Jurajska", color: "#2e7d32" };
    const res = await Veh.showProvider(prov);
    assert.equal(res.count, 2);
    assert.ok(fitArgs, "fitBounds was called");
    assert.deepEqual(fitArgs.b, [[19.3, 50.6], [19.5, 50.8]]);
    assert.equal(Veh.getHighlightedProvider(), prov);

    Veh.clearHighlight();
    assert.equal(Veh.getHighlightedProvider(), null);
  } catch (err) {
    console.error("SHOW_PROVIDER_ERR:", err);
    throw err;
  }
  delete window.App._api;
});


