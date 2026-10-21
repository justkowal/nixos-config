"use strict";
// Daylight: where the sun is, what colour the light and sky are, and how dark it is. Outside diorama mode the light is a fixed neutral day, so the
// ordinary map never looks odd; in diorama mode the real sun (or a scrubbed or cycling time of day) drives
//  - the vehicle shader (sun direction and colour, sky ambient, night factor for lamps and windows),
//  - MapLibre's own light for the 3D buildings, and its sky and fog,
//  - an automatic switch to the dark base map at night.
(() => {
  const RAD = Math.PI / 180;
  const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
  const smooth = (a, b, x) => { const t = clamp((x - a) / (b - a)); return t * t * (3 - 2 * t); };
  const mix = (a, b, t) => a.map((v, i) => v + (b[i] - v) * t);
  const lin = (c) => c.map((v) => Math.pow(v, 2.2));
  const hex = (c) => "#" + c.map((v) => Math.round(clamp(v) * 255).toString(16).padStart(2, "0")).join("");

  // solar position (NOAA style approximation, good to well under a degree): azimuth clockwise from north, altitude above the horizon, both in radians
  function sunPosition(date, lat, lon) {
    const d = date.getTime() / 86400000 + 2440587.5 - 2451545.0;
    const g = (357.529 + 0.98560028 * d) * RAD, q = 280.459 + 0.98564736 * d;
    const L = (q + 1.915 * Math.sin(g) + 0.02 * Math.sin(2 * g)) * RAD, e = (23.439 - 0.00000036 * d) * RAD;
    const ra = Math.atan2(Math.cos(e) * Math.sin(L), Math.cos(L)), dec = Math.asin(Math.sin(e) * Math.sin(L));
    const H = ((280.46061837 + 360.98564736629 * d + lon) * RAD) - ra, phi = lat * RAD;
    const alt = Math.asin(Math.sin(phi) * Math.sin(dec) + Math.cos(phi) * Math.cos(dec) * Math.cos(H));
    const az = Math.atan2(Math.sin(H), Math.cos(H) * Math.sin(phi) - Math.tan(dec) * Math.cos(phi)) + Math.PI;
    return { az, alt };
  }

  // light and sky for a sun altitude (degrees). Colours are display colours 0..1; the shader gets them linearised.
  function skyState(altDeg) {
    const day = smooth(-4, 8, altDeg), night = 1 - smooth(-9, 1.5, altDeg), warm = 1 - smooth(4, 30, altDeg);
    const sunWhite = [1.0, 0.97, 0.92], sunWarm = [1.0, 0.62, 0.32];
    const sunColor = mix(sunWhite, sunWarm, warm).map((v) => v * smooth(-1, 12, altDeg) * 0.95);
    const moon = [0.45, 0.55, 0.85].map((v) => v * 0.16 * night);
    const ambientDay = [0.56, 0.64, 0.78], ambientDusk = [0.62, 0.5, 0.5], ambientNight = [0.13, 0.17, 0.3];
    const ambient = mix(mix(ambientNight, ambientDusk, smooth(-8, 0, altDeg)), ambientDay, smooth(2, 25, altDeg)).map((v) => v * (0.5 + 0.2 * day));
    const sky = mix(mix([0.03, 0.05, 0.12], [0.35, 0.28, 0.42], smooth(-10, -2, altDeg)), [0.45, 0.68, 0.95], smooth(-1, 14, altDeg));
    const horizon = mix(mix([0.06, 0.09, 0.18], [0.95, 0.55, 0.32], smooth(-8, -1, altDeg)), [0.82, 0.9, 0.98], smooth(3, 22, altDeg));
    return { day, night, sunColor, moon, ambient, sky, horizon, alt: altDeg };
  }

  const D = { enabled: false, mode: "live", minutes: 720, speed: 16, lat: 50.06, lon: 19.94, _last: 0, _lightAt: 0, _state: null, _dark: false, bg: [0.78, 0.78, 0.8] };
  const NEUTRAL = { sun: [0.35, -0.45, 0.82], sunColor: [0.78, 0.74, 0.68], ambient: [0.34, 0.36, 0.4], night: 0 };
  const TZ = "Europe/Warsaw";

  // minutes since local (Warsaw) midnight for a date, with the seconds as a fraction
  const fmt = new Intl.DateTimeFormat("en-GB", { timeZone: TZ, hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23" });
  const localMinutes = (date) => { const p = Object.fromEntries(fmt.formatToParts(date).map((x) => [x.type, +x.value])); return p.hour * 60 + p.minute + p.second / 60; };
  // the displayed time: now, a fixed minute of today, or a cycling clock
  // a chosen day (local midnight as a Date) or null for today
  D.day = null;
  const dayStart = (date) => date.getTime() - localMinutes(date) * 60000;
  D.time = () => {
    const now = new Date();
    if (D.mode === "live" && !D.day) return now;
    const start = D.day ? D.day.getTime() : dayStart(now);
    return new Date(start + (D.mode === "live" ? localMinutes(now) : D.minutes % 1440) * 60000);
  };
  D.setDay = (iso) => {  // 'YYYY-MM-DD' or null; local noon is used to find that day's local midnight
    if (!iso) { D.day = null; D._times = null; return; }
    const noon = new Date(`${iso}T12:00:00Z`);
    D.day = new Date(noon.getTime() - localMinutes(noon) * 60000 - 0);
    if (D.mode === "live") { D.minutes = D.localMinutes(); D.mode = "fixed"; }
    D._times = null;
  };
  // actual sun times of the shown day, found by scanning the day for the altitude crossing -0.833 degrees (sun edge on the horizon) and -6 (civil twilight)
  D.sunTimes = () => {
    const start = D.day ? D.day.getTime() : dayStart(new Date()), key = `${start}|${D.lat}|${D.lon}`;
    if (D._times && D._times.key === key) return D._times;
    const alt = (m) => sunPosition(new Date(start + m * 60000), D.lat, D.lon).alt / RAD;
    const out = { key, sunrise: null, sunset: null, dawn: null, dusk: null, noon: 720, maxAlt: -90 };
    let prev = alt(0);
    for (let m = 1; m < 1440; m++) {
      const a = alt(m);
      if (prev < -0.833 && a >= -0.833) out.sunrise = m;
      if (prev >= -0.833 && a < -0.833) out.sunset = m;
      if (prev < -6 && a >= -6) out.dawn = m;
      if (prev >= -6 && a < -6) out.dusk = m;
      if (a > out.maxAlt) { out.maxAlt = a; out.noon = m; }
      prev = a;
    }
    out.dayLength = out.sunrise != null && out.sunset != null ? out.sunset - out.sunrise : out.maxAlt > 0 ? 1440 : 0;  // polar day or night
    D._times = out;
    return out;
  };
  const hm = (m) => (m == null ? "--:--" : `${String(Math.floor(m / 60)).padStart(2, "0")}:${String(m % 60).padStart(2, "0")}`);
  D.sunText = () => { const t = D.sunTimes(); return `Sunrise ${hm(t.sunrise)}, sunset ${hm(t.sunset)} (${Math.floor(t.dayLength / 60)} h ${String(t.dayLength % 60).padStart(2, "0")} min of daylight)`; };
  D.hm = hm;
  D.clockText = () => { const m = Math.floor(D.mode === "live" ? localMinutes(new Date()) : D.minutes % 1440); return `${String(Math.floor(m / 60)).padStart(2, "0")}:${String(m % 60).padStart(2, "0")}`; };
  D.localMinutes = () => localMinutes(D.time());
  D.enable = (on) => { D.enabled = on; D._lightAt = 0; if (!on) D.clear(); };
  D.setLive = () => { D.mode = "live"; };
  D.setMinutes = (m) => { D.mode = "fixed"; D.minutes = ((m % 1440) + 1440) % 1440; };
  D.play = (speed) => { if (D.mode === "live") D.minutes = D.localMinutes(); D.mode = "cycle"; D.speed = speed || D.speed; D._last = performance.now(); };
  D.pause = () => { if (D.mode === "cycle") { D.mode = "fixed"; } };
  D.state = () => { const t = D.time(), p = sunPosition(t, D.lat, D.lon), s = skyState(p.alt / RAD); s.az = p.az; return s; };
  D.wantsDark = () => D.enabled && D._dark;

  // writes the light into the scene (each frame) and into MapLibre (a few times a second)
  D.apply = (scene, map) => {
    if (!scene) return;
    if (!D.enabled) { scene.setLight({ sun: NEUTRAL.sun, sunColor: lin(NEUTRAL.sunColor), ambient: lin(NEUTRAL.ambient), night: 0, bg: lin(D.bg) }); return; }
    const now = performance.now();
    if (D.mode === "cycle") { D.minutes = (D.minutes + ((now - D._last) / 1000) * D.speed) % 1440; }
    D._last = now;
    const s = D._state = D.state(), alt = s.alt * RAD, up = Math.sin(alt), horiz = Math.cos(alt);
    const dir = s.alt > -1 ? [Math.sin(s.az) * horiz, Math.cos(s.az) * horiz, Math.max(up, 0.03)] : [0.3, -0.4, 0.8];  // below the horizon the "sun" becomes a moon light from the sky
    const col = s.alt > -1 ? s.sunColor : s.moon.map((v) => v * 1.0);
    scene.setLight({ sun: dir, sunColor: lin(col.map((v, i) => v + (s.alt > -1 ? s.moon[i] : 0))), ambient: lin(s.ambient), night: s.night, bg: lin(D.bg) });
    if (now - D._lightAt > 250 && map) {
      D._lightAt = now;
      try {
        const azDeg = (s.az / RAD + 360) % 360, polar = clamp(90 - Math.max(s.alt, 4), 8, 86);
        map.setLight({ anchor: "map", color: hex(s.alt > -1 ? s.sunColor.map((v) => v + 0.12 * (1 - s.night)) : [0.3, 0.35, 0.6]), intensity: clamp(0.25 + 0.55 * s.day), position: [1.5, azDeg, polar] });
        map.setSky({ "sky-color": hex(s.sky), "horizon-color": hex(s.horizon), "fog-color": hex(s.horizon), "fog-ground-blend": 0.6, "horizon-fog-blend": 0.8, "sky-horizon-blend": 0.6, "atmosphere-blend": ["interpolate", ["linear"], ["zoom"], 0, 1, 12, 0.4] });
      } catch { /* an older runtime without sky support */ }
      const dark = D._dark ? s.night > 0.35 : s.night > 0.6;  // hysteresis so the style does not flicker at dusk
      if (dark !== D._dark) { D._dark = dark; D.onThemeChange?.(); }
    }
  };
  D.clear = () => { try { window.App?.getMap?.()?.setLight({ anchor: "viewport", color: "#ffffff", intensity: 0.5, position: [1.15, 210, 30] }); window.App?.getMap?.()?.setSky(null); } catch { /* none */ } D._dark = false; D.onThemeChange?.(); };
  D.syncTheme = (dark) => { D.bg = dark ? [0.1, 0.11, 0.13] : [0.86, 0.87, 0.89]; };  // what dimmed vehicles fade toward: the ground colour of the current base map

  window.Daylight = Object.assign(D, { sunPosition, skyState });
})();
