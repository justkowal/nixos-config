"use strict";
// Live vehicles in three levels of detail: heatmap far out, dots in the middle, painted 3D models up close.
// Positions arrive every few seconds, the animation runs every frame. Each vehicle is dead-reckoned along its trip shape
// with a speed controller that
//  - brakes for simulated red lights (signal nodes from OSM) and holds until green,
//  - docks at the platform when the feed says it is stopped at a stop,
//  - steers back toward the reported position: speeds up when behind, eases off when ahead, never reverses,
//  - and for a large mismatch glides over about a second instead of jumping.
(() => {
  const A = window.App;
  const { api, h, icon, $, store } = A;
  const T = () => performance.now() / 1000;

  const VMAX = { RAIL: 45, TRAM: 20, BUS: 22, TROLLEYBUS: 20, DEFAULT: 22 };
  const ACC = { RAIL: 0.8, TRAM: 1.0, BUS: 1.1, TROLLEYBUS: 1.1, DEFAULT: 1.1 };
  const FALLBACK = { RAIL: "#b3311f", BUS: "#1c5fb0", TRAM: "#a35a00", TROLLEYBUS: "#4d7c0f" };
  const GLASS = "#1b2430";
  const EXTRAP_MAX = 40, STALE_DIM = 240, STALE_DROP = 900, K_PULL = 0.3, RESYNC_M = 350, TELEPORT_M = 600, LIGHT_SLACK_M = 110;
  const Z_DOTS = 10.4, Z_HEAT_OUT = 11.8, Z_3D = 15;

  const V = new Map();        // vehicle id -> state
  const SHAPES = new Map();   // trip id -> shape info | "pending" | "none"
  let map = null, on = store.get("veh", true), threeD = store.get("3d", true), hi = new Set(), popup = null;
  let lastFrame = 0, followId = null, followBar = null, cam = null;

  // ---- shapes
  function buildShape(info) {
    const pts = A.decode(info.points);
    if (pts.length < 2) return null;
    const k = Math.cos((pts[0][1] * Math.PI) / 180) * 111320, ky = 110540;
    const X = pts.map((p) => p[0] * k), Y = pts.map((p) => p[1] * ky), cum = [0];
    for (let i = 1; i < pts.length; i++) cum.push(cum[i - 1] + Math.hypot(X[i] - X[i - 1], Y[i] - Y[i - 1]));
    return { pts, X, Y, cum, k, ky, length: cum[cum.length - 1], stops: info.stops || [], sig: info.sig || [] };
  }
  function rayFrom(lon, lat, headingDeg) {
    const r = (headingDeg * Math.PI) / 180, k = Math.cos((lat * Math.PI) / 180) * 111320, ky = 110540;
    const pts = [[lon, lat], [lon + (Math.sin(r) * 6000) / k, lat + (Math.cos(r) * 6000) / ky]];
    const X = pts.map((p) => p[0] * k), Y = pts.map((p) => p[1] * ky), len = Math.hypot(X[1] - X[0], Y[1] - Y[0]);
    return { pts, X, Y, cum: [0, len], k, ky, length: len, stops: [], sig: [], ray: true };
  }
  function locate(sh, s) {  // segment index containing distance s
    let a = 0, b = sh.cum.length - 1;
    while (b - a > 1) { const m = (a + b) >> 1; if (sh.cum[m] <= s) a = m; else b = m; }
    return a;
  }
  function project(sh, lon, lat, near, win = 500) {
    const x = lon * sh.k, y = lat * sh.ky;
    const scan = (lo, hi2) => {
      let best = null;
      for (let i = lo; i <= hi2; i++) {
        const dx = sh.X[i + 1] - sh.X[i], dy = sh.Y[i + 1] - sh.Y[i], l2 = dx * dx + dy * dy;
        const t = l2 ? Math.max(0, Math.min(1, ((x - sh.X[i]) * dx + (y - sh.Y[i]) * dy) / l2)) : 0;
        const d = Math.hypot(x - (sh.X[i] + t * dx), y - (sh.Y[i] + t * dy));
        if (!best || d < best.d) best = { d, s: sh.cum[i] + t * Math.sqrt(l2) };
      }
      return best;
    };
    const last = sh.pts.length - 2;
    let best = near != null ? scan(Math.max(0, locate(sh, near - win)), Math.min(last, locate(sh, near + win))) : null;
    if (!best || best.d > 150) best = scan(0, last);  // lost the thread: search everything once
    return best;
  }
  function pointAt(sh, s) {
    s = Math.max(0, Math.min(sh.length, s));
    const i = Math.min(locate(sh, s), sh.pts.length - 2), seg = sh.cum[i + 1] - sh.cum[i] || 1, t = (s - sh.cum[i]) / seg;
    const lon = sh.pts[i][0] + (sh.pts[i + 1][0] - sh.pts[i][0]) * t, lat = sh.pts[i][1] + (sh.pts[i + 1][1] - sh.pts[i][1]) * t;
    const hd = (Math.atan2(sh.X[i + 1] - sh.X[i], sh.Y[i + 1] - sh.Y[i]) * 180) / Math.PI;
    return { lon, lat, hd: (hd + 360) % 360 };
  }

  // ---- traffic light model: deterministic per junction, so every frame and every client agrees
  function hash(n) { n = Math.imul(n ^ (n >>> 16), 0x45d9f3b); n = Math.imul(n ^ (n >>> 16), 0x45d9f3b); return ((n ^ (n >>> 16)) >>> 0) / 4294967296; }
  function red(trip, sigAlong) {
    const id = Math.round(sigAlong) * 31 + trip.length;
    const cycle = 70 + hash(id) * 50, phase = (Date.now() / 1000 + hash(id + 7) * cycle) % cycle;
    return phase < cycle * 0.42;
  }

  // ---- vehicle state
  function newVehicle(r, now) {
    return { id: r.id, s: 0, vel: 0, sRep: 0, vRep: 0, tRep: -1e9, shape: null, ray: null, h: r.hd ?? 0, fade: 0, lon: r.lon, lat: r.lat, seen: now, model: null };
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
        if (v.rayHd != null) { v.ray = rayFrom(r.lon, r.lat, v.rayHd); v.s = 0; v.sRep = 0; }
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
      if (first) { v.s = v.sRep + v.vRep * Math.min(ageAtArrival, EXTRAP_MAX); v.vel = v.vRep; }
    }
    for (const [id, v] of V) if (now - v.seen > STALE_DROP) V.delete(id);
  }
  function attachShape(v, info) {
    const sh = buildShape(info);
    if (!sh) return;
    // continuity: project where the vehicle is drawn now onto the real shape
    const cur = v.ray ? pointAt(v.ray, v.s) : { lon: v.lon, lat: v.lat };
    const pc = project(sh, cur.lon, cur.lat, null), pr = project(sh, v.lon, v.lat, null);
    v.shape = sh; v.ray = null;
    if (pr) { v.sRep = pr.s; v.s = pc ? pc.s : pr.s; }
  }

  function step(v, dt, now) {
    const sh = v.shape || v.ray;
    if (!sh) return null;
    const age = now - v.tRep, stale = age > STALE_DIM, vmax = VMAX[v.mode] || 22;
    let sTarget = v.sRep + v.vRep * Math.min(age, EXTRAP_MAX), vDes = stale ? 0 : v.vRep;
    if (v.st === "STOPPED_AT" && v.sn && v.shape) {  // docked: sit at the stop the feed names
      const stop = v.shape.stops.find((x) => x.n === v.sn && Math.abs(x.a - v.sRep) < 80);
      if (stop) { sTarget = stop.a; vDes = 0; }
    }
    if (stale) sTarget = v.s;  // no news for a long time: come to rest where we are instead of coasting on an old guess
    const e = sTarget - v.s;
    let vCmd = Math.max(0, Math.min(vDes + K_PULL * e, Math.max(vDes * 1.7, vDes + 6), vmax));
    let hard = false;
    if (Math.abs(e) > TELEPORT_M) {  // far apart: fade out, jump, fade in
      v.fade = Math.min(1, v.fade + dt * 5);
      if (v.fade >= 1) { v.s = Math.max(0, Math.min(sh.length, sTarget)); v.vel = vDes; }
    } else if (e > RESYNC_M) { v.s += Math.min(e * (1 - Math.exp(-dt / 1.1)), 90 * dt); v.fade = Math.min(0.4, v.fade + dt); }  // behind by a few hundred metres: a quick glide
    else v.fade = Math.max(0, v.fade - dt * 2.5);
    // simulated lights, only while we are not already behind reality, so a stop never becomes a permanent lag
    if (v.shape && v.shape.sig.length && e < LIGHT_SLACK_M && vDes > 2 && !stale) {
      for (const a of v.shape.sig) {
        const d = a - v.s;
        if (d < -2) continue;
        if (d > 90) break;
        if (red(v.trip || "", a)) { const cap = Math.sqrt(2 * 1.6 * Math.max(0, d - 4)); vCmd = Math.min(vCmd, cap); hard = d < 40 && v.vel > 1.5 * cap; }
        break;
      }
    }
    v.vel += Math.max(-(hard ? 3.2 : 1.4) * dt, Math.min((ACC[v.mode] || 1.1) * dt, vCmd - v.vel));
    v.s = Math.min(sh.length, Math.max(v.s, v.s + v.vel * dt));
    const ahead = pointAt(sh, v.s + 6);
    v.h = (v.h + (((ahead.hd - v.h + 540) % 360) - 180) * (1 - Math.exp(-dt / 0.22)) + 360) % 360;
    return { alpha: (stale ? 0.45 : 1) * (1 - 0.9 * v.fade) };
  }

  // ---- vehicle models: stacked prisms painted in the carrier's livery. Trams and trains are articulated: each car sits on the track at its own distance.
  function livery(v) {
    const p = A.providerOf(v.ag), L = p?.livery && (p.livery[v.mode] || p.livery.default);
    return { body: L?.body || v.color, stripe: L?.stripe || "#ffffff", roof: L?.roof || "#d4d8de", skirt: L?.skirt || "#2a2f36" };
  }
  function carParts(c, L, o) {  // o: {front, rear, bus, loco, pan}
    const { len, wid, h: ht } = c, out = [];
    const part = (off, plen, pwid, b, t, col) => out.push({ off, len: plen, wid: pwid, b, t, col });
    part(0, len * 0.96, wid - 0.2, 0.25, 0.95, L.skirt);
    part(0, len, wid, 0.95, ht - 0.28, o.loco ? L.stripe : L.body);
    part(0, len, wid + 0.05, 0.95, 1.45, o.loco ? L.body : L.stripe);
    if (!o.loco) part(0, len - 1.5, wid + 0.1, 1.65, ht - 0.75, GLASS);
    part(0, len - 0.5, wid - 0.35, ht - 0.28, ht, L.roof);
    if (o.bus) part(-1, 3.2, 1.6, ht, ht + 0.35, L.roof);
    if (o.pan) part(0, 1.5, 0.9, ht, ht + 0.5, "#2c3138");
    if (o.front) part(len / 2 - 0.17, 0.5, wid - 0.5, 1.3, ht - 0.6, GLASS);
    if (o.rear) part(-(len / 2 - 0.17), 0.5, wid - 0.7, 1.4, ht - 0.7, "#2b3440");
    return out;
  }
  function modelOf(v) {
    if (v.model) return v.model;
    const L = livery(v), ic = /Intercity/i.test(v.ag || "");
    let cars, gap = 0, bell = false;
    if (v.mode === "TRAM") { cars = [8.6, 8.6, 8.6].map((len) => ({ len, wid: 2.4, h: 3.5 })); gap = 0.9; bell = true; }
    else if (v.mode === "RAIL") {
      if (ic) { cars = [{ len: 24, wid: 3, h: 4.2 }, { len: 24, wid: 3, h: 4.2 }, { len: 18, wid: 3, h: 4.3, loco: true }]; gap = 0.8; }
      else { cars = [20, 20, 20].map((len) => ({ len, wid: 2.9, h: 4.1 })); gap = 1.0; bell = true; }
    } else if (v.mode === "BUS" || v.mode === "TROLLEYBUS") cars = [{ len: 12, wid: 2.5, h: 3.1, bus: true }];
    else cars = [{ len: 10, wid: 2.4, h: 3.0, bus: true }];
    const total = cars.reduce((a, c) => a + c.len, 0) + gap * (cars.length - 1);
    let pos = -total / 2;
    const out = [];
    cars.forEach((c, i) => {
      const centre = pos + c.len / 2;
      out.push({ c: centre, bend: cars.length > 1, parts: carParts(c, L, { front: i === cars.length - 1, rear: i === 0, bus: c.bus, loco: c.loco, pan: (v.mode === "TRAM" || (v.mode === "RAIL" && !ic)) && i === 1 }) });
      pos += c.len;
      if (i < cars.length - 1) {
        if (bell) out.push({ c: pos + gap / 2, bend: true, parts: [{ off: 0, len: gap + 0.3, wid: cars[i].wid - 0.45, b: 0.95, t: cars[i].h - 0.5, col: "#262b33" }] });
        pos += gap;
      }
    });
    v.model = { cars: out, total };
    return v.model;
  }

  // ---- drawing
  const hex = (c) => [1, 3, 5].map((i) => parseInt(c.slice(i, i + 2), 16));
  function mix(c, bg, a) {  // blend toward the background: extrusions cannot take per-feature opacity
    if (a >= 0.99) return c;
    const x = hex(c), y = hex(bg);
    return "#" + x.map((v, i) => Math.round(v * a + y[i] * (1 - a)).toString(16).padStart(2, "0")).join("");
  }
  function rect(lon, lat, hdDeg, len, wid, off) {
    const r = (hdDeg * Math.PI) / 180, kx = Math.cos((lat * Math.PI) / 180) * 111320, ky = 110540;
    const fx = Math.sin(r), fy = Math.cos(r), sx = fy, sy = -fx, hl = len / 2, hw = wid / 2;
    const c = (a, b) => [lon + (fx * (a + off) + sx * b) / kx, lat + (fy * (a + off) + sy * b) / ky];
    return [c(hl, hw), c(hl, -hw), c(-hl, -hw), c(-hl, hw), c(hl, hw)];
  }
  function draw(dt, now) {
    if (!map || !map.getSource("veh-dots")) return;
    const b = map.getBounds().toArray(), pad = 0.01, z = map.getZoom(), routeOn = hi.size > 0;
    const dots = [], solids = [];
    const bgHex = (getComputedStyle(document.documentElement).getPropertyValue("--surface-3").trim() || "#dddddd");
    let nearby = 0, followed = null;
    for (const v of V.values()) {
      const st = step(v, dt, now) || { alpha: 0.7 };  // no shape yet: a still dot at the last reported position
      const sh = v.shape || v.ray, p = sh ? pointAt(sh, v.s) : { lon: v.lon, lat: v.lat };
      if (p.lon < b[0][0] - pad || p.lon > b[1][0] + pad || p.lat < b[0][1] - pad || p.lat > b[1][1] + pad) continue;
      const mine = hi.has(v.trip) || v.id === followId, alpha = st.alpha * (routeOn && !mine ? 0.35 : 1);
      dots.push({ type: "Feature", properties: { c: v.color, l: v.line || "", a: alpha, hi: mine ? 1 : 0, v: v.id }, geometry: { type: "Point", coordinates: [p.lon, p.lat] } });
      if (v.id === followId) followed = { lon: p.lon, lat: p.lat, hd: v.h, v };
      if (sh && z >= Z_3D && nearby < 140) {
        nearby++;
        const m = modelOf(v);
        for (const car of m.cars) {
          const cp = car.bend ? pointAt(sh, v.s + car.c) : p, hd = car.bend ? cp.hd : v.h, lon = car.bend ? cp.lon : p.lon, lat = car.bend ? cp.lat : p.lat;
          for (const part of car.parts) {
            solids.push({ type: "Feature", properties: { c: mix(part.col, bgHex, alpha), b: part.b, t: part.t, v: v.id }, geometry: { type: "Polygon", coordinates: [rect(lon, lat, hd, part.len, part.wid, part.off + (car.bend ? 0 : car.c))] } });
          }
        }
      }
    }
    map.getSource("veh-dots").setData({ type: "FeatureCollection", features: dots });
    map.getSource("veh-3d").setData({ type: "FeatureCollection", features: solids });
    if (followId) chase(followed, dt);
  }
  // chase camera: glides to the vehicle, and in 3D turns to look along its direction of travel
  function chase(f, dt) {
    if (!f) { if (followBar) $("#follow-status").textContent = "No position for this vehicle right now"; return; }
    const k = 1 - Math.exp(-dt / 0.4), c = map.getCenter();
    cam = cam || { lon: c.lng, lat: c.lat, zoom: map.getZoom(), target: Math.max(map.getZoom(), 17.8) };
    cam.lon += (f.lon - cam.lon) * k; cam.lat += (f.lat - cam.lat) * k;
    if (cam.free) cam.zoom = map.getZoom();  // the user took over the zoom
    else cam.zoom += (cam.target - cam.zoom) * (1 - Math.exp(-dt / 0.6));
    const opts = { center: [cam.lon, cam.lat], zoom: cam.zoom, animate: false };
    if (threeD) { const b = map.getBearing(); opts.bearing = b + (((f.hd - b + 540) % 360) - 180) * (1 - Math.exp(-dt / 0.8)); }
    map.jumpTo(opts);
    const v = f.v;
    $("#follow-status").textContent = v.st === "STOPPED_AT" ? `At ${v.sn || "a stop"}` : v.sn ? `Next stop: ${v.sn}` : v.vel > 0.5 ? "Moving" : "Standing";
  }
  function showBar(v) {
    if (!followBar) {
      followBar = h("section", { id: "follow", class: "follow glass", "aria-label": "Following a vehicle" },
        h("div", { class: "f-main" }, h("div", { id: "follow-title", class: "f-title" }), h("div", { id: "follow-sub", class: "f-sub" }), h("div", { id: "follow-status", class: "f-status", role: "status", "aria-live": "polite" })),
        h("button", { class: "chip", id: "follow-stop", onclick: () => stopFollow() }, "Stop"));
      document.body.append(followBar);
    }
    followBar.hidden = false;
    const t = $("#follow-title");
    t.replaceChildren(A.badge(v.line || "?", v.color, v.mode), v.to ? ` to ${v.to}` : "");
    $("#follow-sub").textContent = A.providerOf(v.ag)?.name || v.ag || "";
  }
  function follow(id) {
    const v = V.get(id);
    if (!v) return false;
    followId = id; cam = null; on = true; syncVisibility();
    showBar(v);
    ensureShape(v);
    return true;
  }
  function stopFollow() {
    followId = null; cam = null;
    if (followBar) followBar.hidden = true;
    map.easeTo({ bearing: threeD ? map.getBearing() : 0, duration: 400 });
  }
  function ensureShape(v) {
    if (v.shape || !v.trip) return;
    const known = SHAPES.get(v.trip);
    if (known && known.points) return attachShape(v, known);
    if (known === "pending") return;
    SHAPES.set(v.trip, "pending");
    api("shape", { trip: v.trip }).then((info) => { SHAPES.set(v.trip, info); for (const o of V.values()) if (o.trip === v.trip && !o.shape) attachShape(o, info); }).catch(() => SHAPES.set(v.trip, { fail: T() }));
  }
  // from a trip leg or a departure: find the vehicle on that trip, wherever it is, and follow it
  async function followTrip(trip) {
    if (!map || !trip) return false;
    let v = [...V.values()].find((x) => x.trip === trip);
    if (!v) {
      try { const r = await api("vehicles", { trip }); ingest(r.vehicles, r.now); } catch { return false; }
      v = [...V.values()].find((x) => x.trip === trip);
    }
    return v ? follow(v.id) : false;
  }
  function loop() {
    requestAnimationFrame(loop);
    const t = performance.now();
    if (!on || !map || document.hidden || map.getZoom() < Z_DOTS || t - lastFrame < (map.getZoom() >= Z_3D ? 30 : 60)) return;
    const dt = Math.min(0.25, (t - lastFrame) / 1000);
    lastFrame = t;
    draw(dt, T());
  }

  // ---- map layers (re-added after every style change)
  function layers() {
    const css = (n, d) => getComputedStyle(document.documentElement).getPropertyValue(n).trim() || d;
    if (!map.getSource("veh-dots")) {
      for (const id of ["veh-dots", "veh-3d", "veh-heat"]) map.addSource(id, { type: "geojson", data: { type: "FeatureCollection", features: [] } });
    }
    const labelFont = (map.getStyle().layers.find((l) => l.layout && l.layout["text-font"]) || { layout: {} }).layout["text-font"] || ["Noto Sans Regular"];
    const firstSymbol = (map.getStyle().layers.find((l) => l.type === "symbol") || {}).id;
    if (!map.getLayer("buildings-3d") && map.getSource("openmaptiles")) {
      map.addLayer({ id: "buildings-3d", type: "fill-extrusion", source: "openmaptiles", "source-layer": "building", minzoom: 14,
        paint: { "fill-extrusion-color": css("--surface-3", "#ddd"), "fill-extrusion-height": ["coalesce", ["get", "render_height"], 6], "fill-extrusion-base": ["coalesce", ["get", "render_min_height"], 0], "fill-extrusion-opacity": 0.88, "fill-extrusion-vertical-gradient": true } }, firstSymbol);
    }
    const add = (l) => { if (!map.getLayer(l.id)) map.addLayer(l); };
    const accent = css("--accent", "#0b6e5c");
    add({ id: "veh-heat", type: "heatmap", source: "veh-heat", maxzoom: Z_HEAT_OUT, paint: {
      "heatmap-weight": 1, "heatmap-intensity": ["interpolate", ["linear"], ["zoom"], 6, 0.12, 9, 0.35, 11, 0.9], "heatmap-radius": ["interpolate", ["linear"], ["zoom"], 6, 6, 11, 18],
      "heatmap-color": ["interpolate", ["linear"], ["heatmap-density"], 0, "rgba(0,0,0,0)", 0.15, "rgba(60,150,170,0.35)", 0.45, accent, 0.75, "#e0a100", 1, "#c62828"],
      "heatmap-opacity": ["interpolate", ["linear"], ["zoom"], 10.4, 0.9, Z_HEAT_OUT, 0] } });
    add({ id: "veh-3d-body", type: "fill-extrusion", source: "veh-3d", minzoom: Z_3D, paint: { "fill-extrusion-color": ["get", "c"], "fill-extrusion-height": ["get", "t"], "fill-extrusion-base": ["get", "b"], "fill-extrusion-opacity": 0.97, "fill-extrusion-vertical-gradient": true } });
    add({ id: "veh-halo", type: "circle", source: "veh-dots", filter: ["==", ["get", "hi"], 1], paint: { "circle-radius": ["interpolate", ["linear"], ["zoom"], 9, 9, 16, 18], "circle-color": "rgba(0,0,0,0)", "circle-stroke-color": ["get", "c"], "circle-stroke-width": 3, "circle-stroke-opacity": 0.9 } });
    const fade = ["interpolate", ["linear"], ["zoom"], Z_DOTS, 0, 11.2, ["get", "a"], 16.2, ["get", "a"], 17, 0];
    add({ id: "veh-dot", type: "circle", source: "veh-dots", paint: { "circle-radius": ["interpolate", ["linear"], ["zoom"], 9, 3.5, 13, 6, 16, 9], "circle-color": ["get", "c"], "circle-stroke-color": "#ffffff", "circle-stroke-width": 2,
      "circle-opacity": fade, "circle-stroke-opacity": fade } });
    add({ id: "veh-label", type: "symbol", source: "veh-dots", minzoom: 13.2, layout: { "text-field": ["get", "l"], "text-font": labelFont, "text-size": 11, "text-offset": [0, -1.5], "text-optional": true },
      paint: { "text-color": css("--ink", "#111"), "text-halo-color": css("--surface", "#fff"), "text-halo-width": 1.6, "text-opacity": ["get", "a"] } });
    syncVisibility();
  }
  function syncVisibility() {
    if (!map) return;
    for (const id of ["veh-heat", "veh-3d-body", "veh-halo", "veh-dot", "veh-label"]) if (map.getLayer(id)) map.setLayoutProperty(id, "visibility", on ? "visible" : "none");
    if (map.getLayer("buildings-3d")) map.setLayoutProperty("buildings-3d", "visibility", threeD ? "visible" : "none");
  }

  // ---- data
  let fetching = false;
  async function refresh() {
    if (!on || !map || document.hidden || fetching) return;
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
          SHAPES.set(v.trip, "pending"); budget--;
          api("shape", { trip: v.trip }).then((info) => { SHAPES.set(v.trip, info); for (const o of V.values()) if (o.trip === v.trip && !o.shape) attachShape(o, info); }).catch(() => SHAPES.set(v.trip, { fail: T() }));
        }
      }
    } catch { /* keep animating what we have */ } finally { fetching = false; }
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
    if (v) { map.dragRotate.enable(); map.touchPitch.enable(); map.touchZoomRotate.enableRotation(); map.easeTo({ pitch: 58, duration: 600 }); }
    else { map.easeTo({ pitch: 0, bearing: 0, duration: 500 }); map.dragRotate.disable(); map.touchPitch.disable(); map.touchZoomRotate.disableRotation(); }
    syncVisibility();
  }
  function onClick(e) {
    const f = e.features && e.features[0];
    if (f && f.properties.v) follow(f.properties.v);
  }
  function init(m) {
    map = m;
    controls();
    map.on("style.load", layers);
    if (map.isStyleLoaded()) layers();
    for (const layer of ["veh-dot", "veh-3d-body"]) {
      map.on("click", layer, onClick);
      map.on("mouseenter", layer, () => (map.getCanvas().style.cursor = "pointer"));
      map.on("mouseleave", layer, () => (map.getCanvas().style.cursor = ""));
    }
    map.on("dragstart", (e) => { if (followId && e.originalEvent) stopFollow(); });
    map.on("zoomstart", (e) => { if (followId && cam && e.originalEvent) cam.free = true; });
    let deb = 0;
    map.on("moveend", () => { clearTimeout(deb); deb = setTimeout(refresh, 400); });
    setInterval(refresh, 5000);
    map.touchPitch?.disable();
    if (threeD) set3d(true);
    refresh();
    requestAnimationFrame(loop);
  }

  window.Vehicles = {
    init, follow, followTrip, stopFollow, highlight: (ids) => { hi = new Set(ids || []); }, is3d: () => threeD,
    // exposed for tests
    stats: () => ({ total: V.size, withShape: [...V.values()].filter((x) => x.shape).length, on, threeD, zoom: map ? +map.getZoom().toFixed(1) : null }),
    _ingest: ingest, _attach: attachShape, _step: step, _V: V, _project: project, _build: buildShape, _pointAt: pointAt, _red: red, _model: modelOf, _livery: livery,
  };
})();
