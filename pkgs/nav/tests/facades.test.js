"use strict";
// Tests for procedural building facades and window lighting: node --test tests/facades.test.js
const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

global.window = {};
eval(fs.readFileSync(path.join(__dirname, "../static/facades.js"), "utf8"));
const F = window.Facades;

const anchor = { lon: 19.937, lat: 50.061 };
const ky = 111320;
const kx = 111320 * Math.cos((50.061 * Math.PI) / 180);

// Helper to create a rectangular building feature of L x W metres
function createBuilding(L, W, deg = 0, h = 12, minH = 0) {
  const rad = (deg * Math.PI) / 180;
  const pts = [
    [-L / 2, -W / 2],
    [L / 2, -W / 2],
    [L / 2, W / 2],
    [-L / 2, W / 2],
  ].map(([u, v]) => [u * Math.cos(rad) - v * Math.sin(rad), u * Math.sin(rad) + v * Math.cos(rad)]);
  const coords = pts.map(([x, y]) => [anchor.lon + x / kx, anchor.lat + y / ky]);
  coords.push(coords[0]); // closed ring
  return {
    type: "Feature",
    geometry: { type: "Polygon", coordinates: [coords] },
    properties: { render_height: h, render_min_height: minH },
  };
}

test("footprint conversion to local metres respects counter-clockwise orientation", () => {
  const b = createBuilding(20, 10, 0);
  const ring = b.geometry.coordinates[0];
  const local = F.toLocal(ring, anchor);
  assert.equal(local.length, 4);
  const a2 = F.area2(local);
  assert.ok(a2 > 0, `area2 must be positive (CCW): got ${a2}`);
  assert.ok(Math.abs(a2 - 2 * 20 * 10) < 1.0, `area should be ~200 m2: got ${a2 / 2}`);

  // Even if input is clockwise, toLocal reverses it to counter-clockwise
  const cwRing = [...ring].reverse();
  const localCw = F.toLocal(cwRing, anchor);
  assert.ok(F.area2(localCw) > 0, "reversed ring must be normalized to CCW");
});

test("facade generation produces well-formed wall quads with outward unit normals", () => {
  const b = createBuilding(30, 15, 25, 14, 0);
  const mesh = F.buildFacades([b], anchor);
  assert.ok(mesh);
  assert.equal(mesh.walls, 4, "a rectangle has 4 walls");
  assert.equal(mesh.triangles, 8, "4 walls = 8 triangles");
  assert.equal(mesh.count, 16, "4 walls * 4 vertices = 16 vertices");

  const v = mesh.vertex;
  const stride = 12;

  // Verify vertex attributes
  for (let i = 0; i < mesh.count; i++) {
    const o = i * stride;
    const nx = v[o + 3], ny = v[o + 4], nz = v[o + 5];
    assert.equal(nz, 0, "wall normal is horizontal in z");
    const len = Math.hypot(nx, ny);
    assert.ok(Math.abs(len - 1.0) < 1e-5, `normal should be unit length: ${len}`);

    const u = v[o + 6], uCoord = v[o + 7];
    const wallL = v[o + 8], wallH = v[o + 9];
    assert.ok(u >= 0 && u <= wallL, "u must be within [0, wallL]");
    assert.ok(uCoord >= 0 && uCoord <= wallH, "v must be within [0, wallH]");
    assert.ok(Math.abs(wallH - 14) < 1e-4, `wall height should match building height: ${wallH}`);
  }

  // Verify outward normal orientation: dot product with vector from building center must be > 0
  for (let w = 0; w < mesh.walls; w++) {
    const o = w * 4 * stride;
    const x0 = v[o], y0 = v[o + 1];
    const nx = v[o + 3], ny = v[o + 4];
    // building center is at (0, 0) in local coords
    const dot = x0 * nx + y0 * ny;
    assert.ok(dot > 0, `wall ${w} normal points outward: dot=${dot}`);
  }
});

test("triangle winding agrees with outward normals for back-face culling", () => {
  const b = createBuilding(24, 12, 45, 16, 2);
  const mesh = F.buildFacades([b], anchor);
  const v = mesh.vertex;
  const stride = 12;

  let wrongWinding = 0;
  for (let t = 0; t < mesh.triangles; t++) {
    const i0 = mesh.index[t * 3] * stride;
    const i1 = mesh.index[t * 3 + 1] * stride;
    const i2 = mesh.index[t * 3 + 2] * stride;

    const p0 = [v[i0], v[i0 + 1], v[i0 + 2]];
    const p1 = [v[i1], v[i1 + 1], v[i1 + 2]];
    const p2 = [v[i2], v[i2 + 1], v[i2 + 2]];

    // Cross product (p1 - p0) x (p2 - p0)
    const d1 = [p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2]];
    const d2 = [p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2]];
    const cr = [
      d1[1] * d2[2] - d1[2] * d2[1],
      d1[2] * d2[0] - d1[0] * d2[2],
      d1[0] * d2[1] - d1[1] * d2[0],
    ];

    const n = [v[i0 + 3], v[i0 + 4], v[i0 + 5]];
    const dot = cr[0] * n[0] + cr[1] * n[1] + cr[2] * n[2];
    if (dot <= 0) wrongWinding++;
  }

  assert.equal(wrongWinding, 0, "all triangles must face outward in counter-clockwise order");
});

test("ground elevation offsets both base and top of facades", () => {
  const b = createBuilding(10, 10, 0, 15, 0);
  const groundZ = 245.5;
  const mesh = F.buildFacades([b], anchor, () => groundZ);
  const v = mesh.vertex;
  const stride = 12;

  let minZ = Infinity, maxZ = -Infinity;
  for (let i = 0; i < mesh.count; i++) {
    const z = v[i * stride + 2];
    minZ = Math.min(minZ, z);
    maxZ = Math.max(maxZ, z);
  }

  assert.ok(Math.abs(minZ - groundZ) < 1e-4, `base z must be groundZ: ${minZ} vs ${groundZ}`);
  assert.ok(Math.abs(maxZ - (groundZ + 15)) < 1e-4, `top z must be groundZ + 15: ${maxZ}`);
});

test("window lighting cycle: dark by day, lights up after sunset, almost fully dark after midnight", () => {
  const sunTimes = {
    sunrise: 360, // 06:00
    sunset: 1110, // 18:30
    dawn: 330,    // 05:30
    dusk: 1140,   // 19:00
  };

  // Sample 1000 independent windows across 100 buildings and 10 floors
  const sampleWindows = (minute) => {
    let litCount = 0;
    const total = 1000;
    for (let b = 0; b < 100; b++) {
      for (let f = 0; f < 5; f++) {
        for (let bay = 0; bay < 2; bay++) {
          if (F.windowLight(b * 13.7 + 1.1, bay, f, minute, sunTimes)) {
            litCount++;
          }
        }
      }
    }
    return litCount / total;
  };

  // 1. Broad daylight (12:00 / noon = 720 min): 0% windows lit
  const noonRatio = sampleWindows(720);
  assert.equal(noonRatio, 0.0, "windows must be completely dark at noon");

  // 2. Just before sunset (18:00 = 1080 min): 0% windows lit
  const preSunsetRatio = sampleWindows(1080);
  assert.equal(preSunsetRatio, 0.0, "windows must not light up before sunset");

  // 3. Right at sunset (18:30 = 1110 min): early windows start turning on
  const sunsetRatio = sampleWindows(1110);
  assert.ok(sunsetRatio > 0.05 && sunsetRatio < 0.25, `sunset ratio ${sunsetRatio} should be low initial start`);

  // 4. Dusk / early evening (19:30 = 1170 min, sunset + 60 min): windows rapidly lighting up
  const duskRatio = sampleWindows(1170);
  assert.ok(duskRatio > 0.40 && duskRatio < 0.70, `dusk ratio ${duskRatio} should show active lighting`);

  // 5. Peak evening hours (21:00 = 1260 min): peak window lights (~50% - 70% of all windows)
  const peakRatio = sampleWindows(1260);
  assert.ok(peakRatio > 0.45 && peakRatio < 0.75, `peak evening ratio ${peakRatio} should be maximum`);
  assert.ok(peakRatio > duskRatio, "lights should increase from dusk to peak evening");

  // 6. Heading towards midnight (23:30 = 1410 min): people going to bed, lights turning off
  const lateEveningRatio = sampleWindows(1410);
  assert.ok(lateEveningRatio < peakRatio * 0.65, `late evening ratio ${lateEveningRatio} should drop significantly`);

  // 7. Right around midnight (00:00 = 0 min): lights dropping sharply
  const midnightRatio = sampleWindows(0);
  assert.ok(midnightRatio < 0.25, `midnight ratio ${midnightRatio} should be dropping`);

  // 8. AFTER MIDNIGHT (01:00 = 60 min, 02:00 = 120 min, 03:00 = 180 min):
  // "go almost fully dark after midnight"
  const postMidnight1am = sampleWindows(60);
  const postMidnight2am = sampleWindows(120);
  const postMidnight3am = sampleWindows(180);

  assert.ok(postMidnight1am < 0.08, `1am ratio ${postMidnight1am} must be under 8%`);
  assert.ok(postMidnight2am < 0.05, `2am ratio ${postMidnight2am} must be under 5% (almost fully dark)`);
  assert.ok(postMidnight3am < 0.05, `3am ratio ${postMidnight3am} must be under 5% (almost fully dark)`);
  assert.ok(postMidnight2am > 0.0, "a few night owls remain on, not zero");

  // 9. After sunrise (06:30 = 390 min): back to 0% lit
  const postSunriseRatio = sampleWindows(390);
  assert.equal(postSunriseRatio, 0.0, "windows must turn off after sunrise");
});

test("window lighting is deterministic and continuous for a given window", () => {
  const sunTimes = { sunrise: 360, sunset: 1110 };
  const seed = 42.123;

  // The same window at the same minute must always return the exact same state
  for (let m = 0; m < 1440; m += 30) {
    const s1 = F.windowLight(seed, 2, 3, m, sunTimes);
    const s2 = F.windowLight(seed, 2, 3, m, sunTimes);
    assert.equal(s1, s2, `minute ${m} must be deterministic`);
  }

  // Windows turn on once in the evening and turn off at night without sporadic flickering
  let transitions = 0;
  let prevState = F.windowLight(seed, 1, 2, 0, sunTimes);
  for (let m = 1; m < 1440; m++) {
    const state = F.windowLight(seed, 1, 2, m, sunTimes);
    if (state !== prevState) {
      transitions++;
      prevState = state;
    }
  }
  // At most 2 transitions per day: turn on in evening, turn off at night
  assert.ok(transitions <= 2, `transitions per day must be at most 2: got ${transitions}`);
});

test("facade building is fast for a realistic district", () => {
  const buildings = [];
  for (let i = 0; i < 150; i++) {
    const L = 15 + (i % 5) * 4;
    const W = 10 + (i % 3) * 3;
    buildings.push(createBuilding(L, W, (i * 17) % 360, 9 + (i % 6) * 3));
  }

  const t0 = performance.now();
  const mesh = F.buildFacades(buildings, anchor);
  const dt = performance.now() - t0;

  assert.ok(mesh);
  assert.equal(mesh.walls, 600, "150 rectangular buildings = 600 walls");
  assert.equal(mesh.triangles, 1200);
  assert.ok(dt < 50, `building 600 walls should take < 50ms, took ${dt.toFixed(2)}ms`);
});

test("window lighting handles late summer sunsets (e.g. 21:15 / 1275 min) correctly without remaining dark", () => {
  const summerSunTimes = {
    sunrise: 270,  // 04:30
    sunset: 1275,  // 21:15
  };

  // Sample windows at 22:30 (1350 min) - should have significant lit percentage
  let litCount = 0;
  const total = 500;
  for (let b = 0; b < 50; b++) {
    for (let f = 0; f < 5; f++) {
      for (let bay = 0; bay < 2; bay++) {
        if (F.windowLight(b * 13.7 + 1.1, bay, f, 1350, summerSunTimes)) {
          litCount++;
        }
      }
    }
  }
  const ratio2230 = litCount / total;
  assert.ok(ratio2230 > 0.30, `summer sunset at 22:30 should have > 30% lit windows, got ${(ratio2230 * 100).toFixed(1)}%`);

  // Verify that any window that turns on in summer stays on for at least 30 minutes
  for (let b = 0; b < 30; b++) {
    let turnedOnMinute = -1, turnedOffMinute = -1;
    for (let m = 1260; m < 1440 + 270; m++) {
      const evalM = m % 1440;
      const isLit = F.windowLight(b * 19.3, 0, 1, evalM, summerSunTimes);
      if (isLit && turnedOnMinute === -1) turnedOnMinute = m;
      if (!isLit && turnedOnMinute !== -1 && turnedOffMinute === -1) turnedOffMinute = m;
    }
    if (turnedOnMinute !== -1 && turnedOffMinute !== -1) {
      assert.ok(turnedOffMinute - turnedOnMinute >= 30, `window must stay on >= 30 min, was ${turnedOffMinute - turnedOnMinute}`);
    }
  }
});
