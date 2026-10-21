const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
global.window = {};
eval(fs.readFileSync(path.join(__dirname, "../static/dem.js"), "utf8"));
const { Dem, decode, TS } = window.DemLib;

// a tile whose height rises 1 m per pixel eastwards and 2 m per pixel southwards, offset by the tile index so neighbours join up
const originFor = (z) => { const n = 2 ** z, s = Math.sin((50.06 * Math.PI) / 180); return [Math.floor(((19.9 + 180) / 360) * n) * 256, Math.floor((0.5 - Math.log((1 + s) / (1 - s)) / (4 * Math.PI)) * n) * 256]; };
function tileRgba(z, x, y, base = 1000) {
  const [X0, Y0] = originFor(z);
  const out = new Uint8ClampedArray(TS * TS * 4);
  for (let py = 0; py < TS; py++) for (let px = 0; px < TS; px++) {
    const gx = x * TS + px - X0, gy = y * TS + py - Y0, h = base + gx * 1 + gy * 2 + 32768, i = (py * TS + px) * 4;
    out[i] = Math.floor(h / 256); out[i + 1] = Math.floor(h) % 256; out[i + 2] = Math.floor((h - Math.floor(h)) * 256);
  }
  return out;
}
const wait = () => new Promise((r) => setTimeout(r, 5));

test("terrarium decoding", () => {
  const rgba = new Uint8ClampedArray(TS * TS * 4);
  const h = 123.5 + 32768; rgba[0] = Math.floor(h / 256); rgba[1] = Math.floor(h) % 256; rgba[2] = Math.round((h - Math.floor(h)) * 256);
  assert.ok(Math.abs(decode(rgba)[0] - 123.5) < 0.01);
  assert.equal(decode(new Uint8ClampedArray(TS * TS * 4))[5], -32768);
});

test("a missing tile gives 0 and is requested once; it arrives and fires onload", async () => {
  const asked = []; let loaded = 0;
  const d = new Dem({ zoom: 10, fetchTile: async (z, x, y) => { asked.push([z, x, y]); return tileRgba(z, x, y); }, onload: () => loaded++ });
  assert.equal(d.sample(19.9, 50.06), 0);
  d.sample(19.9, 50.06); d.sample(19.9001, 50.0601);
  assert.equal(asked.length, 1, "one request for one tile");
  await wait();
  assert.equal(loaded, 1);
  assert.ok(d.ready(19.9, 50.06) && d.sample(19.9, 50.06) > 900);
});

test("bilinear sampling follows the slope, including across a tile edge", async () => {
  const d = new Dem({ zoom: 10, fetchTile: async (z, x, y) => tileRgba(z, x, y) });
  for (let r = 0; r < 4; r++) { d.ensure(19.2, 49.7, 20.6, 50.5); await wait(); }  // at most 6 tiles load at a time
  const [fx, fy] = d.xy(19.9, 50.06);
  const at = (dx, dy) => { const n = d.n, lon = ((fx + dx) / n) * 360 - 180, my = 0.5 - (fy + dy) / n, lat = (Math.atan(Math.sinh(2 * Math.PI * my)) * 180) / Math.PI; return d.sample(lon, lat); };
  const a = at(0, 0), east = at(1 / TS, 0), south = at(0, 1 / TS);
  assert.ok(Math.abs(east - a - 1) < 0.05, `east step ${east - a}`);
  assert.ok(Math.abs(south - a - 2) < 0.05, `south step ${south - a}`);
  // walk across a tile boundary in small steps: the heights never jump
  let prev = null;
  for (let i = -6; i <= 6; i++) { const x = Math.round(fx) + i / TS, lon = (x / d.n) * 360 - 180, h = d.sample(lon, 50.06); if (prev !== null) assert.ok(Math.abs(h - prev - 1) < 0.1, `step ${h - prev} at ${i}`); prev = h; }
});

test("exaggeration scales elevation, failed tiles are retried later, bounds request every covering tile", async () => {
  let fail = true; const asked = new Set();
  const d = new Dem({ zoom: 12, fetchTile: async (z, x, y) => { asked.add(x + "," + y); if (fail) throw new Error("net"); return tileRgba(z, x, y, 300); } });
  d.sample(19.9, 50.06); await wait();
  assert.equal(d.sample(19.9, 50.06), 0);
  assert.equal(asked.size, 1, "a failed tile is not hammered");
  fail = false; d.failed.clear();
  d.ensure(19.88, 50.04, 19.95, 50.08); await wait(); await wait();
  assert.ok(asked.size >= 2, `${asked.size} tiles for the box`);
  const e1 = d.sample(19.9, 50.06); d.exaggeration = 2;
  assert.ok(Math.abs(d.sample(19.9, 50.06) - 2 * e1) < 1e-6);
});
