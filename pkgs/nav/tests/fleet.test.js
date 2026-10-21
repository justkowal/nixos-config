const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
global.window = {};
eval(fs.readFileSync(path.join(__dirname, "../static/fleet.js"), "utf8"));
const F = window.Fleet;

test("every variant is made of known meshes and is laid out end to end around the centre", () => {
  for (const [key, v] of Object.entries(F.VARIANTS)) {
    for (const [mesh] of v.parts) assert.ok(F.LEN[mesh] > 0, `${key}: unknown mesh ${mesh}`);
    const { cars, total } = F.layout(v.parts);
    assert.ok(Math.abs(cars[0].c - cars[0].c) < 1e-9);
    let edge = -total / 2;
    for (const c of cars) { assert.ok(Math.abs(c.c - F.LEN[c.mesh] / 2 - edge) < 1e-9, `${key}: gap or overlap`); edge += F.LEN[c.mesh]; }
    assert.ok(Math.abs(edge - total / 2) < 1e-9);
    assert.ok(cars.map((c) => c.c).every((x, i, a) => !i || x > a[i - 1]), "ordered rear to front");
  }
  assert.ok(F.layout(F.VARIANTS.tram3.parts).total > 24 && F.layout(F.VARIANTS.tram3.parts).total < 30);
  assert.ok(F.layout(F.VARIANTS.tram5.parts).total > 32 && F.layout(F.VARIANTS.tram5.parts).total < 40);
  assert.ok(F.layout(F.VARIANTS.urbino18.parts).total > 17.5 && F.layout(F.VARIANTS.urbino18.parts).total < 19);
  assert.ok(F.layout(F.VARIANTS.emu4.parts).total > 75 && F.layout(F.VARIANTS.emu4.parts).total < 85);
});

test("every fleet weight table names real variants and covers its modes", () => {
  for (const f of F.FLEETS) for (const mode of ["BUS", "TRAM", "RAIL", "TROLLEYBUS"]) if (f[mode]) for (const k of Object.keys(f[mode])) assert.ok(F.VARIANTS[k], `${f.match}: ${k}`);
});

test("variant choice is deterministic per vehicle and follows the shares", () => {
  const a = F.variantFor("Miejskie Przedsiębiorstwo Komunikacyjne S.A. w Krakowie", "BUS", "veh-1");
  assert.equal(a.key, F.variantFor("Miejskie Przedsiębiorstwo Komunikacyjne S.A. w Krakowie", "BUS", "veh-1").key);
  const count = {};
  for (let i = 0; i < 4000; i++) { const k = F.variantFor("MPK w Krakowie", "BUS", "id" + i).key; count[k] = (count[k] || 0) + 1; }
  assert.ok(Math.abs(count.urbino12 / 4000 - 0.55) < 0.04, JSON.stringify(count));
  assert.ok(Math.abs(count.urbino18 / 4000 - 0.27) < 0.04);
  assert.ok(Math.abs(count.midi / 4000 - 0.18) < 0.04);
});

test("operators get their own families, unknown ones a sensible default", () => {
  assert.equal(F.variantFor("Koleje Śląskie sp. z o.o.", "RAIL", "x").key.startsWith("emu"), true);
  assert.equal(F.variantFor("„PKP Intercity” Spółka Akcyjna", "RAIL", "x").key, "ic");
  assert.equal(F.variantFor("Komunikacja Jurajska", "BUS", "x").key === "coach" || F.variantFor("Komunikacja Jurajska", "BUS", "x").key === "midi", true);
  assert.equal(F.variantFor("Someone Else", "TRAM", "x").key, "tram3");
  assert.equal(F.variantFor("Someone Else", "BUS", "x").key, "urbino12");
  assert.equal(F.variantFor("MPK w Częstochowie", "TRAM", "x").key, "tram105");
});

test("colour variation stays near the livery colour and differs between vehicles", () => {
  const base = "#f2c200", seen = new Set();
  for (let i = 0; i < 200; i++) {
    const c = F.jitter(base, "v" + i);
    seen.add(c.join(","));
    assert.ok(c[0] > 190 && c[1] > 140 && c[2] < 90, `${c} drifted from the yellow`);
  }
  assert.ok(seen.size > 100, "most vehicles are a slightly different shade");
  assert.deepEqual(F.jitter(base, "v1"), F.jitter(base, "v1"));
});

test("random colours cover the whole hue circle plus neutrals", () => {
  let neutral = 0; const hues = new Set();
  for (let i = 0; i < 3000; i++) {
    const [r, g, b] = F.randomColor("car" + i);
    assert.ok([r, g, b].every((v) => v >= 0 && v <= 255));
    if (Math.max(r, g, b) - Math.min(r, g, b) < 12) neutral++; else hues.add(Math.floor((Math.atan2(Math.sqrt(3) * (g - b), 2 * r - g - b) / Math.PI + 1) * 6));
  }
  assert.ok(neutral / 3000 > 0.25 && neutral / 3000 < 0.45, `neutrals ${neutral / 3000}`);
  assert.equal(hues.size >= 10, true, `hue buckets ${hues.size}`);
});
