"use strict";
// Diorama mode: everything that is not the view disappears. What stays is the map with its attribution, a time-of-day bar that fades away when idle,
// and a way out. The scene is 3D, all live vehicles run (tracked or not), and the daylight cycle is on.
(() => {
  const A = window.App;
  const { $ } = A;
  let on = false, idleTimer = 0, orbitFrame = 0, orbitLast = 0, clockTimer = 0, saved = null;

  const poke = () => {
    if (!on) return;
    $("#diorama").classList.remove("idle");
    clearTimeout(idleTimer);
    idleTimer = setTimeout(() => $("#diorama")?.classList.add("idle"), 4000);
  };
  function syncClock() {
    const D = window.Daylight;
    $("#dio-clock").textContent = D.clockText() + (D.mode === "live" ? "" : "");
    if (D.mode !== "fixed") { const m = Math.floor(D.mode === "live" ? D.localMinutes() : D.minutes); if (+$("#dio-slider").value !== m && document.activeElement !== $("#dio-slider")) $("#dio-slider").value = m; }
    $("#dio-live").setAttribute("aria-pressed", D.mode === "live" && !D.day);
    $("#dio-sun").textContent = D.sunText();
    const t = D.sunTimes(); $("#dio-slider").style.setProperty("--rise", (t.sunrise / 14.4) + "%"); $("#dio-slider").style.setProperty("--set", (t.sunset / 14.4) + "%");
    $("#dio-play").setAttribute("aria-pressed", D.mode === "cycle");
    $("#dio-play").textContent = D.mode === "cycle" ? "Pause" : "Play";
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
    D.syncTheme(); D.enable(true); V.setForce(true);
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
    setOrbit(false); clearInterval(clockTimer); clearTimeout(idleTimer);
    document.body.classList.remove("dio-on");
    $("#diorama").hidden = true;
    D.enable(false); D.setDay(null); D.setLive(); V.setForce(false);
    if (!saved?.three && V.is3d()) V.set3d(false);
    if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
    history.replaceState(null, "", location.pathname);
    A.restyle();
    saved = null;
  }

  $("#btn-dio").addEventListener("click", enter);
  $("#dio-exit").addEventListener("click", exit);
  $("#dio-live").addEventListener("click", () => { window.Daylight.setDay(null); window.Daylight.setLive(); $("#dio-date").value = ""; syncClock(); poke(); });
  const jump = (k) => () => { const D = window.Daylight, t = D.sunTimes(); D.setMinutes(k === "noon" ? t.noon : t[k]); syncClock(); poke(); };
  $("#dio-rise").addEventListener("click", jump("sunrise"));
  $("#dio-noon").addEventListener("click", jump("noon"));
  $("#dio-set").addEventListener("click", jump("sunset"));
  $("#dio-date").addEventListener("change", (e) => { const D = window.Daylight; D.setDay(e.target.value || null); if (!e.target.value) D.setLive(); syncClock(); poke(); });
  $("#dio-play").addEventListener("click", () => { const D = window.Daylight; if (D.mode === "cycle") D.pause(); else D.play(16); syncClock(); poke(); });
  $("#dio-orbit").addEventListener("click", () => { setOrbit($("#dio-orbit").getAttribute("aria-pressed") !== "true"); poke(); });
  $("#dio-slider").addEventListener("input", (e) => { window.Daylight.setMinutes(+e.target.value); syncClock(); poke(); });
  for (const ev of ["pointermove", "pointerdown", "keydown", "wheel", "touchstart"]) document.addEventListener(ev, poke, { passive: true });
  document.addEventListener("keydown", (e) => { if (on && e.key === "Escape" && !document.fullscreenElement) exit(); });
  document.addEventListener("fullscreenchange", () => { if (on && !document.fullscreenElement) { /* leaving fullscreen keeps the mode, Escape or Exit leaves it */ } });
  window.Daylight.onThemeChange = () => { if (on || !window.Daylight.enabled) A.restyle(); };

  window.Diorama = { enter, exit, active: () => on };
  if (location.hash.includes("diorama")) setTimeout(() => A.getMap() && enter(), 2500);
})();
