"use strict";
// Ambient traffic for the diorama: lanes are taken from the vector-tile road network, density follows road class and time of day,
// and vehicles follow each other with the Intelligent Driver Model so they queue and never overlap.
(() => {
  const TAU = Math.PI * 2;
  const mercX = (lon) => (lon + 180) / 360;
  const mercY = (lat) => 0.5 - Math.log(Math.tan(Math.PI / 4 + (lat * Math.PI) / 360)) / TAU;
  const mPerMerc = (lat) => 40075016.686 * Math.cos((lat * Math.PI) / 180);

  // vehicles per km per direction at the daily peak, free speed m/s, lateral offset of the lane centre
  const CLASSES = {
    motorway: { dens: 22, v0: 25, off: 1.9 }, trunk: { dens: 16, v0: 19, off: 1.9 }, primary: { dens: 13, v0: 13.5, off: 1.8 },
    secondary: { dens: 9.5, v0: 12, off: 1.7 }, tertiary: { dens: 6.5, v0: 11, off: 1.6 }, minor: { dens: 3.2, v0: 8.5, off: 1.5 },
    residential: { dens: 3.2, v0: 8.5, off: 1.5 }, service: { dens: 0.8, v0: 4.5, off: 1.2 },
  };
  const ALIAS = { motorway_link: "motorway", trunk_link: "trunk", primary_link: "primary", secondary_link: "secondary", tertiary_link: "tertiary", street: "minor", living_street: "service", track: null };
  const roadClass = (c) => (c in ALIAS ? ALIAS[c] : c in CLASSES ? c : null);

  const bump = (h, mu, sd) => Math.exp(-0.5 * ((h - mu) / sd) ** 2);
  // 0..1 share of the peak flow at an hour of the day: two rush hours, a midday plateau and a quiet night
  function timeFactor(hour) {
    const h = ((hour % 24) + 24) % 24;
    return Math.min(1, 0.07 + 0.93 * Math.max(bump(h, 7.9, 1.2), bump(h, 16.6, 1.6), 0.55 * bump(h, 12.5, 3.6), 0.4 * bump(h, 20, 1.8)));
  }
  const DENSITY_SCALE = 1.6;  // a diorama should look busy; real flows are lower than what reads as life on screen
  const density = (cls, hour) => DENSITY_SCALE * CLASSES[cls].dens * timeFactor(hour);                           // veh/km/direction
  // peak flow slows traffic a little
  const freeSpeed = (cls, hour) => CLASSES[cls].v0 * (1 - 0.28 * timeFactor(hour));

  // [type, weight]; heavy vehicles are rare on small streets and common on trunk roads
  function pickType(r, cls) {
    const big = cls === "motorway" || cls === "trunk" ? 2.2 : cls === "primary" ? 1 : cls === "service" ? 0.3 : 0.5;
    const w = [["hatch", 34], ["sedan", 27], ["suv", 20], ["van", 9 * big], ["truck", 5 * big]];
    let t = 0; for (const x of w) t += x[1];
    r *= t; for (const x of w) { if ((r -= x[1]) <= 0) return x[0]; }
    return "sedan";
  }
  const LENGTH = { hatch: 4.0, sedan: 4.75, suv: 4.7, van: 5.4, truck: 9.0 };

  // ---- lanes
  // local metres east (x) and north (y) from an anchor; each way becomes one lane per direction, shifted to the right of travel
  function makeLane(pts, anchor, cls, key) {
    const n = pts.length, X = new Float64Array(n), Y = new Float64Array(n), cum = new Float64Array(n), off = CLASSES[cls].off;
    const ky = 111320;
    const kxm = 111320 * Math.cos((anchor.lat * Math.PI) / 180);
    for (let i = 0; i < n; i++) { X[i] = (pts[i][0] - anchor.lon) * kxm; Y[i] = (pts[i][1] - anchor.lat) * ky; }
    const ox = new Float64Array(n), oy = new Float64Array(n);
    for (let i = 0; i < n; i++) {
      const a = Math.max(0, i - 1), b = Math.min(n - 1, i + 1);
      let dx = X[b] - X[a], dy = Y[b] - Y[a]; const l = Math.hypot(dx, dy) || 1; dx /= l; dy /= l;
      ox[i] = X[i] + dy * off; oy[i] = Y[i] - dx * off;  // right-hand traffic
    }
    for (let i = 1; i < n; i++) cum[i] = cum[i - 1] + Math.hypot(ox[i] - ox[i - 1], oy[i] - oy[i - 1]);
    return { key, cls, off, X: ox, Y: oy, cum, len: cum[n - 1], veh: [], acc: 0, seg: 0 };
  }
  function lanesFromFeatures(features, anchor) {
    const out = [], seen = new Set();
    for (const f of features) {
      const p = f.properties || {}, cls = roadClass(p.class);
      if (!cls || p.brunnel === "tunnel" || p.service === "parking_aisle" || p.service === "driveway") continue;
      const g = f.geometry, lines = g.type === "LineString" ? [g.coordinates] : g.type === "MultiLineString" ? g.coordinates : [];
      for (const line of lines) {
        if (line.length < 2) continue;
        const a = line[0], b = line[line.length - 1], id = [a[0].toFixed(5), a[1].toFixed(5), b[0].toFixed(5), b[1].toFixed(5), line.length].join(",");
        if (seen.has(id)) continue;
        seen.add(id);
        const oneway = p.oneway === 1 || p.oneway === "1" || p.oneway === true || p.class === "motorway";
        const fwd = makeLane(line, anchor, cls, id + ">");
        if (fwd.len >= 12) out.push(fwd);
        if (!(oneway)) { const back = makeLane(line.slice().reverse(), anchor, cls, id + "<"); if (back.len >= 12) out.push(back); }
      }
    }
    return out;
  }

  // ---- car following
  const IDM = { a: 1.6, b: 2.2, T: 1.4, s0: 2.2, delta: 4 };
  function idm(v, v0, gap, dv) {
    const sStar = IDM.s0 + Math.max(0, v * IDM.T + (v * dv) / (2 * Math.sqrt(IDM.a * IDM.b)));
    return IDM.a * (1 - Math.pow(v / v0, IDM.delta) - (sStar / Math.max(gap, 0.1)) ** 2);
  }

  // rng is injectable for tests
  class Traffic {
    constructor(rng = Math.random) { this.rng = rng; this.lanes = new Map(); this.anchor = { lon: 0, lat: 0, mx: 0, my: 0 }; this.hour = 12; this.n = 0; this.max = 900; this.serial = 0; }
    setHour(h) { this.hour = h; }
    // replace the road network, keeping vehicles on lanes that survive
    setLanes(lanes, anchor) {
      const next = new Map();
      for (const l of lanes) {
        const old = this.lanes.get(l.key);
        if (old && this.sameAnchor(anchor)) { next.set(l.key, old); continue; }
        next.set(l.key, l); this.populate(l);
      }
      this.anchor = { ...anchor, mx: mercX(anchor.lon), my: mercY(anchor.lat), k: 1 / mPerMerc(anchor.lat) };
      this.lanes = next; this.recount();
    }
    sameAnchor(a) { return a.lon === this.anchor.lon && a.lat === this.anchor.lat; }
    recount() { let n = 0; for (const l of this.lanes.values()) n += l.veh.length; this.n = n; }
    newVehicle(lane, s, v) {
      const type = pickType(this.rng(), lane.cls), id = "t" + this.serial++;
      return { s, v, type, len: LENGTH[type], v0f: 0.85 + this.rng() * 0.3, tint: window.Fleet ? window.Fleet.randomColor(id) : [128, 128, 128], fade: 0 };
    }
    // steady state: roughly the right number of vehicles at believable gaps
    populate(l) {
      const target = Math.round((density(l.cls, this.hour) * l.len) / 1000), v0 = freeSpeed(l.cls, this.hour);
      const slots = []; for (let i = 0; i < target; i++) slots.push(this.rng() * l.len);
      slots.sort((a, b) => b - a);
      let lastS = Infinity;
      for (const s of slots) { if (lastS - s < 9) continue; l.veh.push(this.newVehicle(l, s, v0 * 0.8)); lastS = s; }
    }
    // front of the array is the vehicle furthest ahead
    step(dt) {
      let total = 0;
      for (const l of this.lanes.values()) {
        const veh = l.veh, vFree = freeSpeed(l.cls, this.hour);
        for (let i = 0; i < veh.length; i++) {
          const c = veh[i], lead = i > 0 ? veh[i - 1] : null;
          const gap = lead ? lead.s - lead.len - c.s : 1e3, dv = lead ? c.v - lead.v : 0;
          let a = idm(c.v, vFree * c.v0f, gap, dv);
          if (a < -9) a = -9;
          c.v = Math.max(0, c.v + a * dt);
          c.s += c.v * dt;
          if (lead && c.s > lead.s - lead.len - 0.3) { c.s = lead.s - lead.len - 0.3; c.v = Math.min(c.v, lead.v); }  // hard stop: never overlap
        }
        while (veh.length && veh[0].s > l.len) veh.shift();
        // inflow at the start of the lane
        l.acc += (density(l.cls, this.hour) * vFree * dt) / 1000;
        if (l.acc >= 1 && this.n < this.max) {
          const last = veh[veh.length - 1];
          if (!last || last.s - last.len > IDM.s0 + 3) { veh.push(this.newVehicle(l, 0, vFree * 0.7)); l.acc -= 1; this.n++; } else l.acc = Math.min(l.acc, 1);
        } else if (l.acc >= 1) l.acc = 1;
        total += veh.length;
      }
      this.n = total;
    }
    // calls emit(type, dx, dy, fx, fy, alpha, tint) in metres relative to the frame origin (mercator ox, oy, metre size k); bounds in mercator
    write(ox, oy, k, x0, x1, y0, y1, emit) {
      const A = this.anchor, kA = A.k;
      for (const l of this.lanes.values()) {
        const X = l.X, Y = l.Y, cum = l.cum;
        let seg = 0;
        for (let i = l.veh.length - 1; i >= 0; i--) {  // ascending s, so one forward pass over the segments
          const c = l.veh[i], s = Math.min(c.s, l.len);
          while (seg < X.length - 2 && cum[seg + 1] < s) seg++;
          const d = cum[seg + 1] - cum[seg] || 1, t = (s - cum[seg]) / d, ux = (X[seg + 1] - X[seg]) / d, uy = (Y[seg + 1] - Y[seg]) / d;
          const px = X[seg] + (X[seg + 1] - X[seg]) * t - ux * c.len * 0.5, py = Y[seg] + (Y[seg + 1] - Y[seg]) * t - uy * c.len * 0.5;  // s is the front bumper
          const mx = A.mx + px * kA, my = A.my - py * kA;
          if (mx < x0 || mx > x1 || my < y0 || my > y1) continue;
          const edge = Math.min(s, l.len - s), alpha = edge < 12 ? Math.max(0, edge / 12) : 1;  // fade in and out at lane ends
          if (alpha <= 0.02) continue;
          emit(c.type, (mx - ox) / k, (oy - my) / k, ux, uy, alpha, c.tint, c.len);
        }
      }
    }
  }

  window.Traffic = { Traffic, CLASSES, timeFactor, density, freeSpeed, lanesFromFeatures, idm, roadClass, pickType };
})();
