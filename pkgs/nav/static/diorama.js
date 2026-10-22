"use strict";
// Diorama mode: everything that is not the view disappears. What stays is the map with its attribution, a time-of-day bar that fades away when idle,
// and a way out. The scene is 3D, all live vehicles run (tracked or not), and the daylight cycle is on.
(() => {
  const A = window.App;
  const { $ } = A;
  const LEVELS = [0, 1, 2, 4];  // terrain: off, true scale, and two exaggerations
  let terrainAt = 2;
  try { const raw = localStorage.getItem("dio-terrain"); if (raw !== null && LEVELS.includes(+raw)) terrainAt = +raw; } catch { /* private mode */ }
  let on = false, idleTimer = 0, orbitFrame = 0, orbitLast = 0, clockTimer = 0, saved = null;
  const TILT_LEVELS = [45, 60, 75, 85];
  const WEATHER_MODES = ["auto", "clear", "cloudy", "rain", "fog", "snow"];

  const poke = () => {
    if (!on) return;
    $("#diorama").classList.remove("idle");
    clearTimeout(idleTimer);
    idleTimer = setTimeout(() => $("#diorama")?.classList.add("idle"), 4000);
  };
  function syncTilt() {
    const map = A.getMap();
    if (!map) return;
    const p = Math.round(map.getPitch());
    const btn = $("#dio-tilt");
    if (btn) {
      btn.textContent = `Tilt ${p}°`;
      btn.setAttribute("aria-pressed", p >= 60);
    }
  }
  function syncWeather() {
    const b = $("#dio-weather");
    if (!b) return;
    const D = window.Daylight;
    if (!D) return;
    const cond = D.weather?.condition || "clear";
    const label = cond.charAt(0).toUpperCase() + cond.slice(1);
    if (D.weather?.auto) {
      b.textContent = `Weather: Auto (${label})`;
      b.setAttribute("aria-pressed", "true");
    } else {
      b.textContent = `Weather: ${label}`;
      b.setAttribute("aria-pressed", "false");
    }
  }
  function syncClock() {
    const D = window.Daylight;
    const isPlaying = D.mode === "replay" || D.mode === "cycle";
    $("#dio-clock").textContent = isPlaying || D.mode === "live" ? D.clockTextWithSeconds() : D.clockText();
    if (D.mode !== "fixed") {
      const m = Math.floor(D.mode === "live" ? D.localMinutes() : D.minutes);
      if (+$("#dio-slider").value !== m && document.activeElement !== $("#dio-slider")) $("#dio-slider").value = m;
    }
    $("#dio-live").setAttribute("aria-pressed", D.mode === "live" && !D.day);
    $("#dio-sun").textContent = D.sunText();
    const t = D.sunTimes();
    $("#dio-slider").style.setProperty("--rise", (t.sunrise / 14.4) + "%");
    $("#dio-slider").style.setProperty("--set", (t.sunset / 14.4) + "%");
    $("#dio-play").setAttribute("aria-pressed", isPlaying);
    $("#dio-play").textContent = isPlaying ? "Pause" : "Play";
    syncWeather();
    syncTilt();
  }
  function orbit(t) {
    orbitFrame = requestAnimationFrame(orbit);
    const dt = Math.min(0.1, (t - orbitLast) / 1000);
    orbitLast = t;
    const map = A.getMap();
    if (map && !document.hidden) map.setBearing(map.getBearing() + dt * 3.5);
  }
  function setOrbit(v) {
    cancelAnimationFrame(orbitFrame);
    $("#dio-orbit").setAttribute("aria-pressed", v);
    if (v) { orbitLast = performance.now(); orbitFrame = requestAnimationFrame(orbit); }
  }

  function enter() {
    if (on) return;
    on = true;
    const map = A.getMap(), V = window.Vehicles, D = window.Daylight;
    saved = { three: V.is3d(), pitch: map.getPitch(), zoom: map.getZoom(), bearing: map.getBearing() };
    document.body.classList.add("dio-on");
    $("#diorama").hidden = false;
    map.setMaxPitch(85);
    map.dragRotate?.enable();
    map.touchPitch?.enable();
    map.touchZoomRotate?.enableRotation();
    map.on("pitch", syncTilt);
    const c = map.getCenter();
    if (c) { D.lat = c.lat; D.lon = c.lng; }
    if (D.weather.auto) D.fetchWeather?.();
    D.syncTheme(); D.enable(true); V.setForce(true); V.setAmbient(true); V.setTerrain(terrainAt); syncTerrain();
    if (!V.is3d()) V.set3d(true);
    map.easeTo({ pitch: Math.max(map.getPitch(), 60), zoom: Math.max(map.getZoom(), 16), duration: 1000 });
    syncClock();
    clockTimer = setInterval(syncClock, 400);
    poke();
    if (document.documentElement.requestFullscreen && !document.fullscreenElement) document.documentElement.requestFullscreen().catch(() => {});
    history.replaceState(null, "", "#diorama");
  }
  function exit() {
    if (!on) return;
    on = false;
    const map = A.getMap(), V = window.Vehicles, D = window.Daylight;
    map.off("pitch", syncTilt);
    setOrbit(false); clearInterval(clockTimer); clearTimeout(idleTimer);
    document.body.classList.remove("dio-on");
    $("#diorama").hidden = true;
    const dioTrack = $("#dio-track");
    if (dioTrack) dioTrack.hidden = true;
    toggleHelp(false);
    D.enable(false); D.setDay(null); D.setLive(); V.setForce(false); V.setAmbient(false); V.setTerrain(0);
    if (!saved?.three && V.is3d()) V.set3d(false);
    if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
    history.replaceState(null, "", location.pathname);
    A.restyle();
    saved = null;
  }

  function toggleHelp(show) {
    const modal = $("#dio-help-modal");
    if (!modal) return;
    const isHidden = modal.hidden;
    const next = show !== undefined ? show : isHidden;
    modal.hidden = !next;
    $("#dio-help")?.setAttribute("aria-expanded", String(next));
    poke();
  }

  $("#btn-dio").addEventListener("click", enter);
  $("#dio-exit").addEventListener("click", exit);
  $("#dio-help")?.addEventListener("click", () => toggleHelp());
  $("#dio-help-close")?.addEventListener("click", () => toggleHelp(false));
  $("#dio-live").addEventListener("click", () => {
    window.Daylight.setDay(null);
    window.Daylight.setLive();
    $("#dio-date").value = "";
    window.Vehicles.refreshSched?.();
    syncClock();
    poke();
  });
  const jump = (k) => () => {
    const D = window.Daylight, t = D.sunTimes();
    D.setMinutes(k === "noon" ? t.noon : t[k]);
    window.Vehicles.refreshSched?.();
    syncClock();
    poke();
  };
  $("#dio-rise").addEventListener("click", jump("sunrise"));
  $("#dio-noon").addEventListener("click", jump("noon"));
  $("#dio-set").addEventListener("click", jump("sunset"));
  $("#dio-date").addEventListener("change", (e) => {
    const D = window.Daylight;
    D.setDay(e.target.value || null);
    if (!e.target.value) D.setLive();
    window.Vehicles.refreshSched?.();
    syncClock();
    poke();
  });
  $("#dio-play").addEventListener("click", () => {
    const D = window.Daylight;
    if (D.mode === "replay" || D.mode === "cycle") {
      D.pause();
    } else {
      D.play(1.0, "replay");
    }
    window.Vehicles.refreshSched?.();
    syncClock();
    poke();
  });
  $("#dio-tilt")?.addEventListener("click", () => {
    const map = A.getMap();
    if (!map) return;
    const cur = map.getPitch();
    let next = TILT_LEVELS[0];
    for (const l of TILT_LEVELS) {
      if (l > cur + 3) { next = l; break; }
    }
    map.easeTo({ pitch: next, duration: 400 });
    poke();
  });
  $("#dio-weather")?.addEventListener("click", () => {
    const D = window.Daylight;
    if (!D) return;
    const cur = D.weather.auto ? "auto" : D.weather.condition;
    const next = WEATHER_MODES[(WEATHER_MODES.indexOf(cur) + 1) % WEATHER_MODES.length];
    D.setWeather(next);
    syncWeather();
    poke();
  });
  function syncTerrain() { const b = $("#dio-terrain"); b.setAttribute("aria-pressed", terrainAt > 0); b.textContent = terrainAt ? `Terrain ${terrainAt}x` : "Terrain off"; }
  $("#dio-terrain").addEventListener("click", () => {
    terrainAt = LEVELS[(LEVELS.indexOf(terrainAt) + 1) % LEVELS.length];
    try { localStorage.setItem("dio-terrain", String(terrainAt)); } catch { /* private mode */ }
    window.Vehicles.setTerrain(terrainAt); syncTerrain(); poke();
  });
  $("#dio-orbit").addEventListener("click", () => { setOrbit($("#dio-orbit").getAttribute("aria-pressed") !== "true"); poke(); });
  let sliderDeb = 0;
  $("#dio-slider").addEventListener("input", (e) => {
    window.Daylight.setMinutes(+e.target.value);
    clearTimeout(sliderDeb);
    sliderDeb = setTimeout(() => window.Vehicles.refreshSched?.(), 250);
    syncClock();
    poke();
  });
  for (const ev of ["pointermove", "pointerdown", "keydown", "wheel", "touchstart"]) document.addEventListener(ev, poke, { passive: true });
  document.addEventListener("keydown", (e) => {
    if (!on) return;
    if (document.activeElement && (document.activeElement.tagName === "INPUT" || document.activeElement.tagName === "TEXTAREA")) return;
    const modal = $("#dio-help-modal");
    if (e.key === "Escape") {
      if (modal && !modal.hidden) {
        toggleHelp(false);
        e.preventDefault();
        return;
      }
      if (!document.fullscreenElement) exit();
      return;
    }
    if (e.key === "?" || e.key === "h" || e.key === "H") {
      toggleHelp();
      e.preventDefault();
      return;
    }
    const map = A.getMap();
    if (!map) return;
    const key = e.key.toLowerCase();
    if (key === "w" || e.key === "ArrowUp") {
      if (!e.shiftKey) { map.panBy([0, -80], { duration: 150 }); poke(); }
    } else if (key === "s" || e.key === "ArrowDown") {
      if (!e.shiftKey) { map.panBy([0, 80], { duration: 150 }); poke(); }
    } else if (key === "a" || e.key === "ArrowLeft") {
      if (!e.shiftKey) { map.panBy([-80, 0], { duration: 150 }); poke(); }
    } else if (key === "d" || e.key === "ArrowRight") {
      if (!e.shiftKey) { map.panBy([80, 0], { duration: 150 }); poke(); }
    } else if (key === "q") {
      map.easeTo({ bearing: map.getBearing() - 15, duration: 200 }); poke();
    } else if (key === "e") {
      map.easeTo({ bearing: map.getBearing() + 15, duration: 200 }); poke();
    } else if (key === "r") {
      map.easeTo({ pitch: Math.min(85, map.getPitch() + 10), duration: 200 }); poke();
    } else if (key === "f") {
      map.easeTo({ pitch: Math.max(0, map.getPitch() - 10), duration: 200 }); poke();
    } else if (key === "+" || key === "=") {
      map.zoomIn({ duration: 200 }); poke();
    } else if (key === "-" || key === "_") {
      map.zoomOut({ duration: 200 }); poke();
    } else if (key === "o") {
      $("#dio-orbit")?.click(); poke();
    } else if (e.key === " ") {
      $("#dio-play")?.click(); poke();
      e.preventDefault();
    }
  });
  document.addEventListener("fullscreenchange", () => { if (on && !document.fullscreenElement) { /* leaving fullscreen keeps the mode, Escape or Exit leaves it */ } });
  window.Daylight.onThemeChange = () => { if (on || !window.Daylight.enabled) A.restyle(); };

  window.Diorama = { enter, exit, active: () => on };
  if (location.hash.includes("diorama")) setTimeout(() => A.getMap() && enter(), 2500);
})();
