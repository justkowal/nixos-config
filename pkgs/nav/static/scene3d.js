"use strict";
// Scene3D: one MapLibre custom layer that draws every dynamic 3D thing with instancing.
//  - meshes are built once (low poly, per-vertex "part" id for the livery) and drawn many times from a small instance buffer
//  - the per-frame cost is one typed-array write per batch plus a few draw calls, independent of how detailed the meshes are
//  - positions are offsets in metres from a per-frame origin, so float32 keeps centimetre precision anywhere
//  - Daylight (sun, sky, night) enters as uniforms
// Extending it (street lights, trees, traffic): build a mesh with MeshBuilder, register it with registerMesh(), fill an InstanceBatch each frame
// (dynamic) or once (static) and attach it with addBatch(). Nothing else in the renderer has to change.
(() => {
  // ================================================================ pure geometry (no GL, unit tested)
  // local mesh frame: x forward, y left, z up, metres. Parts: 0 skirt, 1 body, 2 stripe, 3 roof (livery), 4 glass, 5 dark equipment, 6 headlight, 7 tail light
  const PART = { SKIRT: 0, BODY: 1, STRIPE: 2, ROOF: 3, GLASS: 4, DARK: 5, HEAD: 6, TAIL: 7 };

  class MeshBuilder {
    constructor() { this.pos = []; this.nrm = []; this.part = []; this.idx = []; }
    _quad(a, b, c, d, n, part) {  // a,b,c,d counter clockwise seen from outside
      const base = this.pos.length / 3;
      for (const p of [a, b, c, d]) { this.pos.push(p[0], p[1], p[2]); this.nrm.push(n[0], n[1], n[2]); this.part.push(part); }
      this.idx.push(base, base + 1, base + 2, base, base + 2, base + 3);
    }
    box(x0, x1, y0, y1, z0, z1, part) {
      this._quad([x1, y0, z0], [x1, y1, z0], [x1, y1, z1], [x1, y0, z1], [1, 0, 0], part);
      this._quad([x0, y1, z0], [x0, y0, z0], [x0, y0, z1], [x0, y1, z1], [-1, 0, 0], part);
      this._quad([x1, y1, z0], [x0, y1, z0], [x0, y1, z1], [x1, y1, z1], [0, 1, 0], part);
      this._quad([x0, y0, z0], [x1, y0, z0], [x1, y0, z1], [x0, y0, z1], [0, -1, 0], part);
      this._quad([x0, y0, z1], [x1, y0, z1], [x1, y1, z1], [x0, y1, z1], [0, 0, 1], part);
      this._quad([x0, y1, z0], [x1, y1, z0], [x1, y0, z0], [x0, y0, z0], [0, 0, -1], part);
      return this;
    }
    // convex profile in the x-z plane (counter clockwise seen with x right, z up), extruded along y
    prism(profile, y0, y1, part) {
      const n = profile.length;
      for (let i = 0; i < n; i++) {
        const p = profile[i], q = profile[(i + 1) % n], dx = q[0] - p[0], dz = q[1] - p[1], len = Math.hypot(dx, dz) || 1;
        const nn = [dz / len, 0, -dx / len];
        this._quad([p[0], y1, p[1]], [q[0], y1, q[1]], [q[0], y0, q[1]], [p[0], y0, p[1]], nn, part);
      }
      const base = this.pos.length / 3;
      for (const [y, ny] of [[y1, 1], [y0, -1]]) {  // caps as fans
        const b0 = this.pos.length / 3;
        for (const p of profile) { this.pos.push(p[0], y, p[1]); this.nrm.push(0, ny, 0); this.part.push(part); }
        for (let i = 1; i < n - 1; i++) { if (ny > 0) this.idx.push(b0, b0 + i + 1, b0 + i); else this.idx.push(b0, b0 + i, b0 + i + 1); }
      }
      return base;
    }
    wheel(cx, cz, r, y0, y1, sides = 8) {
      const prof = [];
      for (let i = 0; i < sides; i++) { const a = (i / sides) * Math.PI * 2; prof.push([cx + Math.cos(a) * r, cz + Math.sin(a) * r]); }
      return this.prism(prof, y0, y1, PART.DARK);
    }
    build() {
      const n = this.pos.length / 3, vertex = new Float32Array(n * 7);
      for (let i = 0; i < n; i++) vertex.set([this.pos[i * 3], this.pos[i * 3 + 1], this.pos[i * 3 + 2], this.nrm[i * 3], this.nrm[i * 3 + 1], this.nrm[i * 3 + 2], this.part[i]], i * 7);
      return { vertex, index: new Uint16Array(this.idx), triangles: this.idx.length / 3 };
    }
  }

  // one vehicle body, length L, width W, height H. nose: which ends are streamlined ('front', 'rear', 'both', 'none')
  function carMesh({ L, W, H, nose = "front", bus = false, pantograph = false, loco = false, wheels = 4, bogies = 0 }) {
    const m = new MeshBuilder(), hl = L / 2, hw = W / 2;
    const f = nose === "front" || nose === "both", r = nose === "rear" || nose === "both";
    const rise = loco ? 1.3 : bus ? 0.75 : 1.0;  // how far the nose slopes back at the top
    const prof = [[-hl + (r ? 0.1 : 0), 0.95]];
    prof.push([hl - (f ? 0.2 : 0), 0.95]);
    if (f) prof.push([hl, 1.2], [hl, H - rise], [hl - (bus ? 0.45 : 1.1), H]); else prof.push([hl, H]);
    if (r) prof.push([-hl + 0.4, H], [-hl, H - 0.4], [-hl, 1.2]); else prof.push([-hl, H]);
    m.prism(prof.map((p) => [p[0], p[1]]), -hw, hw, loco ? PART.STRIPE : PART.BODY);
    m.prism([[-hl + 0.1, 0.35], [hl - 0.1, 0.35], [hl - 0.1, 0.99], [-hl + 0.1, 0.99]], -hw + 0.05, hw - 0.05, PART.SKIRT);
    m.box(-hl, hl - (f ? 0.15 : 0), -hw - 0.025, hw + 0.025, 0.95, 1.45, loco ? PART.BODY : PART.STRIPE);
    if (!loco) {
      const w0 = -hl + (r ? 0.9 : 0.5), w1 = hl - (f ? 0.9 : 0.5);
      m.box(w0, w1, hw - 0.03, hw + 0.04, 1.65, H - 0.65, PART.GLASS);
      m.box(w0, w1, -hw - 0.04, -hw + 0.03, 1.65, H - 0.65, PART.GLASS);
    } else {
      m.box(hl - 1.7, hl - 0.9, hw - 0.03, hw + 0.04, H - 1.7, H - 0.7, PART.GLASS);
      m.box(hl - 1.7, hl - 0.9, -hw - 0.04, -hw + 0.03, H - 1.7, H - 0.7, PART.GLASS);
    }
    if (f) { m.box(hl - 0.5, hl + 0.06, -hw + 0.3, hw - 0.3, H - (bus ? 1.9 : 2.1), H - (bus ? 0.55 : 0.8), PART.GLASS); m.box(hl - 0.02, hl + 0.07, hw - 0.7, hw - 0.4, 1.0, 1.2, PART.HEAD); m.box(hl - 0.02, hl + 0.07, -hw + 0.4, -hw + 0.7, 1.0, 1.2, PART.HEAD); }
    if (r) { m.box(-hl - 0.06, -hl + 0.5, -hw + 0.3, hw - 0.3, H - 2.0, H - 0.8, PART.GLASS); m.box(-hl - 0.07, -hl + 0.02, hw - 0.7, hw - 0.4, 1.0, 1.2, PART.TAIL); m.box(-hl - 0.07, -hl + 0.02, -hw + 0.4, -hw + 0.7, 1.0, 1.2, PART.TAIL); }
    if (!f && bus) { m.box(-hl - 0.07, -hl + 0.02, hw - 0.7, hw - 0.4, 1.0, 1.2, PART.TAIL); m.box(-hl - 0.07, -hl + 0.02, -hw + 0.4, -hw + 0.7, 1.0, 1.2, PART.TAIL); }
    m.box(-hl + 0.3, hl - 0.6, -hw + 0.3, hw - 0.3, H - 0.02, H + 0.12, PART.ROOF);
    if (bus) m.box(-1.8, 1.2, -0.8, 0.8, H + 0.1, H + 0.45, PART.DARK);
    else if (loco) m.box(-1.5, 1.5, -0.9, 0.9, H + 0.1, H + 0.4, PART.DARK);
    if (pantograph) { m.box(-0.6, 0.6, -0.45, 0.45, H + 0.1, H + 0.6, PART.DARK); m.box(-0.5, 0.5, -0.9, 0.9, H + 0.6, H + 0.7, PART.DARK); }
    if (wheels) for (const x of wheels === 4 ? [hl - 1.6, -hl + 2.0] : [hl - 1.8, -hl + 1.8]) { m.wheel(x, 0.5, 0.5, hw - 0.3, hw + 0.04); m.wheel(x, 0.5, 0.5, -hw - 0.04, -hw + 0.3); }
    for (let b = 0; b < bogies; b++) { const x = (b === 0 ? -1 : 1) * (hl - 3.0); m.box(x - 1.2, x + 1.2, -hw + 0.2, hw - 0.2, 0.2, 0.9, PART.DARK); }
    return m.build();
  }
  // five road vehicle types for ambient traffic. Painted surfaces use part 1 (body) so the per-instance tint colours them: any colour is possible.
  const ROAD = {
    hatch: { L: 4.0, W: 1.75, H: 1.5, cab: [-1.15, 0.85, 0.5], hood: 0.7 },
    sedan: { L: 4.75, W: 1.85, H: 1.45, cab: [-1.5, 0.95, 0.55], hood: 0.9 },
    suv: { L: 4.7, W: 1.95, H: 1.75, cab: [-1.95, 1.2, 0.35], hood: 0.9 },
  };
  function roadVehicleMesh(type) {
    const m = new MeshBuilder();
    if (type === "van") {
      const L = 5.4, W = 2.0, H = 2.25, hl = L / 2, hw = W / 2;
      m.prism([[-hl, 0.35], [hl, 0.35], [hl, 0.9], [hl - 0.35, 1.05], [hl - 1.3, 1.1], [hl - 1.8, H], [-hl + 0.05, H], [-hl, H - 0.1]].filter((p, i, a) => true), -hw, hw, PART.BODY);
      m.box(hl - 1.75, hl - 1.15, -hw - 0.02, hw + 0.02, 1.2, H - 0.25, PART.GLASS);   // windscreen band (sides)
      m.box(hl - 1.78, hl - 1.3, -hw + 0.1, hw - 0.1, 1.15, H - 0.2, PART.GLASS);
      m.box(hl - 0.03, hl + 0.06, hw - 0.5, hw - 0.2, 0.7, 0.9, PART.HEAD); m.box(hl - 0.03, hl + 0.06, -hw + 0.2, -hw + 0.5, 0.7, 0.9, PART.HEAD);
      m.box(-hl - 0.06, -hl + 0.03, hw - 0.4, hw - 0.15, 0.8, 1.15, PART.TAIL); m.box(-hl - 0.06, -hl + 0.03, -hw + 0.15, -hw + 0.4, 0.8, 1.15, PART.TAIL);
      for (const x of [hl - 1.0, -hl + 1.1]) { m.wheel(x, 0.38, 0.38, hw - 0.28, hw + 0.01); m.wheel(x, 0.38, 0.38, -hw - 0.01, -hw + 0.28); }
      return m.build();
    }
    if (type === "truck") {  // rigid lorry: cab in body colour, load box in the neutral roof colour
      const L = 9.0, W = 2.5, hl = L / 2, hw = W / 2;
      m.prism([[hl - 2.3, 0.55], [hl, 0.55], [hl, 1.1], [hl - 0.4, 1.3], [hl - 0.55, 3.0], [hl - 2.3, 3.2]], -hw + 0.05, hw - 0.05, PART.BODY);
      m.box(-hl, hl - 2.4, -hw, hw, 0.8, 3.7, PART.ROOF);
      m.box(-hl + 0.1, hl - 2.4, -hw + 0.3, hw - 0.3, 0.45, 0.8, PART.DARK);
      m.box(hl - 0.62, hl - 0.38, -hw + 0.25, hw - 0.25, 1.55, 2.7, PART.GLASS);
      m.box(hl - 1.6, hl - 0.6, hw - 0.07, hw + 0.01, 1.55, 2.6, PART.GLASS); m.box(hl - 1.6, hl - 0.6, -hw - 0.01, -hw + 0.07, 1.55, 2.6, PART.GLASS);
      m.box(hl - 0.03, hl + 0.06, hw - 0.7, hw - 0.3, 0.9, 1.15, PART.HEAD); m.box(hl - 0.03, hl + 0.06, -hw + 0.3, -hw + 0.7, 0.9, 1.15, PART.HEAD);
      m.box(-hl - 0.06, -hl + 0.03, hw - 0.6, hw - 0.2, 0.9, 1.2, PART.TAIL); m.box(-hl - 0.06, -hl + 0.03, -hw + 0.2, -hw + 0.6, 0.9, 1.2, PART.TAIL);
      for (const x of [hl - 1.2, -hl + 1.6, -hl + 2.9]) { m.wheel(x, 0.5, 0.5, hw - 0.4, hw + 0.02); m.wheel(x, 0.5, 0.5, -hw - 0.02, -hw + 0.4); }
      return m.build();
    }
    const d = ROAD[type] || ROAD.sedan, L = d.L, W = d.W, H = d.H, hl = L / 2, hw = W / 2;
    m.prism([[-hl, 0.32], [hl, 0.32], [hl, 0.62], [hl - 0.25, 0.86], [-hl + 0.25, 0.86], [-hl, 0.7]], -hw, hw, PART.BODY);            // lower body
    const [cb, cf, rise] = d.cab;  // cabin: back, front (x of the base), and how far the windscreen and rear window slope
    m.prism([[cb, 0.86], [cf, 0.86], [cf - rise, H], [cb + rise * 0.7, H]], -hw + 0.1, hw - 0.1, PART.BODY);                           // roof and pillars
    m.prism([[cb + 0.12, 0.88], [cf - 0.12, 0.88], [cf - rise - 0.02, H - 0.08], [cb + rise * 0.7 + 0.05, H - 0.08]], -hw + 0.04, hw - 0.04, PART.GLASS);  // windows, slightly proud of the roof
    m.box(cb + rise * 0.7 + 0.08, cf - rise - 0.08, -hw + 0.18, hw - 0.18, H - 0.1, H + 0.02, PART.BODY);                               // roof panel hides the glass top
    m.box(hl - 0.03, hl + 0.06, hw - 0.55, hw - 0.2, 0.55, 0.75, PART.HEAD); m.box(hl - 0.03, hl + 0.06, -hw + 0.2, -hw + 0.55, 0.55, 0.75, PART.HEAD);
    m.box(-hl - 0.06, -hl + 0.03, hw - 0.5, hw - 0.15, 0.6, 0.8, PART.TAIL); m.box(-hl - 0.06, -hl + 0.03, -hw + 0.15, -hw + 0.5, 0.6, 0.8, PART.TAIL);
    m.box(hl - 0.04, hl + 0.08, -hw + 0.3, hw - 0.3, 0.32, 0.5, PART.DARK); m.box(-hl - 0.08, -hl + 0.04, -hw + 0.3, hw - 0.3, 0.32, 0.5, PART.DARK);
    for (const x of [hl - 0.95, -hl + 0.95]) { m.wheel(x, 0.32, 0.32, hw - 0.25, hw + 0.01); m.wheel(x, 0.32, 0.32, -hw - 0.01, -hw + 0.25); }
    return m.build();
  }
  const ROAD_TYPES = ["hatch", "sedan", "suv", "van", "truck"];
  const bellowsMesh = (len, wid, h) => new MeshBuilder().box(-len / 2, len / 2, -wid / 2, wid / 2, 0.95, h - 0.5, PART.DARK).build();

  // ---- instance batches: a fixed stride of 20 bytes, filled by JS every frame (dynamic) or once (static)
  //   f32: dx, dy (metres from the frame origin), fx, fy (unit forward vector east, north); u8: livery, alpha 0..255, flags, spare; u8: tint r, g, b, amount
  //   the tint moves the body part toward an arbitrary colour (amount 255 replaces it), so colours are not limited to the palette
  const STRIDE = 24;
  class InstanceBatch {
    constructor(capacity) { this.capacity = capacity; this.count = 0; this.buf = new ArrayBuffer(capacity * STRIDE); this.f32 = new Float32Array(this.buf); this.u8 = new Uint8Array(this.buf); }
    clear() { this.count = 0; }
    push(dx, dy, fx, fy, livery, alpha = 255, flags = 0, tr = 0, tg = 0, tb = 0, ta = 0) {
      if (this.count >= this.capacity) return false;
      const i = this.count++, o = i * 6;
      this.f32[o] = dx; this.f32[o + 1] = dy; this.f32[o + 2] = fx; this.f32[o + 3] = fy;
      const b = i * STRIDE + 16;
      this.u8[b] = livery; this.u8[b + 1] = alpha; this.u8[b + 2] = flags; this.u8[b + 3] = 0;
      this.u8[b + 4] = tr; this.u8[b + 5] = tg; this.u8[b + 6] = tb; this.u8[b + 7] = ta;
      return true;
    }
    view() { return new Uint8Array(this.buf, 0, this.count * STRIDE); }
  }
  // dots (far and middle zoom): dx, dy f32, rgba u8, size px f32, label cell f32  -> 24 bytes
  const DOT_STRIDE = 24;
  class DotBatch {
    constructor(capacity) { this.capacity = capacity; this.count = 0; this.buf = new ArrayBuffer(capacity * DOT_STRIDE); this.f32 = new Float32Array(this.buf); this.u8 = new Uint8Array(this.buf); }
    clear() { this.count = 0; }
    push(dx, dy, r, g, b, a, size, label = -1) {
      if (this.count >= this.capacity) return false;
      const i = this.count++, o = i * 6;
      this.f32[o] = dx; this.f32[o + 1] = dy; this.f32[o + 3] = size; this.f32[o + 4] = label;
      const q = i * DOT_STRIDE + 8;
      this.u8[q] = r; this.u8[q + 1] = g; this.u8[q + 2] = b; this.u8[q + 3] = a;
      return true;
    }
    view() { return new Uint8Array(this.buf, 0, this.count * DOT_STRIDE); }
  }

  // livery table: unique (skirt, body, stripe, roof) tuples -> small integer ids, uploaded as one uniform array
  class Palette {
    constructor(max = 32) { this.max = max; this.ids = new Map(); this.colors = new Float32Array(max * 4 * 3); }
    id(l) {
      const key = [l.skirt, l.body, l.stripe, l.roof].join("|");
      let i = this.ids.get(key);
      if (i !== undefined) return i;
      if (this.ids.size >= this.max) return 0;
      i = this.ids.size; this.ids.set(key, i);
      [l.skirt, l.body, l.stripe, l.roof].forEach((c, k) => this.colors.set(srgbToLinear(hex(c)), (i * 4 + k) * 3));
      return i;
    }
  }
  const hex = (c) => [1, 3, 5].map((i) => parseInt(c.slice(i, i + 2), 16) / 255);
  const srgbToLinear = (rgb) => rgb.map((v) => Math.pow(v, 2.2));

  // column-major 4x4: out = a * b
  function mul(a, b) {
    const o = new Float64Array(16);
    for (let c = 0; c < 4; c++) for (let r = 0; r < 4; r++) { let s = 0; for (let k = 0; k < 4; k++) s += a[k * 4 + r] * b[c * 4 + k]; o[c * 4 + r] = s; }
    return o;
  }
  // local metres (east, north, up) around a mercator origin -> mercator units
  function localToMercator(ox, oy, k) { return new Float64Array([k, 0, 0, 0, 0, -k, 0, 0, 0, 0, k, 0, ox, oy, 0, 1]); }

  // ================================================================ GL
  const VS_MESH = `#version 300 es
precision highp float;
uniform mat4 u_matrix; uniform vec3 u_sun; uniform vec3 u_sunColor; uniform vec3 u_ambient; uniform float u_night; uniform vec3 u_bg;
uniform vec3 u_liv[128];
in vec3 a_pos; in vec3 a_nrm; in float a_part;
in vec2 i_pos; in vec2 i_dir; in vec4 i_meta; in vec4 i_tint;
out vec3 v_col;
void main() {
  vec2 f = i_dir, l = vec2(-f.y, f.x);
  vec2 en = f * a_pos.x + l * a_pos.y;
  gl_Position = u_matrix * vec4(vec3(i_pos + en, a_pos.z), 1.0);
  vec3 n = normalize(vec3(f * a_nrm.x + l * a_nrm.y, a_nrm.z));
  int liv = int(i_meta.x + 0.5), part = int(a_part + 0.5);
  vec3 base = part < 4 ? u_liv[liv * 4 + part] : part == 4 ? vec3(0.012, 0.02, 0.035) : part == 5 ? vec3(0.015, 0.017, 0.02) : part == 6 ? vec3(0.9, 0.85, 0.6) : vec3(0.7, 0.02, 0.02);
  if (part == 1) base = mix(base, pow(i_tint.rgb, vec3(2.2)), i_tint.a);
  float diff = max(dot(n, u_sun), 0.0), hemi = 0.55 + 0.45 * n.z;
  vec3 lit = base * (u_ambient * hemi + u_sunColor * diff);
  vec3 glow = part == 6 ? vec3(1.0, 0.92, 0.7) * 2.2 : part == 7 ? vec3(1.0, 0.1, 0.05) * 1.6 : part == 4 ? vec3(1.0, 0.8, 0.45) * 0.22 : vec3(0.0);
  vec3 c = lit + glow * u_night;
  float a = i_meta.y / 255.0;
  v_col = mix(u_bg, c, a);
}`;
  const FS_MESH = `#version 300 es
precision mediump float;
in vec3 v_col; out vec4 o;
void main() { o = vec4(pow(v_col, vec3(1.0 / 2.2)), 1.0); }`;
  // light cones: additive, no lighting, intensity comes from the vertex (a_part), colour and strength from the instance
  const VS_BEAM = `#version 300 es
precision highp float;
uniform mat4 u_matrix;
in vec3 a_pos; in vec3 a_nrm; in float a_part;
in vec2 i_pos; in vec2 i_dir; in vec4 i_meta; in vec4 i_tint;
out vec3 v_col;
void main() {
  vec2 f = i_dir, l = vec2(-f.y, f.x);
  gl_Position = u_matrix * vec4(vec3(i_pos + f * a_pos.x + l * a_pos.y, a_pos.z), 1.0);
  v_col = i_tint.rgb * (i_meta.y / 255.0) * a_part;
}`;
  const FS_BEAM = `#version 300 es
precision mediump float;
uniform float u_night;
in vec3 v_col; out vec4 o;
void main() { o = vec4(v_col * u_night, 1.0); }`;
  const VS_DOT = `#version 300 es
precision highp float;
uniform mat4 u_matrix; uniform float u_dpr;
in vec2 i_pos; in vec4 i_col; in float i_size;
out vec4 v_col; out float v_soft;
void main() { gl_Position = u_matrix * vec4(i_pos, 0.0, 1.0); gl_PointSize = abs(i_size) * u_dpr; v_col = i_col; v_soft = i_size < 0.0 ? 1.0 : 0.0; }`;
  const FS_DOT = `#version 300 es
precision mediump float;
in vec4 v_col; in float v_soft; out vec4 o;
void main() {
  float d = length(gl_PointCoord - 0.5) * 2.0;
  if (d > 1.0) discard;
  if (v_soft > 0.5) { float f = 1.0 - d; o = vec4(v_col.rgb, v_col.a * f * f); return; }  // a negative size is a soft glow instead of a dot
  float edge = smoothstep(1.0, 0.9, d);
  float ring = smoothstep(0.66, 0.74, d);
  o = vec4(mix(v_col.rgb, vec3(1.0), ring), v_col.a * edge);
}`;
  const VS_LABEL = `#version 300 es
precision highp float;
uniform mat4 u_matrix; uniform vec2 u_viewport; uniform vec2 u_atlas; uniform vec2 u_cell; uniform float u_dpr;
in vec2 i_pos; in float i_cell; in float i_w;
out vec2 v_uv;
void main() {
  vec2 c = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));
  vec4 p = u_matrix * vec4(i_pos, 0.0, 1.0);
  vec2 px = (c * vec2(i_w, u_cell.y) - vec2(i_w * 0.5, u_cell.y + 12.0)) * u_dpr;
  p.xy += px * vec2(2.0, -2.0) / u_viewport * p.w;
  gl_Position = p;
  float col = mod(i_cell, u_atlas.x), row = floor(i_cell / u_atlas.x);
  v_uv = (vec2(col, row) * u_cell + vec2(c.x * i_w, (1.0 - c.y) * u_cell.y)) / (u_atlas * u_cell);
}`;
  const FS_LABEL = `#version 300 es
precision mediump float;
uniform sampler2D u_tex; in vec2 v_uv; out vec4 o;
void main() { o = texture(u_tex, v_uv); if (o.a < 0.02) discard; }`;

  function program(gl, vs, fs) {
    const sh = (type, src) => { const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s)); return s; };
    const p = gl.createProgram();
    ["a_pos", "a_nrm", "a_part", "i_pos", "i_dir", "i_meta", "i_tint"].forEach((n, i) => gl.bindAttribLocation(p, i, n));  // the mesh and beam programs share their vertex arrays
    gl.attachShader(p, sh(gl.VERTEX_SHADER, vs)); gl.attachShader(p, sh(gl.FRAGMENT_SHADER, fs)); gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
    return p;
  }

  // text atlas for line numbers: cells of 64x20 px
  class Labels {
    constructor() { this.cols = 16; this.rows = 16; this.cw = 64; this.ch = 20; this.map = new Map(); this.canvas = document.createElement("canvas"); this.canvas.width = this.cols * this.cw; this.canvas.height = this.rows * this.ch; this.ctx = this.canvas.getContext("2d"); this.dirty = true; this.ink = "#111"; this.halo = "#fff"; }
    theme(ink, halo) { if (ink !== this.ink || halo !== this.halo) { this.ink = ink; this.halo = halo; this.map.clear(); this.ctx.clearRect(0, 0, this.canvas.width, this.canvas.height); this.dirty = true; } }
    cell(text) {
      let c = this.map.get(text);
      if (c) return c;
      if (this.map.size >= this.cols * this.rows) return null;
      const i = this.map.size, x = (i % this.cols) * this.cw, y = Math.floor(i / this.cols) * this.ch, g = this.ctx;
      g.font = "700 13px system-ui, sans-serif"; g.textBaseline = "middle"; g.textAlign = "center";
      const w = Math.min(this.cw - 2, Math.ceil(g.measureText(text).width) + 6);
      g.lineJoin = "round"; g.lineWidth = 4; g.strokeStyle = this.halo; g.strokeText(text, x + w / 2, y + this.ch / 2 + 1); g.fillStyle = this.ink; g.fillText(text, x + w / 2, y + this.ch / 2 + 1);
      c = { i, w }; this.map.set(text, c); this.dirty = true;
      return c;
    }
  }

  // ---- the layer
  function createLayer(opts = {}) {
    const S = {
      id: opts.id || "scene3d", map: null, gl: null, meshes: new Map(), batches: new Map(), palette: new Palette(), labels: new Labels(),
      frame: { ox: 0, oy: 0, k: 1, zoom: 10, dpr: 1 }, light: { sun: [0, 0, 1], sunColor: [1, 1, 1], ambient: [0.5, 0.5, 0.5], night: 0, bg: [0.9, 0.9, 0.9] },
      dots: new DotBatch(8192), labelInst: new Float32Array(2048 * 4), labelCount: 0, showDots: true, showMeshes: true, showLabels: true, stats: { draws: 0, triangles: 0, instances: 0 },
    };
    S.registerMesh = (name, mesh) => { S.meshes.set(name, { mesh, gpu: null }); };
    S.addBatch = (name, mesh, capacity, opts) => { const b = new InstanceBatch(capacity); S.batches.set(name, { mesh, batch: b, gpu: null, beam: !!(opts && opts.beam) }); return b; };
    S.setFrame = (f) => Object.assign(S.frame, f);
    S.setLight = (l) => Object.assign(S.light, l);

    // one VAO per batch: the mesh buffers plus that batch's own instance buffer
    function buildGpu(gl, b) {
      const attr = (p, n) => gl.getAttribLocation(p, n);
      if (b.gpu) { gl.deleteVertexArray(b.gpu.vao); gl.deleteBuffer(b.gpu.vb); gl.deleteBuffer(b.gpu.ib); gl.deleteBuffer(b.gpu.inst); b.gpu = null; }
      const mesh = S.meshes.get(b.mesh).mesh, vao = gl.createVertexArray(), vb = gl.createBuffer(), ib = gl.createBuffer(), inst = gl.createBuffer();
      gl.bindVertexArray(vao);
      gl.bindBuffer(gl.ARRAY_BUFFER, vb); gl.bufferData(gl.ARRAY_BUFFER, mesh.vertex, gl.STATIC_DRAW);
      for (const [n, size, off] of [["a_pos", 3, 0], ["a_nrm", 3, 12], ["a_part", 1, 24]]) { const l = attr(S.progMesh, n); gl.enableVertexAttribArray(l); gl.vertexAttribPointer(l, size, gl.FLOAT, false, 28, off); }
      gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, ib); gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, mesh.index, gl.STATIC_DRAW);
      gl.bindBuffer(gl.ARRAY_BUFFER, inst); gl.bufferData(gl.ARRAY_BUFFER, b.batch.capacity * STRIDE, gl.DYNAMIC_DRAW);
      for (const [n, size, type, norm, off] of [["i_pos", 2, gl.FLOAT, false, 0], ["i_dir", 2, gl.FLOAT, false, 8], ["i_meta", 4, gl.UNSIGNED_BYTE, false, 16], ["i_tint", 4, gl.UNSIGNED_BYTE, true, 20]]) {
        const l = attr(S.progMesh, n); gl.enableVertexAttribArray(l); gl.vertexAttribPointer(l, size, type, norm, STRIDE, off); gl.vertexAttribDivisor(l, 1);
      }
      gl.bindVertexArray(null);
      b.gpu = { vao, vb, ib, inst, triangles: mesh.triangles };
    }
    // a mesh whose geometry changes at runtime (world details streamed from data); it has one instance, so its vertices carry the placement
    S.setDynamicMesh = (name, mesh) => {
      S.meshes.set(name, { mesh, gpu: null });
      let b = S.batches.get(name);
      if (!b) { b = { mesh: name, batch: new InstanceBatch(1), gpu: null }; S.batches.set(name, b); }
      b.pending = true;  // uploaded inside render(), where MapLibre expects GL state to change
      return b.batch;
    };
    S.dropMesh = (name) => {
      const b = S.batches.get(name);
      if (b) b.drop = true;
    };
    function initGL(gl) {
      S.gl = gl;
      S.progMesh = program(gl, VS_MESH, FS_MESH); S.progDot = program(gl, VS_DOT, FS_DOT); S.progBeam = program(gl, VS_BEAM, FS_BEAM); S.uBeam = { u_matrix: gl.getUniformLocation(S.progBeam, "u_matrix"), u_night: gl.getUniformLocation(S.progBeam, "u_night") }; S.progLabel = program(gl, VS_LABEL, FS_LABEL);
      S.uMesh = Object.fromEntries(["u_matrix", "u_sun", "u_sunColor", "u_ambient", "u_night", "u_bg", "u_liv"].map((n) => [n, gl.getUniformLocation(S.progMesh, n)]));
      S.uDot = Object.fromEntries(["u_matrix", "u_dpr"].map((n) => [n, gl.getUniformLocation(S.progDot, n)]));
      S.uLabel = Object.fromEntries(["u_matrix", "u_viewport", "u_atlas", "u_cell", "u_dpr", "u_tex"].map((n) => [n, gl.getUniformLocation(S.progLabel, n)]));
      const attr = (p, n) => gl.getAttribLocation(p, n);
      // meshes: one VAO per batch (mesh buffers + that batch's instance buffer)
      for (const b of S.batches.values()) buildGpu(gl, b);
      // dots
      S.dotVao = gl.createVertexArray(); S.dotBuf = gl.createBuffer();
      gl.bindVertexArray(S.dotVao); gl.bindBuffer(gl.ARRAY_BUFFER, S.dotBuf); gl.bufferData(gl.ARRAY_BUFFER, S.dots.capacity * DOT_STRIDE, gl.DYNAMIC_DRAW);
      for (const [n, size, type, norm, off] of [["i_pos", 2, gl.FLOAT, false, 0], ["i_col", 4, gl.UNSIGNED_BYTE, true, 8], ["i_size", 1, gl.FLOAT, false, 12]]) {
        const l = attr(S.progDot, n); gl.enableVertexAttribArray(l); gl.vertexAttribPointer(l, size, type, norm, DOT_STRIDE, off); gl.vertexAttribDivisor(l, 1);
      }
      gl.bindVertexArray(null);
      // labels
      S.labVao = gl.createVertexArray(); S.labBuf = gl.createBuffer(); S.labTex = gl.createTexture();
      gl.bindVertexArray(S.labVao); gl.bindBuffer(gl.ARRAY_BUFFER, S.labBuf); gl.bufferData(gl.ARRAY_BUFFER, S.labelInst.byteLength, gl.DYNAMIC_DRAW);
      for (const [n, size, off] of [["i_pos", 2, 0], ["i_cell", 1, 8], ["i_w", 1, 12]]) { const l = attr(S.progLabel, n); gl.enableVertexAttribArray(l); gl.vertexAttribPointer(l, size, gl.FLOAT, false, 16, off); gl.vertexAttribDivisor(l, 1); }
      gl.bindVertexArray(null);
      gl.bindTexture(gl.TEXTURE_2D, S.labTex);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      S.labels.dirty = true;
    }

    S.addLabel = (text, dx, dy) => {
      const c = S.labels.cell(text);
      if (!c || S.labelCount >= 2048) return;
      const o = S.labelCount++ * 4;
      S.labelInst[o] = dx; S.labelInst[o + 1] = dy; S.labelInst[o + 2] = c.i; S.labelInst[o + 3] = c.w;
    };
    S.beginFrame = () => { for (const b of S.batches.values()) b.batch.clear(); S.dots.clear(); S.labelCount = 0; };

    const layer = {
      id: S.id, type: "custom", renderingMode: "3d",
      onAdd(map, gl) { S.map = map; initGL(gl); },
      onRemove(map, gl) { S.gl = null; },
      render(gl, args) {
        if (!S.gl) return;
        const main = args.defaultProjectionData?.mainMatrix || args.modelViewProjectionMatrix;
        if (!main) return;
        const fr = S.frame, M = mul(main, localToMercator(fr.ox, fr.oy, fr.k)), m32 = new Float32Array(M);
        let draws = 0, tris = 0, inst = 0;
        for (const [name, b] of S.batches) {
          if (b.drop) { if (b.gpu) { gl.deleteVertexArray(b.gpu.vao); gl.deleteBuffer(b.gpu.vb); gl.deleteBuffer(b.gpu.ib); gl.deleteBuffer(b.gpu.inst); } S.batches.delete(name); S.meshes.delete(name); }
          else if (b.pending) { b.pending = false; buildGpu(gl, b); }
        }
        if (S.showMeshes && fr.zoom >= S.meshZoom) {
          gl.useProgram(S.progMesh);
          const L = S.light;
          gl.uniformMatrix4fv(S.uMesh.u_matrix, false, m32); gl.uniform3fv(S.uMesh.u_sun, L.sun); gl.uniform3fv(S.uMesh.u_sunColor, L.sunColor); gl.uniform3fv(S.uMesh.u_ambient, L.ambient);
          gl.uniform1f(S.uMesh.u_night, L.night); gl.uniform3fv(S.uMesh.u_bg, L.bg); gl.uniform3fv(S.uMesh.u_liv, S.palette.colors);
          gl.enable(gl.CULL_FACE); gl.cullFace(gl.BACK); gl.frontFace(gl.CCW);
          for (const b of S.batches.values()) {
            if (b.beam || !b.batch.count || !b.gpu) continue;
            gl.bindVertexArray(b.gpu.vao);
            gl.bindBuffer(gl.ARRAY_BUFFER, b.gpu.inst); gl.bufferSubData(gl.ARRAY_BUFFER, 0, b.batch.view());
            gl.drawElementsInstanced(gl.TRIANGLES, b.gpu.triangles * 3, gl.UNSIGNED_SHORT, 0, b.batch.count);
            draws++; tris += b.gpu.triangles * b.batch.count; inst += b.batch.count;
          }
          gl.disable(gl.CULL_FACE);
          if (L.night > 0.03) {  // light cones over the lit scene: additive, hidden by buildings but not hiding anything behind them
            gl.useProgram(S.progBeam);
            gl.uniformMatrix4fv(S.uBeam.u_matrix, false, m32); gl.uniform1f(S.uBeam.u_night, Math.min(1, L.night));
            gl.enable(gl.BLEND); gl.blendFunc(gl.ONE, gl.ONE); gl.depthMask(false);
            for (const b of S.batches.values()) {
              if (!b.beam || !b.batch.count || !b.gpu) continue;
              gl.bindVertexArray(b.gpu.vao);
              gl.bindBuffer(gl.ARRAY_BUFFER, b.gpu.inst); gl.bufferSubData(gl.ARRAY_BUFFER, 0, b.batch.view());
              gl.drawElementsInstanced(gl.TRIANGLES, b.gpu.triangles * 3, gl.UNSIGNED_SHORT, 0, b.batch.count);
              draws++; inst += b.batch.count;
            }
            gl.depthMask(true); gl.disable(gl.BLEND);
          }
        }
        if (S.showDots && S.dots.count) {
          gl.useProgram(S.progDot); gl.disable(gl.DEPTH_TEST); gl.enable(gl.BLEND); gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
          gl.uniformMatrix4fv(S.uDot.u_matrix, false, m32); gl.uniform1f(S.uDot.u_dpr, fr.dpr);
          gl.bindVertexArray(S.dotVao); gl.bindBuffer(gl.ARRAY_BUFFER, S.dotBuf); gl.bufferSubData(gl.ARRAY_BUFFER, 0, S.dots.view());
          gl.drawArraysInstanced(gl.POINTS, 0, 1, S.dots.count); draws++;
        }
        if (S.showLabels && S.labelCount) {
          gl.useProgram(S.progLabel); gl.disable(gl.DEPTH_TEST); gl.enable(gl.BLEND); gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
          gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, S.labTex);
          if (S.labels.dirty) { gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, true); gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, S.labels.canvas); S.labels.dirty = false; }
          const cv = S.map.getCanvas();
          gl.uniformMatrix4fv(S.uLabel.u_matrix, false, m32); gl.uniform2f(S.uLabel.u_viewport, cv.width, cv.height); gl.uniform2f(S.uLabel.u_atlas, S.labels.cols, S.labels.rows);
          gl.uniform2f(S.uLabel.u_cell, S.labels.cw, S.labels.ch); gl.uniform1f(S.uLabel.u_dpr, fr.dpr); gl.uniform1i(S.uLabel.u_tex, 0);
          gl.bindVertexArray(S.labVao); gl.bindBuffer(gl.ARRAY_BUFFER, S.labBuf); gl.bufferSubData(gl.ARRAY_BUFFER, 0, S.labelInst.subarray(0, S.labelCount * 4));
          gl.drawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, S.labelCount); draws++;
        }
        gl.bindVertexArray(null); gl.disable(gl.BLEND); gl.enable(gl.DEPTH_TEST);
        S.stats = { draws, triangles: tris, instances: inst, dots: S.dots.count };
      },
    };
    S.layer = layer; S.meshZoom = 15;
    return S;
  }

  window.Scene3D = { PART, MeshBuilder, carMesh, bellowsMesh, roadVehicleMesh, ROAD_TYPES, InstanceBatch, DotBatch, Palette, STRIDE, DOT_STRIDE, mul, localToMercator, createLayer };
})();
