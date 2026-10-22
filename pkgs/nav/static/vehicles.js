"use strict";
// Live vehicles: heatmap far out, GPU dots in the middle, painted instanced 3D models up close (see scene3d.js).
// Positions arrive every few seconds, the simulation runs every frame. Each vehicle is dead-reckoned along its trip shape with a speed controller that
//  - brakes for simulated red lights (signal nodes from OSM) and holds until green,
//  - docks at the platform when the feed says it is stopped at a stop,
//  - steers back toward the reported position: speeds up when behind, eases off when ahead, never reverses,
//  - and for a large mismatch glides over a short distance, or fades out, jumps and fades in.
// The per-frame path does not allocate: shapes keep mercator coordinates and unit directions per segment, signals keep cycle tables and a cursor.
(() => {
  const A = window.App;
  const { api, h, icon, $, store } = A;
  const T = () => performance.now() / 1000;

  const VMAX = { RAIL: 45, TRAM: 20, BUS: 22, TROLLEYBUS: 20, DEFAULT: 22 };
  const ACC = { RAIL: 0.8, TRAM: 1.0, BUS: 1.1, TROLLEYBUS: 1.1, DEFAULT: 1.1 };
  const FALLBACK = { RAIL: "#b3311f", BUS: "#1c5fb0", TRAM: "#a35a00", TROLLEYBUS: "#4d7c0f" };
  const EXTRAP_MAX = 40, STALE_DIM = 240, STALE_DROP = 900, K_PULL = 0.3, RESYNC_M = 350, TELEPORT_M = 600, LIGHT_SLACK_M = 110;
  const Z_DOTS = 10.4, Z_HEAT_OUT = 11.8, Z_MESH = 15, Z_LABEL = 13.2;
  const TAU = Math.PI * 2;

  const V = new Map();        // vehicle id -> state
  const SHAPES = new Map();   // trip id -> shape info | "pending" | { fail }
  let map = null, scene = null, on = store.get("veh", true), threeD = store.get("3d", true), hi = new Set();
  let ambient = false, traffic = null;
  let ctx = false, force = false, followId = null, followBar = null, cam = null, lastTick = 0, nowSec = 0;
  const pose = new Float64Array(4);  // scratch: mx, my, ux, uy

  // ---- mercator helpers
  const mercX = (lon) => (lon + 180) / 360;
  const mercY = (lat) => 0.5 - Math.log(Math.tan(Math.PI / 4 + (lat * Math.PI) / 360)) / TAU;
  const lonOf = (mx) => mx * 360 - 180;
  const latOf = (my) => (Math.atan(Math.sinh(Math.PI * (1 - 2 * my))) * 180) / Math.PI;

  // ---- traffic light model: deterministic per junction (cycle and phase come from a hash of its position along the trip)
  function hash(n) { n = Math.imul(n ^ (n >>> 16), 0x45d9f3b); n = Math.imul(n ^ (n >>> 16), 0x45d9f3b); return ((n ^ (n >>> 16)) >>> 0) / 4294967296; }
  let wall = 0, wallFor = -1;
  const redAt = (sh, j) => ((wall + sh.sigPhase[j]) % sh.sigCycle[j]) < sh.sigCycle[j] * 0.42;

  // ---- shapes: mercator points, metres along the line, unit direction (east, north) per segment
  function buildShape(info) {
    const pts = A.decode(info.points);
    if (pts.length < 2) return null;
    const n = pts.length, k = Math.cos((pts[0][1] * Math.PI) / 180) * 111320, ky = 110540;
    const X = new Float64Array(n), Y = new Float64Array(n), MX = new Float64Array(n), MY = new Float64Array(n), cum = new Float64Array(n), UX = new Float32Array(n), UY = new Float32Array(n);
    for (let i = 0; i < n; i++) { X[i] = pts[i][0] * k; Y[i] = pts[i][1] * ky; MX[i] = mercX(pts[i][0]); MY[i] = mercY(pts[i][1]); }
    for (let i = 1; i < n; i++) cum[i] = cum[i - 1] + Math.hypot(X[i] - X[i - 1], Y[i] - Y[i - 1]);
    for (let i = 0; i < n - 1; i++) { const dx = X[i + 1] - X[i], dy = Y[i + 1] - Y[i], l = Math.hypot(dx, dy) || 1; UX[i] = dx / l; UY[i] = dy / l; }
    UX[n - 1] = UX[n - 2]; UY[n - 1] = UY[n - 2];
    const sigs = info.sig || [], sigCycle = new Float32Array(sigs.length), sigPhase = new Float32Array(sigs.length), trip = info.trip || "";
    for (let j = 0; j < sigs.length; j++) { const id = Math.round(sigs[j]) * 31 + trip.length; sigCycle[j] = 70 + hash(id) * 50; sigPhase[j] = hash(id + 7) * sigCycle[j]; }
    return { pts, X, Y, MX, MY, cum, UX, UY, k, ky, length: cum[n - 1], stops: info.stops || [], sig: Float64Array.from(sigs), sigCycle, sigPhase };
  }
  function rayFrom(lon, lat, headingDeg) {
    const r = (headingDeg * Math.PI) / 180, k = Math.cos((lat * Math.PI) / 180) * 111320, ky = 110540;
    const far = [lon + (Math.sin(r) * 6000) / k, lat + (Math.cos(r) * 6000) / ky];
    const X = Float64Array.of(lon * k, far[0] * k), Y = Float64Array.of(lat * ky, far[1] * ky), len = Math.hypot(X[1] - X[0], Y[1] - Y[0]);
    return { pts: [[lon, lat], far], X, Y, MX: Float64Array.of(mercX(lon), mercX(far[0])), MY: Float64Array.of(mercY(lat), mercY(far[1])), cum: Float64Array.of(0, len), UX: Float32Array.of(Math.sin(r), Math.sin(r)), UY: Float32Array.of(Math.cos(r), Math.cos(r)),
             k, ky, length: len, stops: [], sig: new Float64Array(0), sigCycle: new Float32Array(0), sigPhase: new Float32Array(0), ray: true };
  }
  function locate(sh, s) {  // segment index containing distance s
    let a = 0, b = sh.cum.length - 1;
    while (b - a > 1) { const m = (a + b) >> 1; if (sh.cum[m] <= s) a = m; else b = m; }
    return a;
  }
  function project(sh, lon, lat, near, win = 500) {
    const x = lon * sh.k, y = lat * sh.ky;
    const scan = (lo, hi2) => {
      let bd = Infinity, bs = 0;
      for (let i = lo; i <= hi2; i++) {
        const dx = sh.X[i + 1] - sh.X[i], dy = sh.Y[i + 1] - sh.Y[i], l2 = dx * dx + dy * dy;
        const t = l2 ? Math.max(0, Math.min(1, ((x - sh.X[i]) * dx + (y - sh.Y[i]) * dy) / l2)) : 0;
        const d = Math.hypot(x - (sh.X[i] + t * dx), y - (sh.Y[i] + t * dy));
        if (d < bd) { bd = d; bs = sh.cum[i] + t * Math.sqrt(l2); }
      }
      return { d: bd, s: bs };
    };
    const last = sh.X.length - 2;
    let best = near != null ? scan(Math.max(0, locate(sh, near - win)), Math.min(last, locate(sh, near + win))) : null;
    if (!best || best.d > 150) best = scan(0, last);  // lost the thread: search everything once
    return best;
  }
  // writes mercator position and unit direction at distance s into `pose`
  function poseAt(sh, s) {
    if (s < 0) s = 0; else if (s > sh.length) s = sh.length;
    const i = Math.min(locate(sh, s), sh.X.length - 2), seg = sh.cum[i + 1] - sh.cum[i] || 1, t = (s - sh.cum[i]) / seg;
    pose[0] = sh.MX[i] + (sh.MX[i + 1] - sh.MX[i]) * t; pose[1] = sh.MY[i] + (sh.MY[i + 1] - sh.MY[i]) * t; pose[2] = sh.UX[i]; pose[3] = sh.UY[i];
  }

  // ---- vehicle state
  function newVehicle(r, now) {
    return { id: r.id, s: 0, vel: 0, sRep: 0, vRep: 0, tRep: -1e9, shape: null, ray: null, hx: 0, hy: 1, fade: 0, lon: r.lon, lat: r.lat, seen: now, model: null, ns: 0, seg: 0, seg0: 0, liv: 0, rgb: [68, 80, 92], mx: mercX(r.lon), my: mercY(r.lat) };
  }
  function ingest(list, serverNow) {
    const now = T();
    for (const r of list) {
      let v = V.get(r.id);
      const ageAtArrival = Math.max(0, Math.min(120, serverNow - (r.ts || serverNow)));
      const tRep = now - ageAtArrival;
      if (!v) { v = newVehicle(r, now); V.set(r.id, v); }
      if (tRep <= v.tRep + 0.2 && (v.shape || v.ray)) { v.seen = now; continue; }  // the same report as before
      const modelKey = r.mode + "|" + r.ag;
      if (v.modelKey !== modelKey) { v.modelKey = modelKey; v.model = null; }
      Object.assign(v, { line: r.line, mode: r.mode, ag: r.ag, to: r.to, trip: r.trip, st: r.st, sn: r.sn, seen: now });
      v.color = A.providerOf(r.ag)?.color || FALLBACK[r.mode] || "#44505c";
      v.rgb = [1, 3, 5].map((i) => parseInt(v.color.slice(i, i + 2), 16));
      const prev = { lon: v.lon, lat: v.lat, had: v.tRep > -1e8 };
      v.lon = r.lon; v.lat = r.lat;
      const sh = v.shape;
      if (!sh) {
        // no shape yet: a ray along the reported or observed heading keeps it moving until the real shape arrives
        let hd = r.hd;
        if (hd == null && prev.had && Math.abs(prev.lon - r.lon) + Math.abs(prev.lat - r.lat) > 2e-5) hd = (Math.atan2((r.lon - prev.lon) * 0.64, r.lat - prev.lat) * 180) / Math.PI;
        if (hd != null) v.rayHd = (hd + 360) % 360;
        v.vRep = r.sp != null ? r.sp : v.vRep || 0;
        v.tRep = tRep;
        v.mx = mercX(r.lon); v.my = mercY(r.lat);
        if (v.rayHd != null) { v.ray = rayFrom(r.lon, r.lat, v.rayHd); v.s = 0; v.sRep = 0; v.seg = 0; v.seg0 = 0; }
        continue;
      }
      const p = project(sh, r.lon, r.lat, v.sRep || null);
      if (!p) continue;
      const first = v.tRep < -1e8;
      if (!first && p.s < v.sRep - 60) { v.tRep = tRep; continue; }  // jitter or a looped route: keep the last good position
      const dt = tRep - v.tRep;
      let vr = r.sp != null ? r.sp : !first && dt > 1 ? (p.s - v.sRep) / dt : v.vRep;
      vr = Math.max(0, Math.min(VMAX[v.mode] || 22, vr));
      v.vRep = first || r.sp != null ? (r.sp ?? 6) : 0.5 * v.vRep + 0.5 * vr;  // a reported speed is taken as is, a derived one is smoothed
      if (r.sp == null && !first && dt > 1 && Math.abs(p.s - v.sRep) < 2) v.vRep = 0;  // same place twice: it is standing
      v.sRep = first ? p.s : Math.max(p.s, v.sRep);
      v.tRep = tRep;
      if (first) { v.s = v.sRep + v.vRep * Math.min(ageAtArrival, EXTRAP_MAX); v.vel = v.vRep; v.ns = 0; }
    }
    for (const [id, v] of V) if (!v.sched && now - v.seen > STALE_DROP) V.delete(id);
  }
  function attachShape(v, info) {
    const sh = buildShape(info);
    if (!sh) return;
    if (v.sched) { v.shape = sh; v.ray = null; v.seg = 0; v.seg0 = 0; return; }
    // continuity: project where the vehicle is drawn now onto the real shape
    let cur = { lon: v.lon, lat: v.lat };
    if (v.ray) { poseAt(v.ray, v.s); cur = { lon: lonOf(pose[0]), lat: latOf(pose[1]) }; }
    const pc = project(sh, cur.lon, cur.lat, null), pr = project(sh, v.lon, v.lat, null);
    v.shape = sh; v.ray = null; v.ns = 0; v.seg = 0; v.seg0 = 0;
    if (pr) { v.sRep = pr.s; v.s = pc ? pc.s : pr.s; }
  }

  // per-dt coefficients, recomputed only when dt changes (it is constant from frame to frame)
  let coefDt = -1, kHead = 0, kFadeOut = 0, kGlide = 0, kFadeIn = 0;
  function coefficients(dt) { coefDt = dt; kHead = 1 - Math.exp(-dt / 0.22); kGlide = 1 - Math.exp(-dt / 1.1); }
  // segment cursor: advance or retreat from where this vehicle was last frame instead of searching the whole shape
  function cursor(sh, v, key, s) {
    let i = v[key] | 0;
    const last = sh.X.length - 2;
    if (i > last) i = last;
    while (i < last && sh.cum[i + 1] <= s) i++;
    while (i > 0 && sh.cum[i] > s) i--;
    v[key] = i;
    return i;
  }
  // ---- timetable vehicles (diorama): positions come from the schedule, at the shown time of day
  const simLive = () => !window.Daylight?.enabled || (window.Daylight.mode === "live" && !window.Daylight.day);
  const simEpoch = () => (simLive() ? Date.now() / 1000 : window.Daylight.time().getTime() / 1000);
  function stepSched(v, dt) {
    const sh = v.shape;
    if (!sh) return 0;
    const t = simEpoch() - v.sched.sd, p = window.Sched.position(v.sched.st, t, v.sched.hint);
    v.s = Math.min(sh.length, p.s); v.vel = p.v;
    const ia = cursor(sh, v, "seg", Math.min(sh.length, v.s + 6));
    v.hx = sh.UX[ia]; v.hy = sh.UY[ia];
    const first = v.sched.st[0][2], last = v.sched.st[v.sched.st.length - 1][1];
    return p.phase === "before" ? (first - t < 45 ? 1 : 0) : p.phase === "after" ? Math.max(0, 1 - (t - last) / 20) : 1;
  }
  // advances one vehicle by dt seconds; returns its draw alpha
  function step(v, dt, now) {
    if (v.sched) return stepSched(v, dt);
    const sh = v.shape || v.ray;
    if (!sh) return 0.7;
    if (dt !== coefDt) coefficients(dt);
    if (now !== wallFor) { wallFor = now; wall = Date.now() / 1000; }
    const age = now - v.tRep, stale = age > STALE_DIM, vmax = VMAX[v.mode] || 22;
    let sTarget = v.sRep + v.vRep * Math.min(age, EXTRAP_MAX), vDes = stale ? 0 : v.vRep;
    if (v.st === "STOPPED_AT" && v.sn && v.shape) {  // docked: sit at the stop the feed names
      const stops = v.shape.stops;
      for (let i = 0; i < stops.length; i++) { const x = stops[i]; if (x.n === v.sn && Math.abs(x.a - v.sRep) < 80) { sTarget = x.a; vDes = 0; break; } }
    }
    if (stale) sTarget = v.s;  // no news for a long time: come to rest where we are instead of coasting on an old guess
    const e = sTarget - v.s;
    let vCmd = Math.max(0, Math.min(vDes + K_PULL * e, Math.max(vDes * 1.7, vDes + 6), vmax));
    let hard = false;
    if (Math.abs(e) > TELEPORT_M) {  // far apart: fade out, jump, fade in
      v.fade = Math.min(1, v.fade + dt * 5);
      if (v.fade >= 1) { v.s = Math.max(0, Math.min(sh.length, sTarget)); v.vel = vDes; v.ns = 0; }
    } else if (e > RESYNC_M) { v.s += Math.min(e * kGlide, 90 * dt); v.fade = Math.min(0.4, v.fade + dt); }  // behind by a few hundred metres: a quick glide
    else v.fade = Math.max(0, v.fade - dt * 2.5);
    // simulated lights, only while we are not already behind reality, so a stop never becomes a permanent lag
    const sig = sh.sig;
    if (sig.length && e < LIGHT_SLACK_M && vDes > 2 && !stale) {
      let j = v.ns;
      while (j > 0 && sig[j - 1] > v.s - 2) j--;
      while (j < sig.length && sig[j] < v.s - 2) j++;
      v.ns = j;
      if (j < sig.length) {
        const d = sig[j] - v.s;
        if (d <= 90 && redAt(sh, j)) { const cap = Math.sqrt(2 * 1.6 * Math.max(0, d - 4)); vCmd = Math.min(vCmd, cap); hard = d < 40 && v.vel > 1.5 * cap; }
      }
    }
    v.vel += Math.max(-(hard ? 3.2 : 1.4) * dt, Math.min((ACC[v.mode] || 1.1) * dt, vCmd - v.vel));
    v.s = Math.min(sh.length, Math.max(v.s, v.s + v.vel * dt));
    const ia = cursor(sh, v, "seg", Math.min(sh.length, v.s + 6));  // direction a little ahead, so the nose turns into bends
    v.hx += (sh.UX[ia] - v.hx) * kHead; v.hy += (sh.UY[ia] - v.hy) * kHead;
    const l = Math.sqrt(v.hx * v.hx + v.hy * v.hy) || 1; v.hx /= l; v.hy /= l;
    return (stale ? 0.45 : 1) * (1 - 0.9 * v.fade);
  }

  // ---- models: a fleet variant per vehicle (see fleet.js), cars laid out end to end; articulated cars sit on the track at their own distance
  const modelFor = (v) => window.Fleet.variantFor(v.ag, v.mode, v.id || "x");
  function livery(v) {
    const p = A.providerOf(v.ag), L = p?.livery && (p.livery[v.mode] || p.livery.default);
    return { body: L?.body || v.color, stripe: L?.stripe || "#ffffff", roof: L?.roof || "#d4d8de", skirt: L?.skirt || "#2a2f36" };
  }

  // ---- the frame: simulate, cull, write instances. Drawing itself happens in the custom layer.
  function frame(dt) {
    const c = map.getCenter(), z = map.getZoom();
    const ox = mercX(c.lng), oy = mercY(c.lat), k = 1 / (40075016.686 * Math.cos((c.lat * Math.PI) / 180));  // mercator units per metre
    const b = map.getBounds(), m = 0.25 * Math.max(b.getEast() - b.getWest(), 1e-4);
    const x0 = mercX(b.getWest() - m), x1 = mercX(b.getEast() + m), y1 = mercY(b.getSouth() - m), y0 = mercY(b.getNorth() + m);
    scene.beginFrame();
    const zAt = terrain.on && dem ? (mx, my) => dem.sampleMerc(mx, my) : () => 0;  // ground elevation under a mercator point
    const live = simLive(), dark = scene.light.night, lights = dark > 0.12 ? Math.min(1, (dark - 0.1) / 0.5) : 0, bh = scene.batches.get("b_head")?.batch, bt = scene.batches.get("b_tail")?.batch;
    const routeOn = hi.size > 0, dotAlpha = z < Z_MESH + 0.5 ? 1 : Math.max(0, 1 - (z - (Z_MESH + 0.5)) / 1.2);
    const dotSize = z < 12 ? 7 : z < 14 ? 10 : 14, labels = z >= Z_LABEL && z < 17.6, meshes = z >= Z_MESH;
    for (const v of V.values()) {
      if (v.sched ? (window.Daylight?.mode === "cycle" && window.Daylight.speed > 60) : !live) continue;
      const a = step(v, dt, nowSec), sh = v.shape || v.ray;
      if (a < 0.02 || (v.sched && !sh)) continue;
      if (sh) { const i = cursor(sh, v, "seg0", v.s), t = (v.s - sh.cum[i]) / (sh.cum[i + 1] - sh.cum[i] || 1); v.mx = sh.MX[i] + (sh.MX[i + 1] - sh.MX[i]) * t; v.my = sh.MY[i] + (sh.MY[i + 1] - sh.MY[i]) * t; }
      if (v.mx < x0 || v.mx > x1 || v.my < y0 || v.my > y1) continue;
      const mine = hi.has(v.trip) || v.id === followId, alpha = a * (routeOn && !mine ? 0.35 : 1), dx = (v.mx - ox) / k, dy = (oy - v.my) / k;
      if (dotAlpha > 0.02) {
        const gz = zAt(v.mx, v.my);
        if (mine) scene.dots.push(dx, dy, v.rgb[0], v.rgb[1], v.rgb[2], 90, dotSize * 2.1, -1, gz);
        scene.dots.push(dx, dy, v.rgb[0], v.rgb[1], v.rgb[2], Math.round(255 * alpha * dotAlpha), dotSize, -1, gz);
        if (labels && v.line) scene.addLabel(v.line, dx, dy, gz);
      }
      if (meshes && sh) {
        if (!v.model) { v.model = modelFor(v); const L = livery(v); v.liv = scene.palette.id(L); v.tint = window.Fleet.jitter(L.body, v.id); }
        const al = Math.round(255 * alpha), cars = v.model.cars, bend = cars.length > 1, tn = v.tint;
        for (let i = 0; i < cars.length; i++) {
          const cd = cars[i];
          let cx = dx, cy = dy, fx = v.hx, fy = v.hy, cz = zAt(v.mx, v.my);
          if (bend) { poseAt(sh, v.s + cd.c); cx = (pose[0] - ox) / k; cy = (oy - pose[1]) / k; fx = pose[2]; fy = pose[3]; cz = zAt(pose[0], pose[1]); }
          const tx = fx, ty = fy;  // the direction of travel, before a reversed car is turned round
          if (cd.flip) { fx = -fx; fy = -fy; }
          scene.batches.get(cd.mesh).batch.push(cx, cy, fx, fy, v.liv, al, 0, tn[0], tn[1], tn[2], 255, cz);
          if (lights && bh) {  // headlight cones at the front of the first car, tail cones at the back of the last
            const hl = (window.Fleet.LEN[cd.mesh] || 10) / 2;
            if (i === cars.length - 1) bh.push(cx + tx * hl, cy + ty * hl, tx, ty, 0, Math.round(190 * lights * alpha), 0, 255, 246, 214, 255, cz);
            if (i === 0) bt.push(cx - tx * hl, cy - ty * hl, tx, ty, 0, Math.round(170 * lights * alpha), 0, 255, 34, 22, 255, cz);
          }
        }
      }
    }
    if (meshes && roofs.anchor && threeD) {
      const A = roofs.anchor, ax = mercX(A.lon), ay = mercY(A.lat), rx = (ax - ox) / k, ry = (oy - ay) / k;
      for (const [hex, rgb] of roofs.meshes) scene.batches.get("roof:" + hex)?.batch.push(rx, ry, 1, 0, 0, 255, 0, rgb[0], rgb[1], rgb[2], 255);
    }
    if (threeD && facades.anchor && scene.hasFacades()) {
      const A = facades.anchor, ax = mercX(A.lon), ay = mercY(A.lat);
      scene.setFacadeAnchorOffset((ax - ox) / k, (oy - ay) / k);
    }
    if (meshes && infra.anchor && threeD) {
      const A = infra.anchor, ax = mercX(A.lon), ay = mercY(A.lat), rx = (ax - ox) / k, ry = (oy - ay) / k;
      for (const [name, rgb] of infra.meshes) {
        scene.batches.get("infra:" + name)?.batch.push(rx, ry, 1, 0, 0, 255, 0, rgb[0], rgb[1], rgb[2], 255);
      }
    }
    if (decor.items && ambient && z >= 16) {
      const night = scene.light.night, mpp = (78271.517 * Math.cos((c.lat * Math.PI) / 180)) / Math.pow(2, z), glow = night > 0.2 ? Math.min(1, (night - 0.2) / 0.5) : 0;
      for (const list of ["trees", "lamps", "benches", "bins", "stops"]) for (const o of decor.items[list]) {
        if (o.mx < x0 || o.mx > x1 || o.my < y0 || o.my > y1) continue;
        const dx = (o.mx - ox) / k, dy = (oy - o.my) / k, tinted = o.kind.startsWith("tree") || o.kind === "bin", gz = zAt(o.mx, o.my);
        scene.batches.get("w_" + o.kind)?.batch.push(dx, dy, o.fx, o.fy, decor.liv[o.kind], 255, 0, o.tint[0], o.tint[1], o.tint[2], tinted ? 255 : 0, gz);
        if (glow && o.kind === "lamp") {  // a cone of light from the lamp head down to a pool on the road, plus a small halo at the lamp
          scene.batches.get("b_lamp")?.batch.push(dx, dy, o.fx, o.fy, 0, Math.round(190 * glow), 0, 255, 188, 96, 255, gz);
          scene.dots.push(dx - o.fy * 1.4, dy + o.fx * 1.4, 255, 200, 120, Math.round(70 * glow), -Math.min(60, 3.2 / mpp), -1, gz + 6.9);
        } else if (glow && o.kind === "busstop") scene.dots.push(dx, dy, 255, 200, 120, Math.round(60 * glow), -Math.min(60, 4 / mpp), -1, gz + 2);
      }
    }
    if (traffic && ambient && meshes) {
      traffic.setHour(window.Daylight ? window.Daylight.clockHour() : new Date().getHours());
      traffic.step(dt);
      const bhc = bh, btc = bt;
      traffic.write(ox, oy, k, x0, x1, y0, y1, (type, dx, dy, fx, fy, a, tn, len) => {
        const gz = zAt(ox + dx * k, oy - dy * k);
        scene.batches.get("car_" + type).batch.push(dx, dy, fx, fy, 0, Math.round(255 * a), 0, tn[0], tn[1], tn[2], 255, gz);
        if (lights && bhc) {
          const hl = len / 2;
          bhc.push(dx + fx * hl, dy + fy * hl, fx, fy, 0, Math.round(170 * lights * a), 0, 255, 246, 214, 255, gz);
          btc.push(dx - fx * hl, dy - fy * hl, fx, fy, 0, Math.round(150 * lights * a), 0, 255, 34, 22, 255, gz);
        }
      });
    }
    // Weather particles in 3D: rain or snow falling around the camera
    const weather = window.Daylight?.weather?.condition;
    if (ambient && threeD && (weather === "rain" || weather === "snow" || weather === "thunderstorm")) {
      const isSnow = weather === "snow";
      const count = isSnow ? 140 : 200;
      const speed = isSnow ? 4.5 : 28.0;
      const size = isSnow ? -3.5 : 1.8;
      const r = isSnow ? 245 : 190, g = isSnow ? 250 : 210, b = isSnow ? 255 : 230, a = isSnow ? 190 : 160;
      const t = performance.now() * 0.001;
      for (let i = 0; i < count; i++) {
        const pSeed = (i * 1013904223) >>> 0;
        const rx = ((pSeed % 1200) - 600) * 0.1;
        const ry = (((pSeed * 31) % 1200) - 600) * 0.1;
        const rzBase = ((pSeed * 17) % 350) * 0.1 + 1.0;
        const dropZ = ((rzBase - t * speed) % 35 + 35) % 35;
        const windX = isSnow ? Math.sin(t + i) * 1.5 : 0;
        scene.dots.push(rx + windX, ry, r, g, b, a, size, -1, dropZ);
      }
    }
    scene.setFrame({ ox, oy, k, zoom: z, dpr: window.devicePixelRatio || 1 });
    window.Daylight?.apply(scene, map);
    if (followId) chase(V.get(followId), dt);
  }
  function tick() {
    requestAnimationFrame(tick);
    const t = performance.now();
    if (!scene || !map || document.hidden || !shown() || map.getZoom() < Z_DOTS) { lastTick = t; return; }
    const dt = Math.min(0.05, (t - lastTick) / 1000);
    lastTick = t;
    nowSec = T();
    frame(dt);
    map.triggerRepaint();
  }

  let dioTrackBar = null;
  function updateDioTrackBar(v) {
    const isDio = document.body.classList.contains("dio-on");
    if (!isDio || !v) {
      if (dioTrackBar) dioTrackBar.hidden = true;
      return;
    }
    if (!dioTrackBar) {
      dioTrackBar = h("section", { id: "dio-track", class: "dio-track glass", "aria-label": "Tracking vehicle in diorama" },
        h("div", { class: "dt-top" },
          h("div", { class: "dt-head" },
            h("span", { id: "dt-badge" }),
            h("div", { class: "dt-meta" },
              h("b", { id: "dt-dir" }),
              h("div", { class: "dt-tags" },
                h("span", { id: "dt-src", class: "dt-chip" }),
                h("span", { id: "dt-delay", class: "dt-chip" }),
                h("span", { id: "dt-agency", class: "dt-chip meta" })
              )
            )
          ),
          h("button", { class: "icon-btn small", id: "dt-stop", "aria-label": "Stop tracking", onclick: () => stopFollow() }, icon("x"))
        ),
        h("div", { id: "dt-timeline", class: "dt-timeline" })
      );
      document.body.append(dioTrackBar);
    }
    dioTrackBar.hidden = false;

    // Line and Direction
    $("#dt-badge").replaceChildren(A.badge(v.line || "?", v.color, v.mode));
    $("#dt-dir").textContent = v.to ? `to ${v.to}` : (v.line ? `Line ${v.line}` : "Vehicle");
    $("#dt-agency").textContent = A.providerOf(v.ag)?.name || v.ag || "";

    // Data source indicator: live, simulated live, or replayed from schedule
    const live = simLive();
    let srcText = "", srcClass = "";
    if (!live) {
      srcText = "Replayed from schedule";
      srcClass = "src-replay";
    } else if (v.sched) {
      srcText = "Simulated live";
      srcClass = "src-sim";
    } else {
      srcText = "Live data";
      srcClass = "src-live";
    }
    const srcEl = $("#dt-src");
    srcEl.textContent = srcText;
    srcEl.className = "dt-chip " + srcClass;

    // Delay indicator
    const delayEl = $("#dt-delay");
    if (v.sched) {
      delayEl.textContent = "Scheduled";
      delayEl.className = "dt-chip";
    } else if (v.delay != null) {
      const min = Math.round(v.delay / 60);
      if (min === 0) {
        delayEl.textContent = "On time";
        delayEl.className = "dt-chip on-time";
      } else if (min > 0) {
        delayEl.textContent = `+${min} min`;
        delayEl.className = "dt-chip late";
      } else {
        delayEl.textContent = `${min} min`;
        delayEl.className = "dt-chip early";
      }
    } else {
      delayEl.textContent = v.vel > 0.5 ? "Moving" : "Standing";
      delayEl.className = "dt-chip";
    }

    // Timeline with stops along route
    const tlEl = $("#dt-timeline");
    const stops = v.shape?.stops || [];
    if (!stops.length) {
      tlEl.innerHTML = `<span class="dt-nostops">${v.shape === "pending" ? "Loading route stops…" : (v.sn ? `Next stop: ${v.sn}` : "Route timeline")}</span>`;
    } else {
      let curIdx = 0;
      for (let i = 0; i < stops.length; i++) {
        if (stops[i].a <= v.s) curIdx = i;
      }
      const items = stops.map((st, i) => {
        let cls = "dt-stop";
        if (i < curIdx) cls += " past";
        else if (i === curIdx || (i === curIdx + 1 && Math.abs(st.a - v.s) < 40)) cls += " current";
        else cls += " upcoming";
        return h("div", { class: cls, title: st.n },
          h("div", { class: "dt-dot" }),
          h("div", { class: "dt-name" }, st.n)
        );
      });
      tlEl.replaceChildren(...items);
      const curEl = tlEl.children[curIdx];
      if (curEl && tlEl.scrollLeft != null) {
        const targetX = curEl.offsetLeft - tlEl.clientWidth / 2 + curEl.clientWidth / 2;
        tlEl.scrollLeft = targetX;
      }
    }
  }

  // chase camera: glides to the vehicle, and in 3D turns to look along its direction of travel
  function chase(v, dt) {
    if (!v) {
      if (followBar) $("#follow-status").textContent = "No position for this vehicle right now";
      if (dioTrackBar) dioTrackBar.hidden = true;
      return;
    }
    const lon = lonOf(v.mx), lat = latOf(v.my), c = map.getCenter(), k = 1 - Math.exp(-dt / 0.4);
    cam = cam || { lon: c.lng, lat: c.lat, zoom: map.getZoom(), target: Math.max(map.getZoom(), 17.8) };
    cam.lon += (lon - cam.lon) * k; cam.lat += (lat - cam.lat) * k;
    if (cam.free) cam.zoom = map.getZoom(); else cam.zoom += (cam.target - cam.zoom) * (1 - Math.exp(-dt / 0.6));
    const opts = { center: [cam.lon, cam.lat], zoom: cam.zoom, animate: false };
    if (threeD) { const hd = (Math.atan2(v.hx, v.hy) * 180) / Math.PI, bear = map.getBearing(); opts.bearing = bear + (((hd - bear + 540) % 360) - 180) * (1 - Math.exp(-dt / 0.8)); }
    map.jumpTo(opts);
    $("#follow-status").textContent = v.sched ? (v.vel > 0.5 ? "Estimated from the timetable and its delay" : "Standing, by the timetable") : v.st === "STOPPED_AT" ? `At ${v.sn || "a stop"}` : v.sn ? `Next stop: ${v.sn}` : v.vel > 0.5 ? "Moving" : "Standing";
    updateDioTrackBar(v);
  }
  function showBar(v) {
    if (!followBar) {
      followBar = h("section", { id: "follow", class: "follow glass", "aria-label": "Following a vehicle" },
        h("div", { class: "f-main" }, h("div", { id: "follow-title", class: "f-title" }), h("div", { id: "follow-sub", class: "f-sub" }), h("div", { id: "follow-status", class: "f-status", role: "status", "aria-live": "polite" })),
        h("button", { class: "chip", id: "follow-stop", onclick: () => stopFollow() }, "Stop"));
      document.body.append(followBar);
    }
    followBar.hidden = false;
    $("#follow-title").replaceChildren(A.badge(v.line || "?", v.color, v.mode), v.to ? ` to ${v.to}` : "");
    $("#follow-sub").textContent = A.providerOf(v.ag)?.name || v.ag || "";
    updateDioTrackBar(v);
  }
  function follow(id) {
    const v = V.get(id);
    if (!v) return false;
    followId = id; cam = null; syncVisibility(); refresh();
    showBar(v);
    ensureShape(v);
    return true;
  }
  function stopFollow() {
    followId = null; cam = null;
    if (followBar) followBar.hidden = true;
    if (dioTrackBar) dioTrackBar.hidden = true;
    syncVisibility();
    map.easeTo({ bearing: threeD ? map.getBearing() : 0, duration: 400 });
  }
  function ensureShape(v) {
    if (v.shape || !v.trip) return;
    const known = SHAPES.get(v.trip);
    if (known && known.points) return attachShape(v, known);
    if (known === "pending") return;
    SHAPES.set(v.trip, "pending");
    api("shape", { trip: v.trip }).then((info) => { info.trip = v.trip; SHAPES.set(v.trip, info); for (const o of V.values()) if (o.trip === v.trip && !o.shape) attachShape(o, info); }).catch(() => SHAPES.set(v.trip, { fail: T() }));
  }
  async function followTrip(trip) {
    if (!map || !trip) return false;
    let v = [...V.values()].find((x) => x.trip === trip);
    if (!v) {
      try { const r = await api("vehicles", { trip }); ingest(r.vehicles, r.now); } catch { return false; }
      v = [...V.values()].find((x) => x.trip === trip);
    }
    return v ? follow(v.id) : false;
  }

  // the dark base map is used by the OS theme, or at night in diorama mode
  const isDark = () => (window.Daylight?.enabled ? window.Daylight.wantsDark() : matchMedia("(prefers-color-scheme: dark)").matches);
  // one of six colours per building, stable for a given building (hashed from its height and base)
  const pick6 = (list) => {
    const key = ["%", ["floor", ["*", ["+", ["coalesce", ["get", "render_height"], 6], ["*", ["coalesce", ["get", "render_min_height"], 0], 3.7]], 13.37]], 6];
    return ["match", key, 0, list[0], 1, list[1], 2, list[2], 3, list[3], 4, list[4], list[5]];
  };
  function buildingPalettes(dark) {
    return dark
      ? { walls: ["#3a3f48", "#403b3a", "#363c44", "#443f3a", "#393e3b", "#3f4048"], roofs: ["#5a3a34", "#4d3732", "#3d4249", "#4a403b", "#563f35", "#444a50"], flat: "#2f3338" }
      : { walls: ["#e6dfd2", "#dad3c6", "#e0dcd4", "#d2ccc0", "#e4d8ca", "#d9d6cf"], roofs: ["#b4604a", "#9c5140", "#6d727a", "#85726a", "#a9745e", "#7a8088"], flat: "#8d9198" };
  }
  // ---- layers: heatmap (MapLibre), 3D buildings (MapLibre), everything else is the custom layer
  function layers() {
    const css = (n, d) => getComputedStyle(document.documentElement).getPropertyValue(n).trim() || d;
    if (!map.getSource("veh-heat")) map.addSource("veh-heat", { type: "geojson", data: { type: "FeatureCollection", features: [] } });
    const firstSymbol = (map.getStyle().layers.find((l) => l.type === "symbol") || {}).id;
    if (!map.getLayer("buildings-3d") && map.getSource("openmaptiles")) {
      const P = buildingPalettes(isDark()), H = ["coalesce", ["get", "render_height"], 6], B = ["coalesce", ["get", "render_min_height"], 0];
      map.addLayer({ id: "buildings-3d", type: "fill-extrusion", source: "openmaptiles", "source-layer": "building", minzoom: 14,
        paint: { "fill-extrusion-color": pick6(P.walls), "fill-extrusion-height": H, "fill-extrusion-base": B, "fill-extrusion-opacity": 1, "fill-extrusion-vertical-gradient": true } }, firstSymbol);
      // vector tiles carry no roof shape, so the roof is a thin cap in its own colour: tiles on low buildings, bare concrete and tar on tall ones
      map.addLayer({ id: "buildings-roof", type: "fill-extrusion", source: "openmaptiles", "source-layer": "building", minzoom: 14.5,
        paint: { "fill-extrusion-color": ["case", [">", H, 28], P.flat, pick6(P.roofs)], "fill-extrusion-height": ["+", H, ["case", [">", H, 28], 0.5, 1.6]], "fill-extrusion-base": H, "fill-extrusion-opacity": 1, "fill-extrusion-vertical-gradient": false } }, firstSymbol);
    }
    if (!map.getLayer("veh-heat")) {
      map.addLayer({ id: "veh-heat", type: "heatmap", source: "veh-heat", maxzoom: Z_HEAT_OUT, paint: {
        "heatmap-weight": 1, "heatmap-intensity": ["interpolate", ["linear"], ["zoom"], 6, 0.12, 9, 0.35, 11, 0.9], "heatmap-radius": ["interpolate", ["linear"], ["zoom"], 6, 6, 11, 18],
        "heatmap-color": ["interpolate", ["linear"], ["heatmap-density"], 0, "rgba(0,0,0,0)", 0.15, "rgba(60,150,170,0.35)", 0.45, css("--accent", "#0b6e5c"), 0.75, "#e0a100", 1, "#c62828"],
        "heatmap-opacity": ["interpolate", ["linear"], ["zoom"], 10.4, 0.9, Z_HEAT_OUT, 0] } });
    }
    if (scene && !map.getLayer(scene.id)) map.addLayer(scene.layer);
    if (terrain.on) applyTerrain();
    scene?.labels.theme(isDark() ? "#eef1f4" : "#14181d", isDark() ? "#1b1f24" : "#ffffff");
    window.Daylight?.syncTheme?.(isDark());
    syncVisibility();
  }
  const shown = () => on && (ctx || force || followId !== null);  // vehicles belong to transit contexts, not to general map browsing
  function syncVisibility() {
    if (!map) return;
    if (map.getLayer("veh-heat")) map.setLayoutProperty("veh-heat", "visibility", shown() ? "visible" : "none");
    for (const id of ["buildings-3d", "buildings-roof"]) if (map.getLayer(id)) map.setLayoutProperty(id, "visibility", threeD ? "visible" : "none");
    if (scene) { scene.showDots = scene.showMeshes = scene.showLabels = shown(); }
    const bt = $("#btn-veh");
    if (bt) bt.hidden = !(ctx || force || followId !== null);
    if (threeD) rebuildFacades();
    map.triggerRepaint();
    refreshSched();
  }

  // ---- data
  let fetching = false;
  async function refresh() {
    if (!shown() || !map || document.hidden || fetching) return;
    const z = map.getZoom();
    fetching = true;
    try {
      const b = map.getBounds(), w = (b.getEast() - b.getWest()) * 0.2, hh = (b.getNorth() - b.getSouth()) * 0.2;
      const box = [b.getWest() - w, b.getSouth() - hh, b.getEast() + w, b.getNorth() + hh].map((x) => x.toFixed(5)).join(",");
      if (z < Z_HEAT_OUT) {
        const r = await api("vehicles", { bbox: box, lod: "heat" });
        map.getSource("veh-heat")?.setData({ type: "FeatureCollection", features: r.heat.map((c) => ({ type: "Feature", properties: {}, geometry: { type: "Point", coordinates: c } })) });
      }
      if (z >= Z_DOTS) {
        const r = await api("vehicles", { bbox: box });
        ingest(r.vehicles, r.now);
        let budget = 30;
        for (const v of V.values()) {
          if (v.shape || !v.trip || budget <= 0 || z < 12) continue;
          const known = SHAPES.get(v.trip);
          if (known && known.points) { attachShape(v, known); continue; }
          if (known === "pending" || (known && T() - known.fail < 60)) continue;  // loading, or failed less than a minute ago
          budget--;
          ensureShape(v);
        }
      }
    } catch { /* keep animating what we have */ } finally { fetching = false; }
  }

  // ---- picking: project every vehicle and take the nearest to the pointer
  function pick(pt) {
    let best = null, bd = 1e9;
    const reach = map.getZoom() >= Z_MESH + 1 ? 26 : 16;
    for (const v of V.values()) {
      if (!v.mx) continue;
      const p = map.project([lonOf(v.mx), latOf(v.my)]), d = Math.hypot(p.x - pt.x, p.y - pt.y);
      if (d < bd && d < reach) { bd = d; best = v; }
    }
    return best;
  }

  // ---- ui
  function controls() {
    const box = $("#mapctl");
    const vb = h("button", { class: "icon-btn", id: "btn-veh", "aria-label": "Live vehicles", "aria-pressed": on, title: "Live vehicles" }, icon("bus"));
    const tb = h("button", { class: "icon-btn txt", id: "btn-3d", "aria-label": "3D view", "aria-pressed": threeD, title: "3D view" }, "3D");
    vb.addEventListener("click", () => { on = !on; store.set("veh", on); vb.setAttribute("aria-pressed", on); syncVisibility(); if (on) refresh(); });
    tb.addEventListener("click", () => set3d(!threeD));
    box.append(vb, tb);
  }
  function set3d(v) {
    threeD = v; store.set("3d", v);
    $("#btn-3d")?.setAttribute("aria-pressed", v);
    if (v) {
      map.setMaxPitch(85);
      map.dragRotate?.enable();
      map.touchPitch?.enable();
      map.touchZoomRotate?.enableRotation();
      map.easeTo({ pitch: 58, duration: 600 });
    } else {
      map.easeTo({ pitch: 0, bearing: 0, duration: 500 });
      map.dragRotate?.disable();
      map.touchPitch?.disable();
      map.touchZoomRotate?.disableRotation();
    }
    syncVisibility();
  }
  function setupScene() {
    const S3 = window.Scene3D, car = S3.carMesh;
    scene = S3.createLayer({ id: "scene3d" });
    const meshes = {
      bus12: car({ L: 12, W: 2.5, H: 3.1, nose: "both", bus: true }),
      busMid: car({ L: 10.5, W: 2.45, H: 3.0, nose: "both", bus: true }),
      bus18F: car({ L: 8.8, W: 2.5, H: 3.1, nose: "front", bus: true }),
      bus18R: car({ L: 8.2, W: 2.5, H: 3.1, nose: "front", bus: true }),
      bellowsBus: S3.bellowsMesh(1.4, 2.2, 3.0),
      coach12: car({ L: 12.3, W: 2.55, H: 3.5, nose: "both", bus: true }),
      tram105: car({ L: 13.4, W: 2.4, H: 3.3, nose: "front", wheels: 0, pantograph: true }),
      tramEnd: car({ L: 8.6, W: 2.4, H: 3.5, nose: "front", wheels: 0 }),
      tramMid: car({ L: 8.6, W: 2.4, H: 3.5, nose: "none", pantograph: true, wheels: 0 }),
      bellowsTram: S3.bellowsMesh(1.2, 2.0, 3.5),
      railEnd: car({ L: 20, W: 2.9, H: 4.1, nose: "front", wheels: 0, bogies: 2 }),
      railMid: car({ L: 20, W: 2.9, H: 4.1, nose: "none", wheels: 0, bogies: 2 }),
      icCoach: car({ L: 24.5, W: 2.82, H: 4.0, nose: "none", wheels: 0, bogies: 2 }),
      loco: car({ L: 18, W: 3, H: 4.3, nose: "both", loco: true, wheels: 0, bogies: 2 }),
    };
    for (const t of S3.ROAD_TYPES) meshes["car_" + t] = S3.roadVehicleMesh(t);
    const caps = { car_hatch: 512, car_sedan: 512, car_suv: 512, car_van: 256, car_truck: 192, bus12: 1024, busMid: 512, bus18F: 512, bus18R: 512, bellowsBus: 512, coach12: 128, tram105: 256, tramEnd: 512, tramMid: 512, bellowsTram: 1024, railEnd: 256, railMid: 512, icCoach: 256, loco: 128 };
    for (const [name, mesh] of Object.entries(meshes)) { scene.registerMesh(name, mesh); scene.addBatch(name, name, caps[name]); }
    if (window.World) {
      const caps = { tree_round: 4000, tree_cone: 2500, tree_bare: 4000, lamp: 2600, bench: 800, bin: 700, busstop: 320 };
      const lv = { tree_round: ["#5b4636", "#3f7a3a", "#2f5d2c", "#4a8a40"], tree_cone: ["#5b4636", "#2f5d3a", "#2f5d2c", "#4a8a40"], tree_bare: ["#5b4a3c", "#5b4a3c", "#5b4a3c", "#5b4a3c"],
        lamp: ["#3a3f45", "#3a3f45", "#3a3f45", "#3a3f45"], bench: ["#3a3d42", "#3a3d42", "#9a7650", "#8a6a45"], bin: ["#3a3d42", "#345c40", "#3a3d42", "#3a3d42"], busstop: ["#3a3f45", "#3a3f45", "#a07a50", "#6b7480"] };
      for (const [name, make] of Object.entries(window.World.MESHES)) {
        scene.registerMesh("w_" + name, make()); scene.addBatch("w_" + name, "w_" + name, caps[name]);
        const l = lv[name]; decor.liv[name] = scene.palette.id({ skirt: l[0], body: l[1], stripe: l[2], roof: l[3] });
      }
    }
    if (window.World) for (const [name, make] of Object.entries(window.World.BEAMS)) { scene.registerMesh("b_" + name, make()); scene.addBatch("b_" + name, "b_" + name, name === "lamp" ? 3000 : 4000, { beam: true }); }
    scene.meshZoom = Z_MESH;
  }
  // riding: the passenger's own GPS is fresher and closer than the vehicle feed (which lags by 10 to 30 s), so while aboard it is fed in as a zero-age report
  let rideAsked = 0;
  function rideSync(trip, fix) {
    if (!trip || !fix || fix.acc > 60) return false;
    const v = [...V.values()].find((x) => x.trip === trip && !x.sched);
    if (!v) {
      const t = T();
      if (t - rideAsked > 10) { rideAsked = t; api("vehicles", { trip }).then((r) => ingest(r.vehicles, r.now)).catch(() => {}); }
      return false;
    }
    const kx = 111320 * Math.cos((fix.lat * Math.PI) / 180), dm = Math.hypot((fix.lon - lonOf(v.mx)) * kx, (fix.lat - latOf(v.my)) * 110540);
    if (dm > 700) return false;  // somewhere else: not this vehicle, or not aboard yet
    const now = Date.now() / 1000;
    ingest([{ id: v.id, lat: fix.lat, lon: fix.lon, hd: fix.heading, sp: fix.speed != null && fix.speed >= 0 ? fix.speed : null, ts: now, line: v.line, mode: v.mode, ag: v.ag, to: v.to, trip: v.trip, st: v.st, sn: v.sn }], now);
    return true;
  }
  // ---- terrain: MapLibre drapes the map and the buildings on the DEM, and our own sampler of the same tiles lifts everything we draw
  const terrain = { on: false, exaggeration: 2 };
  let dem = null;
  const demUrl = () => location.origin + "/api/dem?z={z}&x={x}&y={y}";
  function applyTerrain() {
    if (!map || !map.getStyle()) return;  // isStyleLoaded() is false while tiles load, which would skip this for good
    if (!map.getSource("dem")) map.addSource("dem", { type: "raster-dem", tiles: [demUrl()], encoding: "terrarium", tileSize: 256, maxzoom: 14, attribution: "Elevation: Mapzen terrain tiles (SRTM, EU-DEM, NED), AWS Open Data" });
    if (!map.getSource("dem-hs")) map.addSource("dem-hs", { type: "raster-dem", tiles: [demUrl()], encoding: "terrarium", tileSize: 256, maxzoom: 14 });  // a second source for the shading, as MapLibre advises
    if (!map.getLayer("dem-hill")) {
      const first = (map.getStyle().layers.find((l) => l.type === "symbol") || {}).id;
      map.addLayer({ id: "dem-hill", type: "hillshade", source: "dem-hs", maxzoom: 16, paint: { "hillshade-exaggeration": 0.3, "hillshade-illumination-anchor": "map", "hillshade-shadow-color": "#2a2f3a", "hillshade-highlight-color": "#ffffff", "hillshade-accent-color": "#6b7280" } }, map.getLayer("buildings-3d") ? "buildings-3d" : first);
    }
    map.setLayoutProperty("dem-hill", "visibility", terrain.on ? "visible" : "none");
    if (terrain.on) map.setTerrain({ source: "dem", exaggeration: terrain.exaggeration }); else map.setTerrain(null);
    if (dem) dem.exaggeration = terrain.on ? terrain.exaggeration : 1;
  }
  let rebuildTimer = 0;
  function terrainChanged() {
    clearTimeout(rebuildTimer);
    rebuildTimer = setTimeout(() => {
      if (roofs.ways.size) rebuildRoofs();
      rebuildFacades();
      if (ambient) { laneKey = ""; loadLanes(); }
      map?.triggerRepaint();
    }, 400);
  }
  function setTerrain(level) {  // 0 = flat, otherwise the vertical exaggeration
    terrain.on = level > 0;
    if (level > 0) terrain.exaggeration = level;
    if (terrain.on && !dem && window.DemLib) dem = new window.DemLib.Dem({ zoom: 14, fetchTile: window.DemLib.browserFetcher((z, x, y) => `/api/dem?z=${z}&x=${x}&y=${y}`), onload: terrainChanged });
    applyTerrain();
    if (dem) { dem.exaggeration = terrain.on ? terrain.exaggeration : 1; ensureDem(); }
    terrainChanged();
  }
  function ensureDem() {
    if (!terrain.on || !dem || !map) return;
    const b = map.getBounds(), w = (b.getEast() - b.getWest()) * 0.3, h = (b.getNorth() - b.getSouth()) * 0.3;
    dem.retry(); dem.ensure(b.getWest() - w, b.getSouth() - h, b.getEast() + w, b.getNorth() + h);
  }
  // street details: trees, lamps, benches, bins and bus stops, placed on the traffic lanes and kept off buildings
  const decor = { items: null, liv: {}, lanesAt: null };
  const ring2local = (ring, A, kx) => ring.map(([lo, la]) => [(lo - A.lon) * kx, (la - A.lat) * 111320]);
  function buildDecor(anchor, lanes) {
    if (!window.World || !map.getSource("openmaptiles")) { decor.items = null; return; }
    const kx = 111320 * Math.cos((anchor.lat * Math.PI) / 180), rings = [], parks = [], stops = [], seen = new Set();
    const polys = (g) => (g.type === "Polygon" ? [g.coordinates] : g.type === "MultiPolygon" ? g.coordinates : []);
    const q = (layer) => { try { return map.querySourceFeatures("openmaptiles", { sourceLayer: layer }); } catch { return []; } };
    for (const f of q("building")) for (const p of polys(f.geometry)) { const id = p[0][0].join(",") + p[0].length; if (!seen.has(id)) { seen.add(id); rings.push(ring2local(p[0], anchor, kx)); } }
    for (const layer of ["park", "landcover", "landuse"]) for (const f of q(layer)) {
      const c = f.properties.class;
      if (!(layer === "park" || (layer === "landcover" && (c === "wood" || c === "forest")) || (layer === "landuse" && (c === "park" || c === "garden" || c === "cemetery")))) continue;
      for (const p of polys(f.geometry)) { const id = "p" + p[0][0].join(",") + p[0].length; if (!seen.has(id) && p[0].length < 400) { seen.add(id); parks.push(ring2local(p[0], anchor, kx)); } }
    }
    for (const f of q("poi")) { const p = f.properties; if (f.geometry.type === "Point" && (p.subclass === "bus_stop" || p.subclass === "tram_stop")) { const id = "s" + f.geometry.coordinates.join(","); if (!seen.has(id)) { seen.add(id); stops.push([(f.geometry.coordinates[0] - anchor.lon) * kx, (f.geometry.coordinates[1] - anchor.lat) * 111320]); } } }
    const month = (window.Daylight ? window.Daylight.time() : new Date()).getMonth() + 1;
    const zoom = map ? map.getZoom() : 16;
    const res = window.World.place({ lanes, rings, parks, stops, month, zoom });
    decor.inputs = { lanes, rings };
    const kA = 1 / (40075016.686 * Math.cos((anchor.lat * Math.PI) / 180)), ax = mercX(anchor.lon), ay = mercY(anchor.lat);
    for (const list of Object.values(res)) for (const o of list) { o.mx = ax + o.x * kA; o.my = ay - o.y * kA; }
    decor.items = res; decor.month = month;
  }
  // 3D infrastructure: roads, curbs, bridges, tunnels, rail ballast, steel rails, and catenary lines
  const infra = { anchor: null, meshes: new Map() };
  function rebuildInfra(anchor, features) {
    if (!scene || !window.Roads3D || !features) return;
    infra.anchor = anchor;
    const groundFn = (x, y) => {
      if (!terrain.on || !dem) return 0;
      const kA = 1 / (40075016.686 * Math.cos((anchor.lat * Math.PI) / 180));
      return dem.sampleMerc(mercX(anchor.lon) + x * kA, mercY(anchor.lat) - y * kA);
    };
    const res = window.Roads3D.build(features, anchor, groundFn);
    for (const [name, mesh] of Object.entries(res.meshes)) {
      const batchName = "infra:" + name;
      if (!mesh || !mesh.verts || mesh.verts.length === 0) {
        if (infra.meshes.has(name)) {
          scene.dropMesh(batchName);
          infra.meshes.delete(name);
        }
        continue;
      }
      scene.setDynamicMesh(batchName, mesh);
      infra.meshes.set(name, window.Roads3D.COLORS[name] || [128, 128, 128]);
    }
  }
  // roof shapes from OSM (roof:shape): streamed in 0.01 degree cells, built into one mesh per colour around a fixed anchor
  const roofs = { cells: new Map(), ways: new Map(), anchor: null, meshes: new Map(), busy: false, key: "" };
  const capH = (w) => { const base = w.h || (w.lv ? w.lv * 3.1 : 6); return base + (base > 28 ? 0.5 : 1.6); };  // the flat cap layer is what the roof stands on
  function rebuildRoofs() {
    if (!scene || !window.Roofs) return;
    const ground = (w) => { if (!terrain.on || !dem) return 0; let x = 0, y = 0; for (const p of w.pts) { x += p[0]; y += p[1]; } return dem.sample(x / w.pts.length, y / w.pts.length); };
    const { meshes } = window.Roofs.build([...roofs.ways.values()], roofs.anchor, (w) => capH(w) + ground(w));
    for (const name of [...roofs.meshes.keys()]) if (!meshes.has(name)) { scene.dropMesh("roof:" + name); roofs.meshes.delete(name); }
    for (const [hex, mesh] of meshes) { scene.setDynamicMesh("roof:" + hex, mesh); roofs.meshes.set(hex, hex.length === 7 ? [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16)) : [128, 128, 128]); }
  }
  async function loadRoofs() {
    if (!threeD || !map || !scene || roofs.busy || map.getZoom() < Z_MESH) return;
    const c = map.getCenter(), b = map.getBounds(), cx0 = Math.floor(b.getWest() / 0.01), cx1 = Math.floor(b.getEast() / 0.01), cy0 = Math.floor(b.getSouth() / 0.01), cy1 = Math.floor(b.getNorth() / 0.01);
    const want = [];
    for (let x = cx0; x <= cx1; x++) for (let y = cy0; y <= cy1; y++) if (!roofs.cells.has(x + "," + y)) want.push([x, y]);
    if (!want.length) return;
    want.sort((p, q) => Math.hypot(p[0] * 0.01 - c.lng, p[1] * 0.01 - c.lat) - Math.hypot(q[0] * 0.01 - c.lng, q[1] * 0.01 - c.lat));
    const take = want.slice(0, 4);
    if (!roofs.anchor || Math.abs(roofs.anchor.lon - c.lng) > 0.05 || Math.abs(roofs.anchor.lat - c.lat) > 0.03) roofs.anchor = { lon: +c.lng.toFixed(2), lat: +c.lat.toFixed(2) };
    roofs.busy = true;
    try {
      const r = await api("roofs", { cells: take.map((p) => p.join(",")).join(";") });
      for (const id of r.ready) roofs.cells.set(id, true);
      for (const w of r.ways) roofs.ways.set(w.id, w);
      rebuildRoofs();
      if (r.ready.length < take.length) { roofs.busy = false; setTimeout(loadRoofs, 8000); return; }  // the server is still fetching some cells
    } catch { /* retried on the next move */ } finally { roofs.busy = false; }
    if (want.length > take.length) setTimeout(loadRoofs, 1500);
  }
  // procedural building facades with windows that randomly light up after sunset and go almost fully dark after midnight
  const facades = { anchor: null, mesh: null };
  function rebuildFacades() {
    if (!threeD || !scene || !window.Facades || !map || !map.getSource("openmaptiles") || map.getZoom() < 14.5) {
      if (scene?.hasFacades?.()) scene.setFacadeMesh(null);
      return;
    }
    const c = map.getCenter();
    const anchor = { lon: +c.lng.toFixed(2), lat: +c.lat.toFixed(2) };
    facades.anchor = anchor;
    let feats = [];
    try { feats = map.querySourceFeatures("openmaptiles", { sourceLayer: "building" }); } catch { return; }
    if (!feats.length) return;
    const kA = 1 / (40075016.686 * Math.cos((anchor.lat * Math.PI) / 180)), ax = mercX(anchor.lon), ay = mercY(anchor.lat);
    const getGround = (x, y) => (terrain.on && dem ? dem.sampleMerc(ax + x * kA, ay - y * kA) : 0);
    const mesh = window.Facades.buildFacades(feats, anchor, getGround);
    if (mesh) {
      facades.mesh = mesh;
      scene.setFacadeMesh(mesh);
    }
  }
  // trips with no live position, played back from the timetable
  // outside diorama only operators with no live positions at all are estimated (trains, trams without a feed); in diorama every trip without a position is
  let schedBusy = false, schedMode = "";
  async function refreshSched() {
    const mode = ambient ? "all" : shown() ? "gap" : "";
    if (mode !== schedMode) { schedMode = mode; for (const [id, o] of V) if (o.sched) V.delete(id); }
    if (!mode || !map || schedBusy || document.hidden || map.getZoom() < (mode === "all" ? Z_MESH - 1 : 11.5) || (window.Daylight?.mode === "cycle")) return;
    schedBusy = true;
    try {
      const b = map.getBounds(), w = (b.getEast() - b.getWest()) * 0.15, hh = (b.getNorth() - b.getSouth()) * 0.15, live = simLive();
      const box = [b.getWest() - w, b.getSouth() - hh, b.getEast() + w, b.getNorth() + hh].map((x) => x.toFixed(5)).join(",");
      const q = { bbox: box }; if (!live) { q.at = Math.round(simEpoch()); q.all = "1"; } else if (mode === "gap") q.gap = "1";
      const r = await api("sched", q);
      const keep = new Set(), liveTrips = new Set(); for (const o of V.values()) if (!o.sched && o.trip) liveTrips.add(o.trip);
      for (const tr of r.trips || []) {
        if (live && liveTrips.has(tr.trip)) continue;
        const id = "S:" + tr.trip; keep.add(id);
        let v = V.get(id);
        if (!v) {
          v = newVehicle({ id, lon: 0, lat: 0 }, T());
          Object.assign(v, { sched: { sd: tr.sd, st: tr.st, hint: { i: 0 } }, line: tr.line, mode: tr.mode, ag: tr.ag, to: tr.to, trip: tr.trip, modelKey: tr.mode + "|" + tr.ag });
          v.color = A.providerOf(tr.ag)?.color || FALLBACK[tr.mode] || "#44505c";
          v.rgb = [1, 3, 5].map((i) => parseInt(v.color.slice(i, i + 2), 16));
          V.set(id, v);
        } else { v.sched.sd = tr.sd; v.sched.st = tr.st; }
        if (!v.shape) ensureShape(v);
      }
      for (const [id, v] of V) if (v.sched && !keep.has(id) && id !== followId) V.delete(id);
    } catch { /* the next refresh tries again */ } finally { schedBusy = false; }
  }
  // road lanes for ambient traffic come from the tiles already on screen
  let laneKey = "";
  function loadLanes() {
    if (!ambient || !map || !map.getSource("openmaptiles") || map.getZoom() < Z_MESH) return;
    const c = map.getCenter(), STEP = 0.0025, key = Math.round(c.lng / STEP) + "," + Math.round(c.lat / STEP) + "," + Math.round(map.getZoom());  // rebuilding costs a few hundred ms, so only after a real move
    if (key === laneKey) return;
    laneKey = key;
    let feats = [];
    try { feats = map.querySourceFeatures("openmaptiles", { sourceLayer: "transportation" }); } catch (e) { return; }
    const b = map.getBounds(), m = 0.6 * (b.getEast() - b.getWest());
    const inside = feats.filter((f) => { const g = f.geometry, p = g.type === "LineString" ? g.coordinates[0] : g.coordinates?.[0]?.[0]; return p && p[0] > b.getWest() - m && p[0] < b.getEast() + m && p[1] > b.getSouth() - m && p[1] < b.getNorth() + m; });
    const anchor = { lon: +c.lng.toFixed(2), lat: +c.lat.toFixed(2) };
    const lanes = window.Traffic.lanesFromFeatures(inside, anchor);
    traffic.setLanes(lanes, anchor);
    buildDecor(anchor, lanes);
    rebuildInfra(anchor, inside);
  }
  function setAmbient(on) {
    ambient = !!on;
    refreshSched();
    if (!ambient) {
      decor.items = null;
      if (scene) {
        for (const name of infra.meshes.keys()) scene.dropMesh("infra:" + name);
        infra.meshes.clear();
        infra.anchor = null;
      }
    }
    if (ambient && !traffic) traffic = new window.Traffic.Traffic();
    laneKey = "";
    if (ambient) loadLanes();
  }
  function init(m) {
    map = m;
    setupScene();
    controls();
    map.on("style.load", layers);
    if (map.isStyleLoaded()) layers();
    const move = { t: 0 };
    map.on("click", (e) => { if (!shown()) return; const v = pick(e.point); if (v) follow(v.id); });
    map.on("mousemove", (e) => { const n = performance.now(); if (n - move.t < 90 || !shown()) return; move.t = n; map.getCanvas().style.cursor = pick(e.point) ? "pointer" : ""; });
    map.on("dragstart", (e) => { if (followId && e.originalEvent) stopFollow(); });
    map.on("zoomstart", (e) => { if (followId && cam && e.originalEvent) cam.free = true; });
    let deb = 0, deb2 = 0;
    map.on("moveend", () => { clearTimeout(deb); deb = setTimeout(() => { refresh(); loadLanes(); refreshSched(); loadRoofs(); ensureDem(); rebuildFacades(); }, 400); });
    map.on("sourcedata", (e) => {
      if (ambient && e.sourceId === "openmaptiles" && e.isSourceLoaded) { laneKey = ""; clearTimeout(deb2); deb2 = setTimeout(loadLanes, 600); }
      if (threeD && e.sourceId === "openmaptiles" && e.isSourceLoaded) { clearTimeout(deb); deb = setTimeout(rebuildFacades, 500); }
    });
    setInterval(refresh, 5000);
    setInterval(refreshSched, 15000);
    map.touchPitch?.disable();
    if (threeD) set3d(true);
    refresh();
    requestAnimationFrame(tick);
  }

  window.Vehicles = {
    init, follow, followTrip, stopFollow, set3d, is3d: () => threeD, scene: () => scene,
    setTerrain, terrain: () => ({ ...terrain }), dem: () => dem, decor: () => decor, rideSync, loadRoofs, roofs: () => roofs, facades: () => facades, rebuildFacades, setAmbient, ambient: () => ambient, traffic: () => traffic,
    infra: () => infra, rebuildInfra, refreshSched,
    setContext: (c) => { ctx = !!c; syncVisibility(); if (shown()) refresh(); }, setForce: (f) => { force = !!f; syncVisibility(); if (shown()) refresh(); },
    highlight: (ids) => { hi = new Set(ids || []); },
    stats: () => ({ total: V.size, withShape: [...V.values()].filter((x) => x.shape).length, on: shown(), threeD, zoom: map ? +map.getZoom().toFixed(1) : null, render: scene?.stats }),
    // exposed for tests
    _ingest: ingest, _attach: attachShape, _step: step, _V: V, _project: project, _build: buildShape, _red: (sh, j) => { wall = Date.now() / 1000; return redAt(sh, j); }, _model: modelFor, _livery: livery, _pose: (sh, s) => { poseAt(sh, s); return Array.from(pose); },
  };
})();
