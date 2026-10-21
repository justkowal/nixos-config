// Pure geometry and packing of static/scene3d.js (no GL): node --test tests/scene3d.test.js
const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
global.window = {};
global.document = { createElement: () => ({ getContext: () => ({}) }) };
eval(fs.readFileSync(path.join(__dirname, "../static/scene3d.js"), "utf8"));
const S = window.Scene3D;

const MESHES = {
  bus: S.carMesh({ L: 12, W: 2.5, H: 3.1, nose: "both", bus: true }),
  tramEnd: S.carMesh({ L: 8.6, W: 2.4, H: 3.5, nose: "front", wheels: 0 }),
  tramMid: S.carMesh({ L: 8.6, W: 2.4, H: 3.5, nose: "none", pantograph: true, wheels: 0 }),
  rail: S.carMesh({ L: 20, W: 2.9, H: 4.1, nose: "both", wheels: 0, bogies: 2 }),
  loco: S.carMesh({ L: 18, W: 3, H: 4.3, nose: "both", loco: true, wheels: 0, bogies: 2 }),
  bellows: S.bellowsMesh(1.2, 2.0, 3.5),
};

test("every mesh is well formed", () => {
  for (const [name, m] of Object.entries(MESHES)) {
    const n = m.vertex.length / 7;
    assert.ok(Number.isInteger(n) && n > 0, name);
    assert.equal(m.index.length % 3, 0, name);
    assert.ok(Math.max(...m.index) < n, `${name} index in range`);
    assert.ok(m.index.length / 3 === m.triangles && m.triangles < 700, `${name} triangles ${m.triangles}`);
    for (let i = 0; i < n; i++) {
      const [nx, ny, nz, part] = [m.vertex[i * 7 + 3], m.vertex[i * 7 + 4], m.vertex[i * 7 + 5], m.vertex[i * 7 + 6]];
      assert.ok(Math.abs(Math.hypot(nx, ny, nz) - 1) < 1e-5, `${name} unit normal`);
      assert.ok(Number.isInteger(part) && part >= 0 && part <= 7, `${name} part id`);
    }
  }
});

test("triangle winding agrees with the stored normals, so back face culling is safe", () => {
  for (const [name, m] of Object.entries(MESHES)) {
    let bad = 0;
    for (let t = 0; t < m.triangles; t++) {
      const [a, b, c] = [m.index[t * 3], m.index[t * 3 + 1], m.index[t * 3 + 2]].map((i) => Array.from(m.vertex.slice(i * 7, i * 7 + 3)));
      const u = [b[0] - a[0], b[1] - a[1], b[2] - a[2]], v = [c[0] - a[0], c[1] - a[1], c[2] - a[2]];
      const cr = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]];
      const n = Array.from(m.vertex.slice(m.index[t * 3] * 7 + 3, m.index[t * 3] * 7 + 6));
      const dot = cr[0] * n[0] + cr[1] * n[1] + cr[2] * n[2];
      if (dot <= 0) bad++;
    }
    assert.equal(bad, 0, `${name}: ${bad} triangles face the wrong way`);
  }
});

test("the five road vehicle types are well formed, wound correctly and sized like real vehicles", () => {
  assert.deepEqual(S.ROAD_TYPES, ["hatch", "sedan", "suv", "van", "truck"]);
  const dims = { hatch: [3.9, 4.3, 1.4, 1.7], sedan: [4.6, 5.0, 1.35, 1.6], suv: [4.6, 5.0, 1.65, 1.95], van: [5.2, 5.8, 2.1, 2.45], truck: [8.8, 9.4, 3.1, 3.9] };
  for (const type of S.ROAD_TYPES) {
    const m = S.roadVehicleMesh(type), n = m.vertex.length / 7;
    assert.ok(m.triangles > 60 && m.triangles < 600, `${type} ${m.triangles}`);
    assert.ok(Math.max(...m.index) < n);
    let bad = 0, painted = 0, lo = [1e9, 1e9, 1e9], hi = [-1e9, -1e9, -1e9];
    for (let i = 0; i < n; i++) { for (let k = 0; k < 3; k++) { lo[k] = Math.min(lo[k], m.vertex[i * 7 + k]); hi[k] = Math.max(hi[k], m.vertex[i * 7 + k]); } if (m.vertex[i * 7 + 6] === 1) painted++; }
    for (let t = 0; t < m.triangles; t++) {
      const ids = [m.index[t * 3], m.index[t * 3 + 1], m.index[t * 3 + 2]], [a, b, c] = ids.map((i) => Array.from(m.vertex.slice(i * 7, i * 7 + 3)));
      const u = b.map((v, k) => v - a[k]), w = c.map((v, k) => v - a[k]), cr = [u[1] * w[2] - u[2] * w[1], u[2] * w[0] - u[0] * w[2], u[0] * w[1] - u[1] * w[0]];
      const nn = Array.from(m.vertex.slice(ids[0] * 7 + 3, ids[0] * 7 + 6));
      if (cr[0] * nn[0] + cr[1] * nn[1] + cr[2] * nn[2] <= 0) bad++;
    }
    assert.equal(bad, 0, `${type}: ${bad} triangles face the wrong way`);
    assert.ok(painted > 20, `${type} has a painted (tintable) body`);
    const [l0, l1, h0, h1] = dims[type];
    assert.ok(hi[0] - lo[0] > l0 && hi[0] - lo[0] < l1, `${type} length ${(hi[0] - lo[0]).toFixed(2)}`);
    assert.ok(hi[2] > h0 && hi[2] < h1, `${type} height ${hi[2].toFixed(2)}`);
    assert.ok(lo[2] >= -0.01 && lo[2] < 0.1, `${type} sits on the ground`);
  }
});

test("meshes fit their stated size and sit on the ground", () => {
  const ext = (m, k) => { let lo = 1e9, hi = -1e9; for (let i = 0; i < m.vertex.length / 7; i++) { lo = Math.min(lo, m.vertex[i * 7 + k]); hi = Math.max(hi, m.vertex[i * 7 + k]); } return [lo, hi]; };
  const [x0, x1] = ext(MESHES.bus, 0), [y0, y1] = ext(MESHES.bus, 1), [z0, z1] = ext(MESHES.bus, 2);
  assert.ok(x1 - x0 > 11.9 && x1 - x0 < 12.3, "length");
  assert.ok(y1 - y0 > 2.5 && y1 - y0 < 3.0, "width incl. mirrors and wheels");
  assert.ok(z0 >= 0 && z0 < 0.1 && z1 > 3.3 && z1 < 3.8, "height");
});

test("instance batches pack a 24 byte stride with a tint and respect capacity", () => {
  const b = new S.InstanceBatch(2);
  assert.ok(b.push(1.5, -2.5, 0, 1, 7, 128, 3, 10, 20, 30, 200));
  assert.ok(b.push(3, 4, 1, 0, 9));
  assert.equal(b.push(0, 0, 0, 0, 0), false);
  assert.equal(b.count, 2);
  const v = b.view(), dv = new DataView(v.buffer, v.byteOffset, v.byteLength);
  assert.equal(v.length, 48);
  assert.equal(dv.getFloat32(0, true), 1.5); assert.equal(dv.getFloat32(4, true), -2.5); assert.equal(dv.getFloat32(12, true), 1);
  assert.deepEqual([v[16], v[17], v[18]], [7, 128, 3]);
  assert.deepEqual([v[20], v[21], v[22], v[23]], [10, 20, 30, 200]);
  assert.equal(v[40], 9); assert.equal(v[41], 255); assert.deepEqual([v[44], v[45], v[46], v[47]], [0, 0, 0, 0]);
  b.clear(); assert.equal(b.count, 0);
});

test("dot batches pack colour, size and label", () => {
  const d = new S.DotBatch(4);
  d.push(10, 20, 255, 128, 0, 200, 9, 5);
  const v = d.view(), dv = new DataView(v.buffer, v.byteOffset, v.byteLength);
  assert.equal(v.length, 24);
  assert.equal(dv.getFloat32(0, true), 10); assert.equal(dv.getFloat32(4, true), 20);
  assert.deepEqual([v[8], v[9], v[10], v[11]], [255, 128, 0, 200]);
  assert.equal(dv.getFloat32(12, true), 9); assert.equal(dv.getFloat32(16, true), 5);
});

test("palette gives stable ids, linearises colours and falls back when full", () => {
  const p = new S.Palette(2);
  const a = { skirt: "#000000", body: "#ffffff", stripe: "#ff0000", roof: "#808080" };
  assert.equal(p.id(a), 0); assert.equal(p.id(a), 0);
  assert.equal(p.id({ ...a, body: "#eeeeee" }), 1);
  assert.equal(p.id({ ...a, body: "#123456" }), 0, "full: falls back to the first");
  assert.equal(p.colors.length, 2 * 4 * 3);
  assert.ok(Math.abs(p.colors[3] - 1) < 1e-6, "white body is 1.0");
  assert.ok(Math.abs(p.colors[6] - Math.pow(1, 2.2)) < 1e-6);
});

test("local frame matrix maps metres around an origin into mercator units", () => {
  const M = S.localToMercator(0.55, 0.34, 1e-7);
  const apply = (m, v) => [0, 1, 2].map((r) => m[r] * v[0] + m[4 + r] * v[1] + m[8 + r] * v[2] + m[12 + r]);
  const out = apply(M, [100, 50, 10]);  // 100 m east, 50 m north, 10 m up
  assert.ok(Math.abs(out[0] - (0.55 + 1e-5)) < 1e-12);
  assert.ok(Math.abs(out[1] - (0.34 - 5e-6)) < 1e-12, "mercator y grows southwards");
  assert.ok(Math.abs(out[2] - 1e-6) < 1e-12);
  const I = S.mul(new Float64Array([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]), M);
  assert.deepEqual(Array.from(I), Array.from(M));
});
