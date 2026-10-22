"use strict";
// 3D Road and Rail Geometries for the diorama:
//  - 3D road surfaces with physical width, asphalt pavement and curbs
//  - Elevated overpasses and bridges with concrete decks, parapets, and support piers
//  - Tunnel portals at tunnel entrances and exits
//  - 3D railway tracks with ballast embankment, sleepers, and twin steel rails
//  - Catenary support masts and real overhead electric traction wires above electrified rails
(() => {
  const S3 = window.Scene3D;
  const PART = S3 ? S3.PART : { SKIRT: 0, BODY: 1, STRIPE: 2, ROOF: 3, GLASS: 4, DARK: 5, HEAD: 6, TAIL: 7 };

  // Road widths (total metres) by road class
  const ROAD_WIDTH = {
    motorway: 11.0,
    trunk: 9.2,
    primary: 7.8,
    secondary: 7.0,
    tertiary: 6.2,
    minor: 5.4,
    residential: 5.4,
    service: 3.6,
    track: 3.0,
  };
  const roadWidth = (cls) => ROAD_WIDTH[cls] || 5.4;

  const ALIAS_ROAD = {
    motorway_link: "motorway",
    trunk_link: "trunk",
    primary_link: "primary",
    secondary_link: "secondary",
    tertiary_link: "tertiary",
    street: "minor",
    living_street: "service",
  };
  const normalizeRoad = (c) => (c in ALIAS_ROAD ? ALIAS_ROAD[c] : c in ROAD_WIDTH ? c : null);

  const isRail = (p) => {
    const c = p.class, sc = p.subclass;
    return c === "rail" || c === "transit" || c === "tram" || c === "subway" || c === "light_rail" ||
           sc === "rail" || sc === "tram" || sc === "subway" || sc === "light_rail";
  };

  const isElectrified = (p) => {
    if (!isRail(p)) return false;
    if (p.electrified === "no" || p.electrified === 0 || p.electrified === "0" || p.electrified === false) return false;
    if (p.electrified === "yes" || p.electrified === "contact_line" || p.electrified === 1 || p.electrified === "1") return true;
    // Default in central Europe (Poland/Silesia): tramways and standard railway lines are electrified overhead
    const c = p.class, sc = p.subclass;
    if (c === "tram" || sc === "tram" || c === "subway" || sc === "subway") return true;
    if ((c === "rail" || sc === "rail") && sc !== "narrow_gauge" && p.service !== "yard") return true;
    return false;
  };

  // Triangle collector with normals and part id
  class TriBuffer {
    constructor() { this.v = []; }
    tri(a, b, c, part = 1) {
      const ux = b[0] - a[0], uy = b[1] - a[1], uz = b[2] - a[2];
      const vx = c[0] - a[0], vy = c[1] - a[1], vz = c[2] - a[2];
      let nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
      const l = Math.hypot(nx, ny, nz);
      if (l < 1e-9) return;
      nx /= l; ny /= l; nz /= l;
      this.v.push(
        a[0], a[1], a[2], nx, ny, nz, part,
        b[0], b[1], b[2], nx, ny, nz, part,
        c[0], c[1], c[2], nx, ny, nz, part
      );
    }
    quad(a, b, c, d, part = 1) {
      this.tri(a, b, c, part);
      this.tri(a, c, d, part);
    }
    // Box aligned with local orientation
    box(cx, cy, cz, hx, hy, hz, ux, uy, part = 1) {
      const nx = -uy, ny = ux; // perpendicular
      const p = (sx, sy, sz) => [
        cx + ux * (sx * hx) + nx * (sy * hy),
        cy + uy * (sx * hx) + ny * (sy * hy),
        cz + sz * hz
      ];
      // 6 faces
      this.quad(p(1, -1, -1), p(1, 1, -1), p(1, 1, 1), p(1, -1, 1), part);     // +x
      this.quad(p(-1, 1, -1), p(-1, -1, -1), p(-1, -1, 1), p(-1, 1, 1), part);  // -x
      this.quad(p(-1, 1, -1), p(1, 1, -1), p(1, 1, 1), p(-1, 1, 1), part);     // +y
      this.quad(p(1, -1, -1), p(-1, -1, -1), p(-1, -1, 1), p(1, -1, 1), part);  // -y
      this.quad(p(-1, -1, 1), p(1, -1, 1), p(1, 1, 1), p(-1, 1, 1), part);     // top
      this.quad(p(-1, 1, -1), p(1, 1, -1), p(1, -1, -1), p(-1, -1, -1), part);  // bottom
    }
    cylinder(cx, cy, z0, z1, r, part = 1, seg = 8) {
      for (let i = 0; i < seg; i++) {
        const a0 = (i / seg) * Math.PI * 2, a1 = ((i + 1) / seg) * Math.PI * 2;
        const c0 = Math.cos(a0) * r, s0 = Math.sin(a0) * r;
        const c1 = Math.cos(a1) * r, s1 = Math.sin(a1) * r;
        const p0 = [cx + c0, cy + s0, z0], p1 = [cx + c1, cy + s1, z0];
        const q1 = [cx + c1, cy + s1, z1], q0 = [cx + c0, cy + s0, z1];
        this.quad(p0, p1, q1, q0, part);
      }
    }
    toMesh() {
      const n = this.v.length / 7;
      if (!n) return null;
      return {
        vertex: new Float32Array(this.v),
        index: Uint16Array.from({ length: n }, (_, i) => i),
        triangles: n / 3,
      };
    }
  }

  // Convert coordinate array to local metres from anchor
  function polylineLocal(coords, anchor) {
    const ky = 111320, kx = 111320 * Math.cos((anchor.lat * Math.PI) / 180);
    const n = coords.length, pts = [];
    for (let i = 0; i < n; i++) {
      pts.push([(coords[i][0] - anchor.lon) * kx, (coords[i][1] - anchor.lat) * ky]);
    }
    return pts;
  }

  // Segment normals and lengths
  function lineMetrics(pts) {
    const n = pts.length;
    const len = new Float64Array(n), cum = new Float64Array(n);
    const ux = new Float64Array(n), uy = new Float64Array(n);
    for (let i = 0; i < n - 1; i++) {
      const dx = pts[i + 1][0] - pts[i][0], dy = pts[i + 1][1] - pts[i][1];
      const l = Math.hypot(dx, dy) || 1e-6;
      len[i] = l;
      cum[i + 1] = cum[i] + l;
      ux[i] = dx / l;
      uy[i] = dy / l;
    }
    ux[n - 1] = ux[n - 2] || 1;
    uy[n - 1] = uy[n - 2] || 0;
    return { len, cum, ux, uy, total: cum[n - 1] };
  }

  // Vertex normals along polyline (mitered perpendiculars)
  function vertexPerps(pts, m) {
    const n = pts.length;
    const px = new Float64Array(n), py = new Float64Array(n);
    for (let i = 0; i < n; i++) {
      let dx = 0, dy = 0;
      if (i > 0) { dx += m.ux[i - 1]; dy += m.uy[i - 1]; }
      if (i < n - 1) { dx += m.ux[i]; dy += m.uy[i]; }
      const l = Math.hypot(dx, dy) || 1;
      dx /= l; dy /= l;
      // Perpendicular to forward tangent (pointing to the left)
      px[i] = -dy;
      py[i] = dx;
    }
    return { px, py };
  }

  // ---------------------------------------------------------------- Road Builder
  function buildRoadGeometry(bufAsphalt, bufConcrete, pts, cls, brunnel, layer, groundFn) {
    const n = pts.length;
    if (n < 2) return;
    const m = lineMetrics(pts);
    if (m.total < 4) return;
    const { px, py } = vertexPerps(pts, m);
    const w = roadWidth(cls), hw = w * 0.5;
    const isBridge = brunnel === "bridge" || layer > 0;
    const isTunnel = brunnel === "tunnel" || layer < 0;

    const bridgeHeight = isBridge ? Math.max(1, layer || 1) * 5.2 : 0;
    const rampLen = Math.min(24, m.total * 0.25);

    // Height calculation at point i along the line
    const zAt = (i) => {
      const g = groundFn ? groundFn(pts[i][0], pts[i][1]) : 0;
      if (!isBridge) {
        return g + (isTunnel ? -0.1 : 0.1);
      }
      const s = m.cum[i];
      let ramp = 1;
      if (s < rampLen) ramp = s / rampLen;
      else if (s > m.total - rampLen) ramp = (m.total - s) / rampLen;
      return g + bridgeHeight * ramp + 0.1;
    };

    // 1. Asphalt road surface
    for (let i = 0; i < n - 1; i++) {
      const z0 = zAt(i), z1 = zAt(i + 1);
      const l0 = [pts[i][0] + px[i] * hw, pts[i][1] + py[i] * hw, z0];
      const r0 = [pts[i][0] - px[i] * hw, pts[i][1] - py[i] * hw, z0];
      const l1 = [pts[i + 1][0] + px[i + 1] * hw, pts[i + 1][1] + py[i + 1] * hw, z1];
      const r1 = [pts[i + 1][0] - px[i + 1] * hw, pts[i + 1][1] - py[i + 1] * hw, z1];
      bufAsphalt.quad(r0, l0, l1, r1, PART.BODY);
    }

    // 2. Curbs or Bridge parapets
    const curbW = isBridge ? 0.4 : 0.22;
    const curbH = isBridge ? 0.9 : 0.14;
    for (let i = 0; i < n - 1; i++) {
      const z0 = zAt(i), z1 = zAt(i + 1);
      // Left curb
      const l0In = [pts[i][0] + px[i] * hw, pts[i][1] + py[i] * hw, z0];
      const l0Out = [pts[i][0] + px[i] * (hw + curbW), pts[i][1] + py[i] * (hw + curbW), z0 + curbH];
      const l1In = [pts[i + 1][0] + px[i + 1] * hw, pts[i + 1][1] + py[i + 1] * hw, z1];
      const l1Out = [pts[i + 1][0] + px[i + 1] * (hw + curbW), pts[i + 1][1] + py[i + 1] * (hw + curbW), z1 + curbH];
      bufConcrete.quad(l0In, l0Out, l1Out, l1In, PART.ROOF);

      // Right curb
      const r0In = [pts[i][0] - px[i] * hw, pts[i][1] - py[i] * hw, z0];
      const r0Out = [pts[i][0] - px[i] * (hw + curbW), pts[i][1] - py[i] * (hw + curbW), z0 + curbH];
      const r1In = [pts[i + 1][0] - px[i + 1] * hw, pts[i + 1][1] - py[i + 1] * hw, z1];
      const r1Out = [pts[i + 1][0] - px[i + 1] * (hw + curbW), pts[i + 1][1] - py[i + 1] * (hw + curbW), z1 + curbH];
      bufConcrete.quad(r0Out, r0In, r1In, r1Out, PART.ROOF);
    }

    // 3. Bridge structure (deck thickness, underside and vertical support piers)
    if (isBridge && m.total >= rampLen * 2) {
      const deckThick = 0.7;
      // Deck slab sides and underside
      for (let i = 0; i < n - 1; i++) {
        const s = (m.cum[i] + m.cum[i + 1]) * 0.5;
        if (s < rampLen || s > m.total - rampLen) continue;
        const z0 = zAt(i), z1 = zAt(i + 1);
        const wTotal = hw + curbW;
        // Underside quad
        const u0L = [pts[i][0] + px[i] * wTotal, pts[i][1] + py[i] * wTotal, z0 - deckThick];
        const u0R = [pts[i][0] - px[i] * wTotal, pts[i][1] - py[i] * wTotal, z0 - deckThick];
        const u1L = [pts[i + 1][0] + px[i + 1] * wTotal, pts[i + 1][1] + py[i + 1] * wTotal, z1 - deckThick];
        const u1R = [pts[i + 1][0] - px[i + 1] * wTotal, pts[i + 1][1] - py[i + 1] * wTotal, z1 - deckThick];
        bufConcrete.quad(u0R, u1R, u1L, u0L, PART.DARK);

        // Outer slab left vertical face
        const o0L = [pts[i][0] + px[i] * wTotal, pts[i][1] + py[i] * wTotal, z0 + curbH];
        const o1L = [pts[i + 1][0] + px[i + 1] * wTotal, pts[i + 1][1] + py[i + 1] * wTotal, z1 + curbH];
        bufConcrete.quad(u0L, u1L, o1L, o0L, PART.ROOF);

        // Outer slab right vertical face
        const o0R = [pts[i][0] - px[i] * wTotal, pts[i][1] - py[i] * wTotal, z0 + curbH];
        const o1R = [pts[i + 1][0] - px[i + 1] * wTotal, pts[i + 1][1] - py[i + 1] * wTotal, z1 + curbH];
        bufConcrete.quad(o0R, o1R, u1R, u0R, PART.ROOF);
      }

      // Vertical Support Piers placed every ~28m along the span
      const pierSpan = 28;
      for (let s = rampLen + 10; s <= m.total - rampLen - 5; s += pierSpan) {
        let idx = 0;
        while (idx < n - 2 && m.cum[idx + 1] < s) idx++;
        const t = (s - m.cum[idx]) / (m.len[idx] || 1);
        const cx = pts[idx][0] + (pts[idx + 1][0] - pts[idx][0]) * t;
        const cy = pts[idx][1] + (pts[idx + 1][1] - pts[idx][1]) * t;
        const ground = groundFn ? groundFn(cx, cy) : 0;
        const deckZ = ground + bridgeHeight + 0.1 - deckThick;
        if (deckZ > ground + 1.2) {
          // Concrete column pier
          bufConcrete.cylinder(cx, cy, ground, deckZ, 0.75, PART.ROOF, 8);
          // Column capital/head
          bufConcrete.box(cx, cy, deckZ - 0.2, 1.2, hw * 0.9, 0.25, m.ux[idx], m.uy[idx], PART.ROOF);
        }
      }
    }

    // 4. Tunnel portals
    if (isTunnel && n >= 2) {
      for (const endIdx of [0, n - 1]) {
        const isStart = endIdx === 0;
        const pt = pts[endIdx];
        const dir = isStart ? [m.ux[0], m.uy[0]] : [-m.ux[n - 2], -m.uy[n - 2]];
        const pz = zAt(endIdx);
        // Portal arch frame
        const ptx = pt[0], pty = pt[1];
        const span = hw + 0.8;
        bufConcrete.box(ptx + dir[0] * 1.0, pty + dir[1] * 1.0, pz + 2.4, 0.9, span + 0.5, 2.4, dir[0], dir[1], PART.ROOF);
        // Dark recessed portal opening
        bufConcrete.box(ptx - dir[0] * 0.5, pty - dir[1] * 0.5, pz + 2.1, 0.4, span - 0.2, 2.1, dir[0], dir[1], PART.DARK);
      }
    }
  }

  // ---------------------------------------------------------------- Rail Builder
  function buildRailGeometry(bufBallast, bufSteel, bufTraction, pts, brunnel, layer, electrified, groundFn) {
    const n = pts.length;
    if (n < 2) return;
    const m = lineMetrics(pts);
    if (m.total < 4) return;
    const { px, py } = vertexPerps(pts, m);
    const isBridge = brunnel === "bridge" || layer > 0;
    const bridgeHeight = isBridge ? Math.max(1, layer || 1) * 5.2 : 0;
    const rampLen = Math.min(28, m.total * 0.25);

    const zAt = (i) => {
      const g = groundFn ? groundFn(pts[i][0], pts[i][1]) : 0;
      if (!isBridge) return g + 0.12;
      const s = m.cum[i];
      let ramp = 1;
      if (s < rampLen) ramp = s / rampLen;
      else if (s > m.total - rampLen) ramp = (m.total - s) / rampLen;
      return g + bridgeHeight * ramp + 0.12;
    };

    // 1. Ballast bed (gravel prism: top width 3.2m, bottom width 4.2m, height 0.24m)
    const topW = 1.6, botW = 2.1, bH = 0.24;
    for (let i = 0; i < n - 1; i++) {
      const z0 = zAt(i), z1 = zAt(i + 1);
      // Top flat surface of ballast
      const t0L = [pts[i][0] + px[i] * topW, pts[i][1] + py[i] * topW, z0 + bH];
      const t0R = [pts[i][0] - px[i] * topW, pts[i][1] - py[i] * topW, z0 + bH];
      const t1L = [pts[i + 1][0] + px[i + 1] * topW, pts[i + 1][1] + py[i + 1] * topW, z1 + bH];
      const t1R = [pts[i + 1][0] - px[i + 1] * topW, pts[i + 1][1] - py[i + 1] * topW, z1 + bH];
      bufBallast.quad(t0R, t0L, t1L, t1R, PART.BODY);

      // Left sloping embankment
      const b0L = [pts[i][0] + px[i] * botW, pts[i][1] + py[i] * botW, z0];
      const b1L = [pts[i + 1][0] + px[i + 1] * botW, pts[i + 1][1] + py[i + 1] * botW, z1];
      bufBallast.quad(b0L, t0L, t1L, b1L, PART.BODY);

      // Right sloping embankment
      const b0R = [pts[i][0] - px[i] * botW, pts[i][1] - py[i] * botW, z0];
      const b1R = [pts[i + 1][0] - px[i + 1] * botW, pts[i + 1][1] - py[i + 1] * botW, z1];
      bufBallast.quad(t0R, b0R, b1R, t1R, PART.BODY);
    }

    // 2. Twin steel rails (standard gauge 1.435m, centered at +/- 0.717m)
    const railGaugeHalf = 0.7175;
    const railW = 0.07, railH = 0.16;
    for (let i = 0; i < n - 1; i++) {
      const z0 = zAt(i) + bH, z1 = zAt(i + 1) + bH;
      for (const side of [-1, 1]) {
        const off = side * railGaugeHalf;
        const p0c = [pts[i][0] + px[i] * off, pts[i][1] + py[i] * off];
        const p1c = [pts[i + 1][0] + px[i + 1] * off, pts[i + 1][1] + py[i + 1] * off];

        const r0L = [p0c[0] + px[i] * (railW * 0.5), p0c[1] + py[i] * (railW * 0.5), z0 + railH];
        const r0R = [p0c[0] - px[i] * (railW * 0.5), p0c[1] - py[i] * (railW * 0.5), z0 + railH];
        const r1L = [p1c[0] + px[i + 1] * (railW * 0.5), p1c[1] + py[i + 1] * (railW * 0.5), z1 + railH];
        const r1R = [p1c[0] - px[i + 1] * (railW * 0.5), p1c[1] - py[i + 1] * (railW * 0.5), z1 + railH];

        // Rail head top surface
        bufSteel.quad(r0R, r0L, r1L, r1R, PART.STRIPE);
        // Rail sides
        const s0L = [p0c[0] + px[i] * (railW * 0.5), p0c[1] + py[i] * (railW * 0.5), z0];
        const s1L = [p1c[0] + px[i + 1] * (railW * 0.5), p1c[1] + py[i + 1] * (railW * 0.5), z1];
        bufSteel.quad(s0L, r0L, r1L, s1L, PART.DARK);
        const s0R = [p0c[0] - px[i] * (railW * 0.5), p0c[1] - py[i] * (railW * 0.5), z0];
        const s1R = [p1c[0] - px[i + 1] * (railW * 0.5), p1c[1] - py[i + 1] * (railW * 0.5), z1];
        bufSteel.quad(r0R, s0R, s1R, r1R, PART.DARK);
      }
    }

    // 3. Rail Viaduct bridge piers
    if (isBridge && m.total >= rampLen * 2) {
      const pierSpan = 30;
      for (let s = rampLen + 10; s <= m.total - rampLen - 5; s += pierSpan) {
        let idx = 0;
        while (idx < n - 2 && m.cum[idx + 1] < s) idx++;
        const t = (s - m.cum[idx]) / (m.len[idx] || 1);
        const cx = pts[idx][0] + (pts[idx + 1][0] - pts[idx][0]) * t;
        const cy = pts[idx][1] + (pts[idx + 1][1] - pts[idx][1]) * t;
        const ground = groundFn ? groundFn(cx, cy) : 0;
        const deckZ = ground + bridgeHeight + 0.1;
        if (deckZ > ground + 1.2) {
          bufBallast.cylinder(cx, cy, ground, deckZ, 0.9, PART.ROOF, 8);
        }
      }
    }

    // 4. Overhead Catenary Wires & Traction Poles (Electrified lines)
    if (electrified) {
      const wireContactZ = 5.25;
      const wireMessengerZ = 6.45;
      const wireThick = 0.035;

      // Continuous contact wire and messenger wire
      for (let i = 0; i < n - 1; i++) {
        const z0 = zAt(i) + bH, z1 = zAt(i + 1) + bH;
        // Contact wire (lower)
        const c0L = [pts[i][0] + px[i] * wireThick, pts[i][1] + py[i] * wireThick, z0 + wireContactZ];
        const c0R = [pts[i][0] - px[i] * wireThick, pts[i][1] - py[i] * wireThick, z0 + wireContactZ];
        const c1L = [pts[i + 1][0] + px[i + 1] * wireThick, pts[i + 1][1] + py[i + 1] * wireThick, z1 + wireContactZ];
        const c1R = [pts[i + 1][0] - px[i + 1] * wireThick, pts[i + 1][1] - py[i + 1] * wireThick, z1 + wireContactZ];
        bufTraction.quad(c0R, c0L, c1L, c1R, PART.DARK);

        // Messenger wire (upper)
        const m0L = [pts[i][0] + px[i] * wireThick, pts[i][1] + py[i] * wireThick, z0 + wireMessengerZ];
        const m0R = [pts[i][0] - px[i] * wireThick, pts[i][1] - py[i] * wireThick, z0 + wireMessengerZ];
        const m1L = [pts[i + 1][0] + px[i + 1] * wireThick, pts[i + 1][1] + py[i + 1] * wireThick, z1 + wireMessengerZ];
        const m1R = [pts[i + 1][0] - px[i + 1] * wireThick, pts[i + 1][1] - py[i + 1] * wireThick, z1 + wireMessengerZ];
        bufTraction.quad(m0R, m0L, m1L, m1R, PART.DARK);
      }

      // Vertical droppers / hangers connecting messenger and contact wire every ~9m
      const dropperSpan = 9.0;
      for (let s = 4; s < m.total - 4; s += dropperSpan) {
        let idx = 0;
        while (idx < n - 2 && m.cum[idx + 1] < s) idx++;
        const t = (s - m.cum[idx]) / (m.len[idx] || 1);
        const cx = pts[idx][0] + (pts[idx + 1][0] - pts[idx][0]) * t;
        const cy = pts[idx][1] + (pts[idx + 1][1] - pts[idx][1]) * t;
        const baseZ = (zAt(idx) + zAt(idx + 1)) * 0.5 + bH;
        bufTraction.box(cx, cy, baseZ + (wireContactZ + wireMessengerZ) * 0.5, 0.02, 0.02, (wireMessengerZ - wireContactZ) * 0.5, m.ux[idx], m.uy[idx], PART.DARK);
      }

      // Catenary Masts / Traction Poles placed every ~36m
      const poleSpan = 36.0;
      const mastOffset = 2.7; // metres to the right of the track
      for (let s = 6; s <= m.total - 6; s += poleSpan) {
        let idx = 0;
        while (idx < n - 2 && m.cum[idx + 1] < s) idx++;
        const t = (s - m.cum[idx]) / (m.len[idx] || 1);
        const tx = pts[idx][0] + (pts[idx + 1][0] - pts[idx][0]) * t;
        const ty = pts[idx][1] + (pts[idx + 1][1] - pts[idx][1]) * t;
        const uxx = m.ux[idx], uyy = m.uy[idx];
        const pxx = -uyy, pyy = uxx; // left
        const baseZ = (zAt(idx) + zAt(idx + 1)) * 0.5;

        // Mast pole on the right side of the track
        const mx = tx - pxx * mastOffset;
        const my = ty - pyy * mastOffset;
        const mastH = 7.6;
        bufTraction.cylinder(mx, my, baseZ, baseZ + mastH, 0.14, PART.DARK, 6);

        // Horizontal cantilever bracket reaching out over the track center
        const armLen = mastOffset + 0.3;
        const armMidX = mx + pxx * (armLen * 0.5);
        const armMidY = my + pyy * (armLen * 0.5);
        bufTraction.box(armMidX, armMidY, baseZ + wireMessengerZ + 0.1, 0.05, armLen * 0.5, 0.05, uxx, uyy, PART.DARK);
        bufTraction.box(armMidX, armMidY, baseZ + wireContactZ + 0.05, 0.04, armLen * 0.45, 0.04, uxx, uyy, PART.DARK);
        // Insulator near the tip
        bufTraction.cylinder(tx, ty, baseZ + wireMessengerZ, baseZ + wireMessengerZ + 0.25, 0.08, PART.HEAD, 6);
      }
    }
  }

  // ---------------------------------------------------------------- Main Builder
  // Takes features array from openmaptiles transportation layer, anchor { lon, lat }, and optional ground elevation sampler
  function build({ features, anchor, groundFn }) {
    const bufAsphalt = new TriBuffer();
    const bufConcrete = new TriBuffer();
    const bufBallast = new TriBuffer();
    const bufSteel = new TriBuffer();
    const bufTraction = new TriBuffer();

    const seen = new Set();
    let roadCount = 0, railCount = 0, electrifiedCount = 0;

    for (const f of features) {
      const p = f.properties || {};
      const g = f.geometry;
      if (!g) continue;
      const lines = g.type === "LineString" ? [g.coordinates] : g.type === "MultiLineString" ? g.coordinates : [];

      const brunnel = p.brunnel || "";
      const layer = typeof p.layer === "number" ? p.layer : parseInt(p.layer, 10) || 0;
      const rail = isRail(p);
      const cls = rail ? (p.class || p.subclass) : normalizeRoad(p.class);

      if (!cls) continue;

      for (const line of lines) {
        if (line.length < 2) continue;
        const key = `${line[0][0].toFixed(5)},${line[0][1].toFixed(5)}_${line[line.length - 1][0].toFixed(5)},${line[line.length - 1][1].toFixed(5)}_${cls}`;
        if (seen.has(key)) continue;
        seen.add(key);

        const pts = polylineLocal(line, anchor);

        if (rail) {
          railCount++;
          const elec = isElectrified(p);
          if (elec) electrifiedCount++;
          buildRailGeometry(bufBallast, bufSteel, bufTraction, pts, brunnel, layer, elec, groundFn);
        } else {
          roadCount++;
          buildRoadGeometry(bufAsphalt, bufConcrete, pts, cls, brunnel, layer, groundFn);
        }
      }
    }

    return {
      meshes: {
        road_asphalt: bufAsphalt.toMesh(),
        road_concrete: bufConcrete.toMesh(),
        rail_ballast: bufBallast.toMesh(),
        rail_steel: bufSteel.toMesh(),
        rail_traction: bufTraction.toMesh(),
      },
      stats: { roadCount, railCount, electrifiedCount },
    };
  }

  // Material RGB tints for rendering with standard shader
  const COLORS = {
    road_asphalt: [52, 55, 60],
    road_concrete: [142, 146, 154],
    rail_ballast: [78, 74, 70],
    rail_steel: [165, 172, 182],
    rail_traction: [82, 88, 96],
  };

  window.Roads3D = {
    build,
    buildRoadGeometry,
    buildRailGeometry,
    roadWidth,
    normalizeRoad,
    isRail,
    isElectrified,
    COLORS,
    TriBuffer,
    lineMetrics,
  };
})();
