"use strict";
// Roof shapes from OpenStreetMap (roof:shape) as meshes. Footprints come in as [lon, lat] rings and leave as triangles in metres east/north of an
// anchor, z up from the ground. Gabled, hipped and skillion roofs follow the footprint's oriented rectangle, so they only apply to roughly rectangular
// buildings; pyramidal and domed roofs work on any convex footprint. Anything else keeps the flat cap.
(() => {
  const KIND = { gabled: "gabled", gambrel: "gabled", saltbox: "gabled", hipped: "hipped", "half-hipped": "hipped", mansard: "hipped", pyramidal: "pyramidal", skillion: "skillion", "lean_to": "skillion", dome: "dome", onion: "dome", round: "dome" };
  const kindOf = (shape) => KIND[shape] || null;

  const area2 = (r) => { let a = 0; for (let i = 0; i < r.length; i++) { const p = r[i], q = r[(i + 1) % r.length]; a += p[0] * q[1] - q[0] * p[1]; } return a; };
  function toLocal(ring, anchor) {
    const ky = 111320, kx = 111320 * Math.cos((anchor.lat * Math.PI) / 180);
    let pts = ring.map(([lo, la]) => [(lo - anchor.lon) * kx, (la - anchor.lat) * ky]);
    if (pts.length > 1 && pts[0][0] === pts[pts.length - 1][0] && pts[0][1] === pts[pts.length - 1][1]) pts.pop();
    if (area2(pts) < 0) pts.reverse();  // counter clockwise
    return pts;
  }
  const isConvex = (r) => { let s = 0; for (let i = 0; i < r.length; i++) { const a = r[i], b = r[(i + 1) % r.length], c = r[(i + 2) % r.length], z = (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0]); if (Math.abs(z) < 1e-9) continue; const sg = Math.sign(z); if (s && sg !== s) return false; s = sg; } return true; };
  // smallest oriented rectangle over the polygon's edge directions
  function obb(r) {
    let best = null;
    for (let i = 0; i < r.length; i++) {
      const p = r[i], q = r[(i + 1) % r.length], l = Math.hypot(q[0] - p[0], q[1] - p[1]);
      if (l < 0.5) continue;
      const ux = (q[0] - p[0]) / l, uy = (q[1] - p[1]) / l;
      let u0 = 1e9, u1 = -1e9, v0 = 1e9, v1 = -1e9;
      for (const t of r) { const u = t[0] * ux + t[1] * uy, v = -t[0] * uy + t[1] * ux; u0 = Math.min(u0, u); u1 = Math.max(u1, u); v0 = Math.min(v0, v); v1 = Math.max(v1, v); }
      const a = (u1 - u0) * (v1 - v0);
      if (!best || a < best.a) best = { a, ux, uy, u0, u1, v0, v1 };
    }
    if (!best) return null;
    const cu = (best.u0 + best.u1) / 2, cv = (best.v0 + best.v1) / 2;
    let ax = best.ux, ay = best.uy, L = best.u1 - best.u0, W = best.v1 - best.v0;
    if (W > L) { [ax, ay] = [-ay, ax]; [L, W] = [W, L]; }  // the long axis comes first
    return { ax, ay, L, W, cx: cu * best.ux - cv * best.uy, cy: cu * best.uy + cv * best.ux, area: best.a };
  }

  class Tris {
    constructor() { this.v = []; }
    // one flat triangle, normal from the winding (counter clockwise seen from outside); degenerate ones are dropped
    tri(a, b, c) {
      const ux = b[0] - a[0], uy = b[1] - a[1], uz = b[2] - a[2], vx = c[0] - a[0], vy = c[1] - a[1], vz = c[2] - a[2];
      let nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
      const l = Math.hypot(nx, ny, nz);
      if (l < 1e-9) return;
      nx /= l; ny /= l; nz /= l;
      this.v.push(a[0], a[1], a[2], nx, ny, nz, 1, b[0], b[1], b[2], nx, ny, nz, 1, c[0], c[1], c[2], nx, ny, nz, 1);
    }
    quad(a, b, c, d) { this.tri(a, b, c); this.tri(a, c, d); }
  }
  const defaultRise = (kind, W) => (kind === "pyramidal" ? Math.min(12, Math.max(2, W * 0.45)) : kind === "skillion" ? Math.min(4, Math.max(1, W * 0.22)) : kind === "dome" ? Math.max(1.5, W * 0.45) : Math.min(7, Math.max(1.6, W * 0.33)));

  // adds one roof to t. ring: local metres, counter clockwise. z0: height of the eaves. Returns false when the footprint does not suit the shape.
  function addRoof(t, kind, ring, z0, rise, dirDeg) {
    if (ring.length < 3) return false;
    const box = obb(ring);
    if (!box) return false;
    const rectangular = Math.abs(area2(ring)) / 2 / box.area > 0.82;
    const R = rise > 0 ? rise : defaultRise(kind, box.W);
    const P = (u, v, z) => [box.cx + u * box.ax - v * box.ay, box.cy + u * box.ay + v * box.ax, z];  // u along the long side, v across
    const hl = box.L / 2, hw = box.W / 2;
    if (kind === "gabled") {
      if (!rectangular || box.W < 2) return false;
      t.quad(P(-hl, -hw, z0), P(hl, -hw, z0), P(hl, 0, z0 + R), P(-hl, 0, z0 + R));       // south slope
      t.quad(P(hl, hw, z0), P(-hl, hw, z0), P(-hl, 0, z0 + R), P(hl, 0, z0 + R));         // north slope
      t.tri(P(hl, -hw, z0), P(hl, hw, z0), P(hl, 0, z0 + R));                              // gable ends
      t.tri(P(-hl, hw, z0), P(-hl, -hw, z0), P(-hl, 0, z0 + R));
      return true;
    }
    if (kind === "hipped") {
      if (!rectangular || box.W < 2) return false;
      const r = Math.max(0, hl - hw);  // the ridge ends where the hips meet
      t.quad(P(-hl, -hw, z0), P(hl, -hw, z0), P(r, 0, z0 + R), P(-r, 0, z0 + R));
      t.quad(P(hl, hw, z0), P(-hl, hw, z0), P(-r, 0, z0 + R), P(r, 0, z0 + R));
      t.tri(P(hl, -hw, z0), P(hl, hw, z0), P(r, 0, z0 + R));
      t.tri(P(-hl, hw, z0), P(-hl, -hw, z0), P(-r, 0, z0 + R));
      return true;
    }
    if (kind === "skillion") {
      if (!rectangular || box.W < 2) return false;
      let dv = -1;  // downslope towards the south side of the box unless a direction is given
      if (dirDeg != null) { const dx = Math.sin((dirDeg * Math.PI) / 180), dy = Math.cos((dirDeg * Math.PI) / 180); dv = dx * -box.ay + dy * box.ax >= 0 ? 1 : -1; }
      const lo = dv * hw, hi = -dv * hw;
      t.quad(P(-hl, lo, z0), P(hl, lo, z0), P(hl, hi, z0 + R), P(-hl, hi, z0 + R));
      const s0 = P(-hl, hi, z0), s1 = P(hl, hi, z0), h0 = P(-hl, hi, z0 + R), h1 = P(hl, hi, z0 + R);
      if (dv < 0) { t.quad(s1, s0, h0, h1); t.tri(P(hl, lo, z0), P(hl, hi, z0), h1); t.tri(P(-hl, hi, z0), P(-hl, lo, z0), h0); }
      else { t.quad(s0, s1, h1, h0); t.tri(P(hl, hi, z0), P(hl, lo, z0), h1); t.tri(P(-hl, lo, z0), P(-hl, hi, z0), h0); }
      return true;
    }
    if (kind === "pyramidal") {
      if (!isConvex(ring)) return false;
      let cx = 0, cy = 0; for (const p of ring) { cx += p[0]; cy += p[1]; } cx /= ring.length; cy /= ring.length;
      const apex = [cx, cy, z0 + R];
      for (let i = 0; i < ring.length; i++) { const a = ring[i], b = ring[(i + 1) % ring.length]; t.tri([a[0], a[1], z0], [b[0], b[1], z0], apex); }
      return true;
    }
    if (kind === "dome") {
      if (!isConvex(ring) || box.W < 3) return false;
      const rings = 5, seg = 14;
      for (let k = 0; k < rings; k++) {
        const a0 = (k / rings) * (Math.PI / 2), a1 = ((k + 1) / rings) * (Math.PI / 2), s0 = Math.cos(a0), s1 = Math.cos(a1), z1 = z0 + Math.sin(a0) * R, z2 = z0 + Math.sin(a1) * R;
        for (let i = 0; i < seg; i++) {
          const b0 = (i / seg) * Math.PI * 2, b1 = ((i + 1) / seg) * Math.PI * 2;
          const q = (s, b, z) => P(Math.cos(b) * hl * s, Math.sin(b) * hw * s, z);
          if (k === rings - 1) t.tri(q(s0, b0, z1), q(s0, b1, z1), q(0, 0, z2)); else t.quad(q(s0, b0, z1), q(s0, b1, z1), q(s1, b1, z2), q(s1, b0, z2));
        }
      }
      return true;
    }
    return false;
  }

  // ---- colours: roof:colour when it is a hex or a plain colour name, otherwise from the material
  const NAMED = { red: "#a8483a", brown: "#6e4f3f", grey: "#6f757c", gray: "#6f757c", black: "#33373c", green: "#5f8f7c", white: "#d8d5cc", blue: "#4e6a8a", orange: "#b4694a", yellow: "#c9b36a" };
  const MATERIAL = { roof_tiles: "#b4604a", tile: "#b4604a", tiles: "#b4604a", slate: "#565c64", metal: "#8c939b", metal_sheet: "#8c939b", copper: "#6f9a8a", tar_paper: "#4b4e52", concrete: "#7d7f82", thatch: "#9a8658", stone: "#8a8478", glass: "#8fb0c2", eternit: "#7a7f84", asbestos: "#7a7f84" };
  function colorOf(tags) {
    const c = (tags.col || "").toLowerCase();
    if (/^#[0-9a-f]{6}$/.test(c)) return c;
    if (NAMED[c]) return NAMED[c];
    return MATERIAL[tags.mat] || "#a8573f";
  }
  // roof height above the eaves: roof:height, else roof:levels * 3, else null (a default by shape)
  const riseOf = (w) => (w.rh > 0 ? w.rh : w.rlv > 0 ? w.rlv * 3 : 0);

  // builds meshes grouped by colour: Map hex -> { vertex: Float32Array (pos3 nrm3 part1 per vertex), index: Uint16Array, triangles }. heightOf(w) gives the eaves height.
  function build(ways, anchor, heightOf) {
    const groups = new Map();
    let used = 0;
    for (const w of ways) {
      const kind = kindOf(w.shape);
      if (!kind || !w.pts || w.pts.length < 4) continue;
      const hex = colorOf({ col: w.col, mat: w.mat });
      let g = groups.get(hex);
      if (!g) { g = new Tris(); groups.set(hex, g); }
      const mark = g.v.length;
      if (addRoof(g, kind, toLocal(w.pts, anchor), heightOf(w), riseOf(w), w.dir ?? null)) used++; else g.v.length = mark;
    }
    const out = new Map();
    for (const [hex, g] of groups) {
      const n = g.v.length / 7;
      if (!n || n > 65000) continue;  // a chunk of more than 16 bit indices would need splitting; real city tiles stay far below it
      out.set(hex, { vertex: new Float32Array(g.v), index: Uint16Array.from({ length: n }, (_, i) => i), triangles: n / 3 });
    }
    return { meshes: out, used };
  }

  window.Roofs = { kindOf, toLocal, obb, isConvex, addRoof, Tris, colorOf, build, defaultRise };
})();
