"use strict";
// Street-level details for the diorama: trees, lamps, benches, bins and bus stops. Meshes are built once and drawn instanced; the placement works on the
// same lanes the traffic uses (local metres from an anchor) and keeps everything off buildings and off carriageways.
(() => {
  const S3 = window.Scene3D;
  const PART = S3.PART;

  // ---- geometry helpers: faces are given in any order, the normal is made to point away from `c`
  function face(m, pts, c, part) {
    const [a, b, d] = pts;
    let n = [(b[1] - a[1]) * (d[2] - a[2]) - (b[2] - a[2]) * (d[1] - a[1]), (b[2] - a[2]) * (d[0] - a[0]) - (b[0] - a[0]) * (d[2] - a[2]), (b[0] - a[0]) * (d[1] - a[1]) - (b[1] - a[1]) * (d[0] - a[0])];
    const l = Math.hypot(...n);
    if (l < 1e-9) return;
    n = n.map((v) => v / l);
    const mid = pts.reduce((s, p) => [s[0] + p[0], s[1] + p[1], s[2] + p[2]], [0, 0, 0]).map((v) => v / pts.length);
    const out = n[0] * (mid[0] - c[0]) + n[1] * (mid[1] - c[1]) + n[2] * (mid[2] - c[2]);
    const list = out < 0 ? pts.slice().reverse() : pts;
    if (out < 0) n = n.map((v) => -v);
    if (list.length === 3) m._quad(list[0], list[1], list[2], list[2], n, part); else m._quad(list[0], list[1], list[2], list[3], n, part);
  }
  function ellipsoid(m, cx, cy, cz, rx, ry, rz, part, seg = 7, rings = 4) {
    const c = [cx, cy, cz], pt = (a, b) => [cx + Math.cos(a) * Math.cos(b) * rx, cy + Math.sin(a) * Math.cos(b) * ry, cz + Math.sin(b) * rz];
    for (let k = 0; k < rings; k++) {
      const b0 = -Math.PI / 2 + (k / rings) * Math.PI, b1 = -Math.PI / 2 + ((k + 1) / rings) * Math.PI;
      for (let i = 0; i < seg; i++) { const a0 = (i / seg) * Math.PI * 2, a1 = ((i + 1) / seg) * Math.PI * 2; face(m, [pt(a0, b0), pt(a1, b0), pt(a1, b1), pt(a0, b1)], c, part); }
    }
  }
  function cone(m, cx, cy, z0, z1, r, part, seg = 8) {
    const c = [cx, cy, (z0 + z1) / 2 - 0.2], apex = [cx, cy, z1];
    for (let i = 0; i < seg; i++) {
      const a0 = (i / seg) * Math.PI * 2, a1 = ((i + 1) / seg) * Math.PI * 2, p = [cx + Math.cos(a0) * r, cy + Math.sin(a0) * r, z0], q = [cx + Math.cos(a1) * r, cy + Math.sin(a1) * r, z0];
      face(m, [p, q, apex], c, part);
      face(m, [p, q, [cx, cy, z0]], [cx, cy, z0 + 1], part);
    }
  }
  function post(m, cx, cy, r, z0, z1, part, sides = 6) {
    const prof = []; for (let i = 0; i < sides; i++) { const a = (i / sides) * Math.PI * 2; prof.push([cx + Math.cos(a) * r, 0]); }
    // a vertical prism around (cx, cy): build it from side quads
    const c = [cx, cy, (z0 + z1) / 2];
    for (let i = 0; i < sides; i++) {
      const a0 = (i / sides) * Math.PI * 2, a1 = ((i + 1) / sides) * Math.PI * 2;
      const p = [cx + Math.cos(a0) * r, cy + Math.sin(a0) * r], q = [cx + Math.cos(a1) * r, cy + Math.sin(a1) * r];
      face(m, [[p[0], p[1], z0], [q[0], q[1], z0], [q[0], q[1], z1], [p[0], p[1], z1]], c, part);
      face(m, [[p[0], p[1], z1], [q[0], q[1], z1], [cx, cy, z1]], [cx, cy, z0], part);
    }
  }

  // ---- meshes (local frame: x forward along the street, y toward the road, z up)
  function treeMesh(kind) {
    const m = new S3.MeshBuilder();
    if (kind === "cone") {
      post(m, 0, 0, 0.16, 0, 1.6, PART.SKIRT);
      cone(m, 0, 0, 1.0, 3.6, 1.7, PART.BODY); cone(m, 0, 0, 2.5, 5.3, 1.3, PART.BODY); cone(m, 0, 0, 4.2, 7.0, 0.85, PART.BODY);
    } else if (kind === "bare") {
      post(m, 0, 0, 0.2, 0, 3.2, PART.SKIRT);
      for (const [dx, dy] of [[1, 0.2], [-0.8, 0.9], [-0.2, -1.1], [0.5, 1]]) {
        const c = [dx * 0.4, dy * 0.4, 3.6];
        face(m, [[0.1, 0, 2.6], [dx, dy, 4.6], [-0.1, 0.1, 2.6]], [0, 0, 2.8], PART.SKIRT); void c;
      }
    } else {
      post(m, 0, 0, 0.2, 0, 2.6, PART.SKIRT);
      ellipsoid(m, 0, 0, 4.0, 2.1, 2.1, 1.9, PART.BODY, 8, 4);
      ellipsoid(m, 0.9, 0.5, 5.0, 1.3, 1.3, 1.2, PART.BODY, 6, 3);
    }
    return m.build();
  }
  function lampMesh() {
    const m = new S3.MeshBuilder();
    post(m, 0, 0, 0.07, 0, 7.2, PART.DARK, 6);
    m.box(-0.05, 0.05, 0, 1.6, 7.1, 7.25, PART.DARK);       // arm toward the road
    m.box(-0.28, 0.28, 1.1, 1.75, 6.88, 7.1, PART.HEAD);    // the lamp, lit at night
    m.box(-0.3, 0.3, 1.05, 1.8, 7.1, 7.18, PART.DARK);
    return m.build();
  }
  function benchMesh() {
    const m = new S3.MeshBuilder();
    m.box(-0.8, 0.8, -0.22, 0.22, 0.42, 0.48, PART.ROOF);   // seat
    m.box(-0.8, 0.8, -0.27, -0.22, 0.5, 0.88, PART.ROOF);   // back, away from the road
    m.box(-0.72, -0.64, -0.2, 0.2, 0, 0.42, PART.DARK); m.box(0.64, 0.72, -0.2, 0.2, 0, 0.42, PART.DARK);
    return m.build();
  }
  function binMesh() {
    const m = new S3.MeshBuilder();
    post(m, 0, 0, 0.21, 0, 0.88, PART.BODY, 8);
    m.box(-0.23, 0.23, -0.23, 0.23, 0.88, 0.95, PART.DARK);
    return m.build();
  }
  function stopMesh() {
    const m = new S3.MeshBuilder();
    m.box(-1.6, 1.6, -0.72, 0.72, 2.45, 2.6, PART.ROOF);                                   // roof
    for (const x of [-1.55, 1.55]) { m.box(x - 0.04, x + 0.04, -0.7, -0.62, 0, 2.45, PART.DARK); m.box(x - 0.04, x + 0.04, 0.62, 0.7, 0, 2.45, PART.DARK); }
    m.box(-1.5, 1.5, -0.72, -0.68, 0.35, 2.4, PART.GLASS);                                  // back panel
    m.box(-1.5, -1.46, -0.7, 0.7, 0.35, 2.4, PART.GLASS);                                   // one side panel
    m.box(-1.2, 1.0, -0.62, -0.18, 0.42, 0.48, PART.STRIPE); m.box(-1.2, 1.0, -0.64, -0.6, 0.48, 0.8, PART.STRIPE);  // bench inside
    post(m, 2.1, 0.55, 0.04, 0, 2.4, PART.DARK, 4);                                        // pole with the lit stop sign
    m.box(1.9, 2.3, 0.5, 0.6, 1.9, 2.4, PART.HEAD);
    return m.build();
  }
  const MESHES = { tree_round: () => treeMesh("round"), tree_cone: () => treeMesh("cone"), tree_bare: () => treeMesh("bare"), lamp: lampMesh, bench: benchMesh, bin: binMesh, busstop: stopMesh };

  // ---- light cones: vertices carry the intensity in the part slot (1 at the source, fading to 0 at the edge of the light)
  function beam(cones) {
    const v = [], idx = [];
    const vert = (p, i) => { v.push(p[0], p[1], p[2], 0, 0, 1, i); return v.length / 7 - 1; };
    for (const c of cones) {
      const a = vert(c.apex, c.apexI), mid = vert(c.centre, c.floorI), ring = [];
      for (let i = 0; i < c.seg; i++) { const t = (i / c.seg) * Math.PI * 2; ring.push(vert([c.centre[0] + Math.cos(t) * c.rx, c.centre[1] + Math.sin(t) * c.ry, c.centre[2]], 0)); }
      for (let i = 0; i < c.seg; i++) { const p = ring[i], q = ring[(i + 1) % c.seg]; idx.push(a, p, q, mid, p, q); }  // the cone's side and the pool on the ground
    }
    return { vertex: new Float32Array(v), index: Uint16Array.from(idx), triangles: idx.length / 3 };
  }
  const beamCone = (apex, centre, rx, ry, apexI, floorI, seg = 10) => ({ apex, centre, rx, ry, apexI, floorI, seg });
  const BEAMS = {
    lamp: () => beam([beamCone([0, 1.4, 6.85], [0, 1.4, 0.05], 4.6, 4.6, 0.55, 0.42, 14)]),
    head: () => beam([beamCone([0, 0.7, 0.8], [11, 0.9, 0.05], 8.5, 2.1, 0.8, 0.3), beamCone([0, -0.7, 0.8], [11, -0.9, 0.05], 8.5, 2.1, 0.8, 0.3)]),
    tail: () => beam([beamCone([0, 0.7, 0.8], [-2.8, 0.75, 0.05], 2.2, 1.0, 0.7, 0.3, 8), beamCone([0, -0.7, 0.8], [-2.8, -0.75, 0.05], 2.2, 1.0, 0.7, 0.3, 8)]),
  };

  // ---- season: leaf colour by month (northern Poland and Silesia)
  function leaf(month, rnd) {  // returns [r, g, b]
    const hsl = (h, s, l) => { const q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q, f = (t) => { t = (t + 1) % 1; return t < 1 / 6 ? p + (q - p) * 6 * t : t < 1 / 2 ? q : t < 2 / 3 ? p + (q - p) * (2 / 3 - t) * 6 : p; }; return [f(h + 1 / 3), f(h), f(h - 1 / 3)].map((v) => Math.round(v * 255)); };
    if (month === 12 || month <= 2) return hsl(0.08, 0.12, 0.22 + rnd() * 0.1);
    if (month === 3) return hsl(0.2 + rnd() * 0.03, 0.4, 0.4 + rnd() * 0.1);
    if (month === 4) return hsl(0.24 + rnd() * 0.04, 0.55, 0.4 + rnd() * 0.1);
    if (month <= 8) return hsl(0.25 + rnd() * 0.09, 0.45 + rnd() * 0.15, 0.24 + rnd() * 0.14);
    if (month === 9) return hsl(0.17 + rnd() * 0.12, 0.5, 0.3 + rnd() * 0.12);
    const r = rnd();  // October and November
    return r < 0.3 ? hsl(0.25 + rnd() * 0.05, 0.4, 0.3) : r < 0.65 ? hsl(0.11 + rnd() * 0.04, 0.75, 0.46) : hsl(0.02 + rnd() * 0.04, 0.7, 0.38 + rnd() * 0.1);
  }
  const bareSeason = (month) => month === 12 || month <= 2;

  // ---- spatial helpers
  const HALF = { motorway: 5.5, trunk: 4.6, primary: 3.8, secondary: 3.5, tertiary: 3.2, minor: 2.8, residential: 2.8, service: 1.8 };
  const half = (cls) => HALF[cls] || 2.8;

  // buildings and carriageways as grids of 3 m cells
  class Blocker {
    constructor() { this.cell = 3; this.rcell = 1; this.road = new Set(); this.rings = new Map(); }
    key(x, y) { return Math.floor(x / this.cell) * 100003 + Math.floor(y / this.cell); }
    rkey(x, y) { return Math.floor(x / this.rcell) * 100003 + Math.floor(y / this.rcell); }  // the carriageway needs a finer grid, or it spills onto the pavement
    addRing(ring) {
      let x0 = 1e9, x1 = -1e9, y0 = 1e9, y1 = -1e9;
      for (const p of ring) { x0 = Math.min(x0, p[0]); x1 = Math.max(x1, p[0]); y0 = Math.min(y0, p[1]); y1 = Math.max(y1, p[1]); }
      const r = { ring, x0, x1, y0, y1 };
      for (let cx = Math.floor(x0 / this.cell); cx <= Math.floor(x1 / this.cell); cx++) for (let cy = Math.floor(y0 / this.cell); cy <= Math.floor(y1 / this.cell); cy++) {
        const k = cx * 100003 + cy; let l = this.rings.get(k); if (!l) this.rings.set(k, (l = [])); l.push(r);
      }
    }
    addLane(l) {  // a lane stands for half of its street, so mark the whole width around the centreline once per direction pair
      const w = half(l.cls) + 0.3, n = l.X.length;
      for (let i = 0; i < n - 1; i++) {
        const len = Math.hypot(l.X[i + 1] - l.X[i], l.Y[i + 1] - l.Y[i]) || 1, ux = (l.X[i + 1] - l.X[i]) / len, uy = (l.Y[i + 1] - l.Y[i]) / len;
        for (let s = 0; s <= len; s += 0.7) for (let d = -w; d <= w; d += 0.7) this.road.add(this.rkey(l.X[i] + ux * s - uy * (l.off + d), l.Y[i] + uy * s + ux * (l.off + d)));
      }
    }
    onRoad(x, y) { return this.road.has(this.rkey(x, y)); }
    inBuilding(x, y) {
      const l = this.rings.get(this.key(x, y));
      if (!l) return false;
      for (const r of l) {
        if (x < r.x0 || x > r.x1 || y < r.y0 || y > r.y1) continue;
        let inside = false;
        for (let i = 0, j = r.ring.length - 1; i < r.ring.length; j = i++) {
          const a = r.ring[i], b = r.ring[j];
          if ((a[1] > y) !== (b[1] > y) && x < ((b[0] - a[0]) * (y - a[1])) / (b[1] - a[1]) + a[0]) inside = !inside;
        }
        if (inside) return true;
      }
      return false;
    }
    free(x, y, margin = 0) { return !this.onRoad(x, y) && !this.inBuilding(x, y) && (!margin || (!this.inBuilding(x + margin, y) && !this.inBuilding(x - margin, y) && !this.inBuilding(x, y + margin) && !this.inBuilding(x, y - margin))); }
  }

  const area = (r) => { let a = 0; for (let i = 0; i < r.length; i++) { const p = r[i], q = r[(i + 1) % r.length]; a += p[0] * q[1] - q[0] * p[1]; } return a / 2; };

  function hashStr(str) {
    let h = 2166136261 >>> 0;
    for (let i = 0; i < str.length; i++) h = Math.imul(h ^ str.charCodeAt(i), 16777619) >>> 0;
    return h;
  }
  function makeRng(seed) {
    let s = (seed | 0) || 1;
    return () => {
      s = (Math.imul(s ^ (s >>> 15), 0x2c1b3c6d) + 0x9e3779b9) | 0;
      return ((s ^ (s >>> 13)) >>> 0) / 4294967296;
    };
  }

  // lanes: from Traffic.lanesFromFeatures (offset to the right of travel, local metres). rings: building outlines, parks: park polygons, stops: [x, y] bus stop points.
  // rnd: () => 0..1 (optional), month: 1..12, zoom: map zoom level. Returns lists of { x, y, fx, fy, tint:[r,g,b], kind }.
  function place({ lanes, rings = [], parks = [], stops = [], rnd = null, month = 6, caps = {}, zoom = 16 }) {
    const z = typeof zoom === "number" ? zoom : 16;
    const densityMult = z >= 18 ? 1.7 : z >= 17 ? 1.35 : 1.0;
    const cap = {
      trees: Math.round(5000 * densityMult),
      lamps: Math.round(2500 * densityMult),
      benches: Math.round(700 * densityMult),
      bins: Math.round(600 * densityMult),
      stops: 300,
      ...caps,
    };
    const B = new Blocker();
    for (const r of rings) B.addRing(r);
    for (const l of lanes) if (l.key.endsWith(">")) B.addLane(l);  // one direction stands for the street; the other differs only by the offset
    const out = { trees: [], lamps: [], benches: [], bins: [], stops: [] };
    const bare = bareSeason(month);
    const tangentAt = (l, i) => { const a = Math.max(0, i - 1), b = Math.min(l.X.length - 1, i + 1), dx = l.X[b] - l.X[a], dy = l.Y[b] - l.Y[a], d = Math.hypot(dx, dy) || 1; return [dx / d, dy / d]; };

    const walk = (l, spacing, jitter, lrnd, f) => {
      let s = 8 + lrnd() * spacing, i = 0;
      while (s < l.len - 8) {
        while (i < l.X.length - 2 && l.cum[i + 1] < s) i++;
        const seg = l.cum[i + 1] - l.cum[i] || 1, t = (s - l.cum[i]) / seg, x = l.X[i] + (l.X[i + 1] - l.X[i]) * t, y = l.Y[i] + (l.Y[i + 1] - l.Y[i]) * t, [tx, ty] = tangentAt(l, i);
        f(x, y, tx, ty, s);
        s += spacing * (1 - jitter + lrnd() * 2 * jitter);
      }
    };

    for (const l of lanes) {
      // Deterministic PRNG seeded per-lane so camera pans and lane ordering do not shuffle objects
      const lSeed = l.key ? hashStr(l.key) : 12345;
      const lrnd = rnd ? rnd : makeRng(lSeed);
      const treeAt = (x, y, kind) => { const t = leaf(month, lrnd); out.trees.push({ x, y, fx: 1, fy: 0, tint: t, kind: bare ? "tree_bare" : kind === "cone" ? "tree_cone" : "tree_round" }); };

      const hw = half(l.cls), nx = (tx, ty) => [ty, -tx];  // right of travel
      const at = (x, y, tx, ty, extra) => { const [rx, ry] = nx(tx, ty), lat = hw + extra - l.off; return [x + rx * lat, y + ry * lat]; };
      const mean = l.cls === "motorway" || l.cls === "trunk";

      const lampSpacing = (l.cls === "service" ? 60 : 34) / densityMult;
      if (!mean && out.lamps.length < cap.lamps) {
        walk(l, lampSpacing, 0.1, lrnd, (x, y, tx, ty) => {
          for (const extra of [0.9, 0.4]) {  // narrow streets: closer to the kerb
            const [px, py] = at(x, y, tx, ty, extra);
            if (B.free(px, py, 0.3) && out.lamps.length < cap.lamps) { out.lamps.push({ x: px, y: py, fx: tx, fy: ty, tint: [0, 0, 0], kind: "lamp" }); break; }
          }
        });
      }

      const treeSpacing = (l.cls === "secondary" ? 22 : 15) / densityMult;
      if (["secondary", "tertiary", "minor", "residential"].includes(l.cls) && out.trees.length < cap.trees) {
        walk(l, treeSpacing, 0.35, lrnd, (x, y, tx, ty) => {
          if (lrnd() < (0.3 / densityMult)) return;
          const [px, py] = at(x, y, tx, ty, 2.7);
          if (B.free(px, py, 1.4) && out.trees.length < cap.trees) treeAt(px, py, lrnd() < 0.22 ? "cone" : "round");
        });
      }

      if (["primary", "secondary", "tertiary", "minor", "residential"].includes(l.cls) && out.benches.length < cap.benches) {
        walk(l, 75 / densityMult, 0.4, lrnd, (x, y, tx, ty) => {
          const [px, py] = at(x, y, tx, ty, 1.5);
          if (!B.free(px, py, 0.8)) return;
          if (lrnd() < 0.55 && out.benches.length < cap.benches) out.benches.push({ x: px, y: py, fx: tx, fy: ty, tint: [0, 0, 0], kind: "bench" });
          else if (out.bins.length < cap.bins) { const t = lrnd() < 0.5 ? [52, 92, 64] : [62, 66, 72]; out.bins.push({ x: px + tx * 1.2, y: py + ty * 1.2, fx: tx, fy: ty, tint: t, kind: "bin" }); }
        });
      }
    }

    // bus stops: the shelter stands on the right of the nearest lane, its open side toward the road
    for (const [sx, sy] of stops) {
      if (out.stops.length >= cap.stops) break;
      let best = null;
      for (const l of lanes) {
        for (let i = 0; i < l.X.length - 1; i++) {
          const dx = l.X[i + 1] - l.X[i], dy = l.Y[i + 1] - l.Y[i], len2 = dx * dx + dy * dy || 1, t = Math.max(0, Math.min(1, ((sx - l.X[i]) * dx + (sy - l.Y[i]) * dy) / len2)), d = Math.hypot(sx - l.X[i] - dx * t, sy - l.Y[i] - dy * t);
          if (d < 14 && (!best || d < best.d)) best = { d, l, i, t, dx, dy };
        }
      }
      if (!best) continue;
      const { l, i, t, dx, dy } = best, len = Math.hypot(dx, dy) || 1, tx = dx / len, ty = dy / len, x = l.X[i] + dx * t, y = l.Y[i] + dy * t, lat = half(l.cls) + 2.2 - l.off;
      const px = x + ty * lat, py = y - tx * lat;
      if (B.inBuilding(px, py) || B.onRoad(px, py)) continue;
      out.stops.push({ x: px, y: py, fx: tx, fy: ty, tint: [0, 0, 0], kind: "busstop" });
    }

    // parks and woods: trees at a density by area, deterministic per park
    for (const ring of parks) {
      const a = Math.abs(area(ring));
      if (a < 300) continue;
      let x0 = 1e9, x1 = -1e9, y0 = 1e9, y1 = -1e9; for (const p of ring) { x0 = Math.min(x0, p[0]); x1 = Math.max(x1, p[0]); y0 = Math.min(y0, p[1]); y1 = Math.max(y1, p[1]); }
      const pSeed = hashStr(ring.length + "_" + (x1 - x0).toFixed(1) + "_" + (y1 - y0).toFixed(1));
      const prnd = rnd ? rnd : makeRng(pSeed);
      const treeAt = (x, y, kind) => { const t = leaf(month, prnd); out.trees.push({ x, y, fx: 1, fy: 0, tint: t, kind: bare ? "tree_bare" : kind === "cone" ? "tree_cone" : "tree_round" }); };
      const want = Math.min(Math.round(900 * densityMult), Math.round(a / (170 / densityMult)));
      for (let n = 0, tries = 0; n < want && tries < want * 6 && out.trees.length < cap.trees; tries++) {
        const x = x0 + prnd() * (x1 - x0), y = y0 + prnd() * (y1 - y0);
        let inside = false;
        for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) { const p = ring[i], q = ring[j]; if ((p[1] > y) !== (q[1] > y) && x < ((q[0] - p[0]) * (y - p[1])) / (q[1] - p[1]) + p[0]) inside = !inside; }
        if (inside && B.free(x, y, 0.5)) { treeAt(x, y, prnd() < 0.3 ? "cone" : "round"); n++; }
      }
    }
    return out;
  }



  window.World = { BEAMS, MESHES, place, leaf, Blocker, bareSeason, HALF };
})();
