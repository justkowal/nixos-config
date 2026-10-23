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

  // light and sky for a sun altitude (degrees) and weather condition. Colours are display colours 0..1; the shader gets them linearised.
  function skyState(altDeg, weather = "clear") {
    const day = smooth(-4, 8, altDeg), night = 1 - smooth(-9, 1.5, altDeg), warm = 1 - smooth(4, 30, altDeg);
    const sunWhite = [1.0, 0.97, 0.92], sunWarm = [1.0, 0.62, 0.32];
    let sunColor = mix(sunWhite, sunWarm, warm).map((v) => v * smooth(-1, 12, altDeg) * 0.95);
    const moon = [0.45, 0.55, 0.85].map((v) => v * 0.16 * night);
    const ambientDay = [0.56, 0.64, 0.78], ambientDusk = [0.62, 0.5, 0.5], ambientNight = [0.13, 0.17, 0.3];
    let ambient = mix(mix(ambientNight, ambientDusk, smooth(-8, 0, altDeg)), ambientDay, smooth(2, 25, altDeg)).map((v) => v * (0.5 + 0.2 * day));
    let sky = mix(mix([0.03, 0.05, 0.12], [0.35, 0.28, 0.42], smooth(-10, -2, altDeg)), [0.45, 0.68, 0.95], smooth(-1, 14, altDeg));
    let horizon = mix(mix([0.06, 0.09, 0.18], [0.95, 0.55, 0.32], smooth(-8, -1, altDeg)), [0.82, 0.9, 0.98], smooth(3, 22, altDeg));
    let fog = horizon;
    let fogDensity = 0.6;

    if (weather === "cloudy") {
      sunColor = sunColor.map((v) => v * 0.45);
      ambient = ambient.map((v) => v * 1.15 + 0.05);
      sky = mix(sky, [0.55, 0.58, 0.64], 0.75);
      horizon = mix(horizon, [0.65, 0.68, 0.72], 0.75);
      fog = horizon;
      fogDensity = 0.75;
    } else if (weather === "rain" || weather === "thunderstorm") {
      const storm = weather === "thunderstorm";
      sunColor = sunColor.map((v) => v * (storm ? 0.15 : 0.25));
      ambient = ambient.map((v) => v * 0.85);
      sky = mix(sky, storm ? [0.18, 0.20, 0.26] : [0.28, 0.32, 0.38], 0.85);
      horizon = mix(horizon, storm ? [0.22, 0.24, 0.30] : [0.36, 0.39, 0.45], 0.85);
      fog = horizon;
      fogDensity = 0.85;
    } else if (weather === "fog") {
      sunColor = sunColor.map((v) => v * 0.2);
      ambient = ambient.map((v) => v * 1.1);
      sky = [0.72, 0.74, 0.78];
      horizon = [0.72, 0.74, 0.78];
      fog = [0.72, 0.74, 0.78];
      fogDensity = 0.95;
    } else if (weather === "snow") {
      sunColor = sunColor.map((v) => v * 0.6);
      ambient = ambient.map((v) => v * 1.25 + 0.08);
      sky = mix(sky, [0.74, 0.78, 0.84], 0.7);
      horizon = mix(horizon, [0.82, 0.85, 0.90], 0.7);
      fog = horizon;
      fogDensity = 0.8;
    }

    return { day, night, sunColor, moon, ambient, sky, horizon, fog, fogDensity, alt: altDeg, weather };
  }

  const D = {
    enabled: false,
    mode: "live",
    minutes: 720,
    speed: 1.0,
    lat: 50.06,
    lon: 19.94,
    _last: 0,
    _lightAt: 0,
    _state: null,
    _dark: false,
    bg: [0.78, 0.78, 0.8],
    weather: { condition: "clear", temp: 16, cloud: 10, precip: 0, auto: true },
  };
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
  D.clockTextWithSeconds = () => {
    const m = D.mode === "live" ? localMinutes(new Date()) : D.minutes % 1440;
    const totalSec = Math.floor(m * 60);
    return `${String(Math.floor(totalSec / 3600)).padStart(2, "0")}:${String(Math.floor((totalSec % 3600) / 60)).padStart(2, "0")}:${String(totalSec % 60).padStart(2, "0")}`;
  };
  D.clockHour = () => (D.mode === "live" ? localMinutes(new Date()) : D.minutes % 1440) / 60;
  D.localMinutes = () => localMinutes(D.time());
  D.enable = (on) => { D.enabled = on; D._lightAt = 0; if (!on) D.clear(); };
  D.setLive = () => { D.mode = "live"; };
  D.setMinutes = (m) => { D.mode = "fixed"; D.minutes = ((m % 1440) + 1440) % 1440; };
  D.play = (speed, mode = "replay") => {
    if (D.mode === "live") D.minutes = D.localMinutes();
    D.mode = mode;
    D.speed = speed !== undefined ? speed : 1.0;
    D._last = performance.now();
  };
  D.pause = () => { if (D.mode === "cycle" || D.mode === "replay") { D.mode = "fixed"; } };
  D.setWeather = (cond) => {
    if (cond === "auto") {
      D.weather.auto = true;
      D.fetchWeather?.();
    } else {
      D.weather.auto = false;
      D.weather.condition = cond;
      D._lightAt = 0;
    }
  };
  D.fetchWeather = async () => {
    try {
      const res = await fetch(`/api/weather?lat=${D.lat.toFixed(4)}&lon=${D.lon.toFixed(4)}`);
      if (res.ok) {
        const data = await res.json();
        if (data && data.condition && D.weather.auto) {
          D.weather.condition = data.condition;
          D.weather.temp = data.temp;
          D.weather.cloud = data.cloud;
          D.weather.precip = data.precip;
          D._lightAt = 0;
        }
      }
    } catch { /* offline / fallback */ }
  };
  D.state = () => { const t = D.time(), p = sunPosition(t, D.lat, D.lon), s = skyState(p.alt / RAD, D.weather.condition); s.az = p.az; return s; };
  D.wantsDark = () => D.enabled && D._dark;

  // writes the light into the scene (each frame) and into MapLibre (a few times a second)
  D.apply = (scene, map) => {
    if (!scene) return;
    if (!D.enabled) { scene.setLight({ sun: NEUTRAL.sun, sunColor: lin(NEUTRAL.sunColor), ambient: lin(NEUTRAL.ambient), night: 0, bg: lin(D.bg), timeMin: 720, sunsetMin: 1110, sunriseMin: 360 }); return; }
    const now = performance.now();
    if (D.mode === "cycle") {
      D.minutes = (D.minutes + ((now - D._last) / 1000) * D.speed) % 1440;
    } else if (D.mode === "replay") {
      // realtime pace: speed is simulation seconds per real second
      D.minutes = (D.minutes + ((now - D._last) / 1000) * (D.speed / 60)) % 1440;
    }
    D._last = now;
    const s = D._state = D.state(), alt = s.alt * RAD, up = Math.sin(alt), horiz = Math.cos(alt);
    const dir = s.alt > -1 ? [Math.sin(s.az) * horiz, Math.cos(s.az) * horiz, Math.max(up, 0.03)] : [0.3, -0.4, 0.8];  // below the horizon the "sun" becomes a moon light from the sky
    const col = s.alt > -1 ? s.sunColor : s.moon.map((v) => v * 1.0);
    const m = Math.floor(D.mode === "live" ? localMinutes(new Date()) : D.minutes % 1440);
    const st = D.sunTimes();
    scene.setLight({ sun: dir, sunColor: lin(col.map((v, i) => v + (s.alt > -1 ? s.moon[i] : 0))), ambient: lin(s.ambient), night: s.night, bg: lin(D.bg), timeMin: m, sunsetMin: st.sunset ?? 1110, sunriseMin: st.sunrise ?? 360 });
    scene.weather = D.weather.condition;
    if (now - D._lightAt > 250 && map) {
      D._lightAt = now;
      try {
        const azDeg = (s.az / RAD + 360) % 360, polar = clamp(90 - Math.max(s.alt, 4), 8, 86);
        map.setLight({ anchor: "map", color: hex(s.alt > -1 ? s.sunColor.map((v) => v + 0.12 * (1 - s.night)) : [0.3, 0.35, 0.6]), intensity: clamp(0.25 + 0.55 * s.day), position: [1.5, azDeg, polar] });
        if (map.getLayer("dem-hill")) { map.setPaintProperty("dem-hill", "hillshade-illumination-direction", azDeg); map.setPaintProperty("dem-hill", "hillshade-exaggeration", s.alt > 0 ? clamp(0.22 + 0.35 * (1 - Math.min(1, s.alt / 50)), 0.2, 0.6) : 0.12); }  // long shadows at low sun
        map.setSky({
          "sky-color": hex(s.sky),
          "horizon-color": hex(s.horizon),
          "fog-color": hex(s.fog || s.horizon),
          "fog-ground-blend": s.fogDensity || 0.6,
          "horizon-fog-blend": 0.8,
          "sky-horizon-blend": 0.6,
          "atmosphere-blend": ["interpolate", ["linear"], ["zoom"], 0, 1, 12, 0.4]
        });
      } catch { /* an older runtime without sky support */ }
      const dark = D._dark ? s.night > 0.35 : s.night > 0.6;  // hysteresis so the style does not flicker at dusk
      if (dark !== D._dark) { D._dark = dark; D.onThemeChange?.(); }
    }
  };
  D.groundIllumination = (st) => {
    const s = st || D._state || D.state();
    if (!s) return [1.0, 1.0, 1.0];
    const alt = s.alt * RAD;
    // Direct sunlight has vertical incidence (sin) plus grazing atmospheric wash at low sun
    const sunIncidence = s.alt > 0 ? Math.sin(alt) * 0.75 + 0.35 * smooth(-1, 14, s.alt) : 0;
    const sunC = s.alt > 0 ? s.sunColor : [0, 0, 0];
    const ambC = s.ambient;
    const moonC = s.moon || [0, 0, 0];

    // Direct sun on ground + ambient diffuse + moonlight
    const r = ambC[0] + sunC[0] * sunIncidence + moonC[0] * 1.2;
    const g = ambC[1] + sunC[1] * sunIncidence + moonC[1] * 1.2;
    const b = ambC[2] + sunC[2] * sunIncidence + moonC[2] * 1.2;

    const maxMidday = 1.15;
    return [
      clamp(r / maxMidday, 0.16, 1.15),
      clamp(g / maxMidday, 0.17, 1.15),
      clamp(b / maxMidday, 0.18, 1.15)
    ];
  };

  D.createIlluminationLayer = () => {
    let prog = null, vbo = null, uMatrix = null, uLight = null;

    const VS = `#version 300 es
    precision highp float;
    uniform mat4 u_matrix;
    in vec2 a_pos;
    void main() {
      gl_Position = u_matrix * vec4(a_pos, 0.0, 1.0);
    }`;

    const FS = `#version 300 es
    precision mediump float;
    uniform vec3 u_light;
    out vec4 fragColor;
    void main() {
      fragColor = vec4(u_light, 1.0);
    }`;

    return {
      id: "base-map-illumination",
      type: "custom",
      renderingMode: "3d",
      onAdd(map, gl) {
        const vs = gl.createShader(gl.VERTEX_SHADER);
        gl.shaderSource(vs, VS);
        gl.compileShader(vs);
        const fs = gl.createShader(gl.FRAGMENT_SHADER);
        gl.shaderSource(fs, FS);
        gl.compileShader(fs);
        prog = gl.createProgram();
        gl.attachShader(prog, vs);
        gl.attachShader(prog, fs);
        gl.linkProgram(prog);

        uMatrix = gl.getUniformLocation(prog, "u_matrix");
        uLight = gl.getUniformLocation(prog, "u_light");

        const verts = [];
        const STEPS = 8;
        for (let i = 0; i < STEPS; i++) {
          for (let j = 0; j < STEPS; j++) {
            const x0 = i / STEPS, x1 = (i + 1) / STEPS;
            const y0 = j / STEPS, y1 = (j + 1) / STEPS;
            verts.push(
              x0, y0,  x1, y0,  x0, y1,
              x0, y1,  x1, y0,  x1, y1
            );
          }
        }
        vbo = gl.createBuffer();
        gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
        gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(verts), gl.STATIC_DRAW);
      },
      render(gl, args) {
        if (!D.enabled || !prog) return;
        const mat = (args && (args.defaultProjectionData?.mainMatrix || args.modelViewProjectionMatrix)) || args;
        if (!mat) return;
        const m32 = mat instanceof Float32Array ? mat : new Float32Array(mat);
        if (m32.length < 16) return;
        const [lr, lg, lb] = D.groundIllumination();

        gl.useProgram(prog);
        gl.uniformMatrix4fv(uMatrix, false, m32);
        gl.uniform3f(uLight, lr, lg, lb);

        gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
        const aPos = gl.getAttribLocation(prog, "a_pos");
        gl.enableVertexAttribArray(aPos);
        gl.vertexAttribPointer(aPos, 2, gl.FLOAT, false, 0, 0);

        gl.enable(gl.BLEND);
        gl.blendFuncSeparate(gl.DST_COLOR, gl.ZERO, gl.ZERO, gl.ONE);
        gl.colorMask(true, true, true, false);
        gl.disable(gl.DEPTH_TEST);

        gl.drawArrays(gl.TRIANGLES, 0, 8 * 8 * 6);

        gl.colorMask(true, true, true, true);
        gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
        gl.disableVertexAttribArray(aPos);
      },
      onRemove(map, gl) {
        if (vbo) { gl.deleteBuffer(vbo); vbo = null; }
        if (prog) { gl.deleteProgram(prog); prog = null; }
      }
    };
  };

  D.clear = () => { try { window.App?.getMap?.()?.setLight({ anchor: "viewport", color: "#ffffff", intensity: 0.5, position: [1.15, 210, 30] }); window.App?.getMap?.()?.setSky?.(undefined, { validate: false }); } catch { /* none */ } D._dark = false; D.onThemeChange?.(); };
  D.syncTheme = (dark) => { D.bg = dark ? [0.1, 0.11, 0.13] : [0.86, 0.87, 0.89]; };  // what dimmed vehicles fade toward: the ground colour of the current base map

  window.Daylight = Object.assign(D, { sunPosition, skyState });
})();
