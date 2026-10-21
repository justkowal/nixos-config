"use strict";
// Ground elevation for the 3D scene, from the same Terrarium tiles MapLibre drapes the map with, so everything we draw sits on the surface it sees.
// Terrarium encodes metres as R * 256 + G + B / 256 - 32768. Tiles load lazily; until one arrives a sample is 0 and the tile is requested.
(() => {
  const TS = 256;
  const decode = (rgba) => {
    const out = new Float32Array(TS * TS);
    for (let i = 0; i < TS * TS; i++) out[i] = rgba[i * 4] * 256 + rgba[i * 4 + 1] + rgba[i * 4 + 2] / 256 - 32768;
    return out;
  };

  class Dem {
    // fetchTile(z, x, y) -> Promise<Uint8ClampedArray | null> with 256 x 256 RGBA
    constructor({ fetchTile, zoom = 14, onload = () => {} }) {
      this.fetchTile = fetchTile; this.z = zoom; this.n = 2 ** zoom; this.onload = onload;
      this.tiles = new Map(); this.exaggeration = 1; this.last = null; this.loading = 0; this.failed = new Map();
    }
    key(x, y) { return x * 100000 + y; }
    tile(x, y, request = true) {
      if (x < 0) x += this.n; else if (x >= this.n) x -= this.n;
      if (y < 0 || y >= this.n) return null;
      const k = this.key(x, y), t = this.tiles.get(k);
      if (t) return t.data;
      if (request && !this.failed.has(k) && this.loading < 6) this.request(x, y, k);
      return null;
    }
    request(x, y, k) {
      this.tiles.set(k, { data: null });
      this.loading++;
      Promise.resolve(this.fetchTile(this.z, x, y)).then((rgba) => {
        if (rgba) { this.tiles.set(k, { data: decode(rgba) }); this.onload(x, y); } else { this.tiles.delete(k); this.failed.set(k, Date.now()); }
      }).catch(() => { this.tiles.delete(k); this.failed.set(k, Date.now()); }).finally(() => { this.loading--; });
    }
    // fractional tile coordinates of a point
    xy(lon, lat) {
      const x = ((lon + 180) / 360) * this.n, s = Math.sin((lat * Math.PI) / 180);
      return [x, (0.5 - Math.log((1 + s) / (1 - s)) / (4 * Math.PI)) * this.n];
    }
    pixel(tx, ty, ix, iy, fallback) {  // a pixel that may lie in the neighbouring tile
      if (ix < 0) { tx--; ix += TS; } else if (ix >= TS) { tx++; ix -= TS; }
      if (iy < 0) { ty--; iy += TS; } else if (iy >= TS) { ty++; iy -= TS; }
      const d = this.tile(tx, ty, false);
      return d ? d[iy * TS + ix] : fallback;
    }
    // metres above sea level (times the exaggeration), bilinear; 0 where nothing is loaded yet
    sample(lon, lat) {
      const [fx, fy] = this.xy(lon, lat), tx = Math.floor(fx), ty = Math.floor(fy);
      const d = this.tile(tx, ty);
      if (!d) return 0;
      const px = (fx - tx) * TS - 0.5, py = (fy - ty) * TS - 0.5, ix = Math.floor(px), iy = Math.floor(py), ax = px - ix, ay = py - iy;
      const c = d[Math.max(0, Math.min(TS - 1, iy)) * TS + Math.max(0, Math.min(TS - 1, ix))];
      const p = (x, y) => (x >= 0 && x < TS && y >= 0 && y < TS ? d[y * TS + x] : this.pixel(tx, ty, x, y, c));
      const h = p(ix, iy) * (1 - ax) * (1 - ay) + p(ix + 1, iy) * ax * (1 - ay) + p(ix, iy + 1) * (1 - ax) * ay + p(ix + 1, iy + 1) * ax * ay;
      return h * this.exaggeration;
    }
    // the same on mercator coordinates (0..1), which is what the scene works in
    sampleMerc(mx, my) { return this.sample(mx * 360 - 180, (Math.atan(Math.sinh(Math.PI * (1 - 2 * my))) * 180) / Math.PI); }
    ready(lon, lat) { const [fx, fy] = this.xy(lon, lat); return !!this.tile(Math.floor(fx), Math.floor(fy), false); }
    // request the tiles covering a box
    ensure(w, s, e, n) {
      const [x0, y1] = this.xy(w, s), [x1, y0] = this.xy(e, n);
      for (let x = Math.floor(x0); x <= Math.floor(x1); x++) for (let y = Math.floor(y0); y <= Math.floor(y1); y++) this.tile(x, y);
    }
    retry() { const now = Date.now(); for (const [k, t] of this.failed) if (now - t > 30000) this.failed.delete(k); }
  }

  // the browser side: tiles from our own proxy, decoded through a canvas
  function browserFetcher(urlFor) {
    let canvas = null, ctx = null;
    return async (z, x, y) => {
      const r = await fetch(urlFor(z, x, y), { credentials: "same-origin" });
      if (!r.ok) return null;
      const bmp = await createImageBitmap(await r.blob());
      if (!canvas) { canvas = typeof OffscreenCanvas !== "undefined" ? new OffscreenCanvas(TS, TS) : Object.assign(document.createElement("canvas"), { width: TS, height: TS }); ctx = canvas.getContext("2d", { willReadFrequently: true }); }
      ctx.clearRect(0, 0, TS, TS); ctx.drawImage(bmp, 0, 0, TS, TS);
      bmp.close?.();
      return ctx.getImageData(0, 0, TS, TS).data;
    };
  }

  window.DemLib = { Dem, decode, browserFetcher, TS };
})();
