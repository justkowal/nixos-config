"use strict";
// Procedural building facades for the 3D diorama:
//  - generates extruded wall quads around building footprint polygons with outward unit normals,
//    wall lengths, heights, and procedural UVs
//  - coordinates with the daylight cycle: windows randomly light up after sunset
//    and go almost fully dark after midnight
(() => {
  const area2 = (r) => {
    let a = 0;
    for (let i = 0; i < r.length; i++) {
      const p = r[i], q = r[(i + 1) % r.length];
      a += p[0] * q[1] - q[0] * p[1];
    }
    return a;
  };

  function toLocal(ring, anchor) {
    const ky = 111320, kx = 111320 * Math.cos((anchor.lat * Math.PI) / 180);
    const pts = ring.map(([lo, la]) => [(lo - anchor.lon) * kx, (la - anchor.lat) * ky]);
    if (pts.length > 1 && pts[0][0] === pts[pts.length - 1][0] && pts[0][1] === pts[pts.length - 1][1]) pts.pop();
    if (area2(pts) < 0) pts.reverse();  // ensure counter-clockwise winding so outward normal points away from interior
    return pts;
  }

  // Deterministic 3D pseudo-random hash for procedural window variation
  function hash3(seed, bay, floor) {
    const h = (x, y, z) => {
      const s = Math.sin(x * 12.9898 + y * 78.233 + z * 37.719) * 43758.5453;
      return s - Math.floor(s);
    };
    return [
      h(bay, floor, seed),
      h(floor + 19.3, bay + 7.1, seed + 31.7),
      h(bay + 43.7, floor + 53.1, seed + 89.2),
    ];
  }

  // Evaluates whether an individual window (bay, floor) of a building (seed) is lit at time `minute` (0..1440)
  // `sunTimes`: { sunrise: number, sunset: number, dusk: number, dawn: number } in minutes from midnight
  function windowLight(seed, bay, floor, minute, sunTimes = {}) {
    const sunset = sunTimes.sunset ?? 1110;   // default ~18:30
    const sunrise = sunTimes.sunrise ?? 360;  // default ~06:00
    const [r1, r2, r3] = hash3(seed, bay, floor);

    // 70% of windows are occupied/eligible to turn on in the evening
    if (r1 >= 0.70) return false;

    // Turn-on time: randomly distributed from sunset - 15 min to sunset + 75 min
    const tOn = sunset - 15 + r2 * 90;

    // Bedtime / turn-off time:
    //  - 25% turn off early: 22:00 to 23:00 (1320 to 1380 min)
    //  - 40% turn off late evening: 23:00 to 23:45 (1380 to 1425 min)
    //  - 28% turn off around midnight: 23:45 to 00:30 (1425 to 1470 min)
    //  - 7% night owls stay up later: 00:30 to 03:30 (1470 to 1650 min)
    let tOff;
    if (r3 < 0.25) {
      tOff = 1320 + (r3 / 0.25) * 60;
    } else if (r3 < 0.65) {
      tOff = 1380 + ((r3 - 0.25) / 0.40) * 45;
    } else if (r3 < 0.93) {
      tOff = 1425 + ((r3 - 0.65) / 0.28) * 45;
    } else {
      tOff = 1470 + ((r3 - 0.93) / 0.07) * 180;
    }
    tOff = Math.max(tOff, tOn + 30 + r3 * 60);

    // Normalize minute across midnight:
    // If minute < sunrise, it is past midnight (00:00 to sunrise), evaluated as minute + 1440
    const mEval = (minute < sunrise) ? (minute + 1440) : minute;

    // Outside the active evening/night period
    if (mEval < sunset - 15 || mEval >= sunrise + 1440) return false;

    return mEval >= tOn && mEval < tOff;
  }

  // Generates facade mesh for an array of GeoJSON building features
  function buildFacades(features, anchor, getGround = () => 0) {
    const polys = (g) => (g.type === "Polygon" ? [g.coordinates] : g.type === "MultiPolygon" ? g.coordinates : []);
    const seen = new Set();
    const v = [];
    const idx = [];

    for (const f of features) {
      if (!f || !f.geometry) continue;
      const rings = polys(f.geometry);
      for (const p of rings) {
        if (!p || !p[0] || p[0].length < 3) continue;
        const outer = p[0];
        const id = outer[0].join(",") + outer.length;
        if (seen.has(id)) continue;
        seen.add(id);

        const pts = toLocal(outer, anchor);
        const a = area2(pts);
        if (Math.abs(a) < 2) continue;  // skip slivers smaller than 1 m2

        // Height and levels
        const props = f.properties || {};
        const hVal = props.render_height || props.height || (props.levels ? props.levels * 3.2 : 9.0);
        const minVal = props.render_min_height || props.min_height || 0.0;
        const wallH = Math.max(1.5, hVal - minVal);

        // Building center for elevation sampling & seed
        let cx = 0, cy = 0;
        for (const pt of pts) { cx += pt[0]; cy += pt[1]; }
        cx /= pts.length; cy /= pts.length;
        const gz = getGround(cx, cy);
        const z0 = gz + minVal;
        const z1 = z0 + wallH;

        // Deterministic building seed and wall palette id (0..5)
        const seed = Math.abs(Math.sin(cx * 12.9898 + cy * 78.233) * 43758.5453) % 1000.0;
        const palId = Math.floor(Math.abs(cx * 3.7 + cy * 13.3) % 6);

        // Extrude each edge into a vertical wall quad
        const n = pts.length;
        for (let i = 0; i < n; i++) {
          const p0 = pts[i], p1 = pts[(i + 1) % n];
          const dx = p1[0] - p0[0], dy = p1[1] - p0[1];
          const len = Math.hypot(dx, dy);
          if (len < 0.8) continue;  // skip tiny wall notches

          // Outward normal in counter-clockwise winding: (dy / len, -dx / len)
          const nx = dy / len, ny = -dx / len;

          // Push wall slightly outward along normal (0.04m) to completely prevent Z-fighting with 3D vector tiles
          const off = 0.04;
          const x0 = p0[0] + nx * off, y0 = p0[1] + ny * off;
          const x1 = p1[0] + nx * off, y1 = p1[1] + ny * off;

          const base = v.length / 12;

          // Vertex format (stride 12 floats):
          //  pos: x, y, z (3)
          //  nrm: nx, ny, nz (3)
          //  uv:  u, v (2) -> distance along wall, height from base
          //  meta: wallL, wallH, seed, palId (4)
          v.push(
            x0, y0, z0, nx, ny, 0, 0, 0, len, wallH, seed, palId,
            x1, y1, z0, nx, ny, 0, len, 0, len, wallH, seed, palId,
            x1, y1, z1, nx, ny, 0, len, wallH, len, wallH, seed, palId,
            x0, y0, z1, nx, ny, 0, 0, wallH, len, wallH, seed, palId
          );

          // Counter-clockwise triangles seen from outside:
          // V0 (bottom-start) -> V1 (bottom-end) -> V2 (top-end)
          // V0 (bottom-start) -> V2 (top-end) -> V3 (top-start)
          idx.push(base, base + 1, base + 2, base, base + 2, base + 3);
        }
      }
    }

    const nVerts = v.length / 12;
    const nTris = idx.length / 3;
    if (!nVerts || !nTris) return null;

    const use32 = nVerts > 65535;
    return {
      vertex: new Float32Array(v),
      index: use32 ? new Uint32Array(idx) : new Uint16Array(idx),
      triangles: nTris,
      walls: idx.length / 6,
      count: nVerts,
    };
  }

  window.Facades = {
    area2,
    toLocal,
    hash3,
    windowLight,
    buildFacades,
  };
})();
