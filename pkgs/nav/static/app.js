"use strict";
window.__sim = /[#&]sim=1/.test(location.hash);
// Kowal Nav client. No framework: state object, small render functions, text set with textContent only (feed data is untrusted).

const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const SVG = "http://www.w3.org/2000/svg";
const TZ = "Europe/Warsaw";

function h(tag, props = {}, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (v == null || v === false) continue;
    if (k === "class") e.className = v;
    else if (k === "style") for (const [p, val] of Object.entries(v)) e.style.setProperty(p, val);
    else if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
    else e.setAttribute(k, v === true ? "" : v);
  }
  for (const c of kids.flat()) if (c != null && c !== false) e.append(c.nodeType ? c : document.createTextNode(c));
  return e;
}
function icon(id, cls = "") {
  const s = document.createElementNS(SVG, "svg");
  s.setAttribute("class", "ic " + cls);
  s.setAttribute("aria-hidden", "true");
  const u = document.createElementNS(SVG, "use");
  u.setAttribute("href", "#i-" + id);
  s.append(u);
  return s;
}
const store = {
  get(k, d) { try { return JSON.parse(localStorage.getItem(k)) ?? d; } catch { return d; } },
  set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch { /* private mode */ } },
};

// ---------------------------------------------------------------- formatting
const tf = new Intl.DateTimeFormat("pl-PL", { hour: "2-digit", minute: "2-digit", hour12: false, timeZone: TZ });
const df = new Intl.DateTimeFormat("en-GB", { weekday: "short", day: "numeric", month: "short", timeZone: TZ });
const dkey = (d) => new Intl.DateTimeFormat("sv-SE", { timeZone: TZ }).format(d);
const hm = (iso) => tf.format(new Date(iso));
function dayTag(iso) {
  const d = new Date(iso), today = new Date();
  if (dkey(d) === dkey(today)) return "";
  if (dkey(d) === dkey(new Date(today.getTime() + 864e5))) return "tomorrow";
  return df.format(d);
}
const mins = (s) => Math.round(s / 60);
function dur(s) {
  const m = mins(s);
  return m < 60 ? `${m} min` : `${Math.floor(m / 60)} h${m % 60 ? ` ${m % 60} min` : ""}`;
}
const dist = (m) => (m < 950 ? `${Math.round(m / 10) * 10} m` : `${(m / 1000).toFixed(m < 10000 ? 1 : 0)} km`);

// ---------------------------------------------------------------- providers and modes
let providers = [];
const FALLBACK = { RAIL: "#b3311f", BUS: "#1c5fb0", TRAM: "#a35a00" };
const MODE_ICON = { WALK: "walk", BICYCLE: "bike", CAR: "car", RAIL: "rail", BUS: "bus", TRAM: "tram", SUBWAY: "tram" };
const providerOf = (agency) => providers.find((p) => agency && agency.includes(p.match));
function color(leg) {
  if (leg.line) return providerOf(leg.agency)?.color || FALLBACK[leg.mode] || "#44505c";
  return css(leg.mode === "BICYCLE" ? "--bike" : leg.mode === "CAR" ? "--car" : "--walk");
}
const css = (v) => getComputedStyle(document.documentElement).getPropertyValue(v).trim();

function rtTag(delayS, live) {
  if (!live) return h("span", { class: "rt plan", title: "This vehicle has no live data, the time is from the timetable" }, "No live data");
  const m = mins(delayS || 0);
  if (m >= 1) return h("span", { class: "rt late" }, `Live, ${m} min late`);
  if (m <= -1) return h("span", { class: "rt live" }, `Live, ${-m} min early`);
  return h("span", { class: "rt live" }, "Live, on time");
}
function badge(line, c, mode) {
  return h("span", { class: "badge", style: { "--c": c } }, icon(MODE_ICON[mode] || "transit"), line);
}

// ---------------------------------------------------------------- state
const S = {
  tab: "plan", from: null, to: null, mode: "transit", transit: { rail: true, bus: true, tram: true },
  by: "depart", at: "", results: [], sel: -1, me: null, detent: "peek", active: "to", stop: null,
};
let ctl = null;

async function api(path, params = {}, signal) {
  const q = new URLSearchParams(params).toString();
  const r = await fetch(`/api/${path}${q ? "?" + q : ""}`, { credentials: "same-origin", signal });
  if (r.status === 401) { showLogin(); throw new Error("signed out"); }
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error || `error ${r.status}`);
  return j;
}

// ---------------------------------------------------------------- map
const dark = matchMedia("(prefers-color-scheme: dark)");
const styleUrl = () => `https://tiles.openfreemap.org/styles/${dark.matches ? "dark" : "positron"}`;
let map, routeData = { type: "FeatureCollection", features: [] };
let markers = [], userMarker = null, popup = null;

function initMap() {
  const home = store.get("view", { c: [19.94, 50.06], z: 11 });
  try {
    map = new maplibregl.Map({ container: "map", style: styleUrl(), center: home.c, zoom: home.z, attributionControl: false, dragRotate: false, pitchWithRotate: false, touchPitch: false, maxPitch: 70 });
  } catch {
    map = null;  // no WebGL: planning, times and departures keep working
    $("#map").classList.add("nomap");
    $("#map").replaceChildren(h("p", {}, "The map needs WebGL, which is off on this device. Routes, times and departures still work."));
    return;
  }
  map.addControl(new maplibregl.AttributionControl({ compact: true }), "top-right");
  map.touchZoomRotate.disableRotation();
  map.on("style.load", addRouteLayers);
  map.on("moveend", () => { const c = map.getCenter(); store.set("view", { c: [+c.lng.toFixed(4), +c.lat.toFixed(4)], z: +map.getZoom().toFixed(1) }); });
  dark.addEventListener("change", () => map.setStyle(styleUrl()));
  map.on("contextmenu", (e) => placeMenu(e.lngLat));
  let timer = null;
  const cancel = () => { clearTimeout(timer); timer = null; };
  map.on("touchstart", (e) => { if (e.originalEvent.touches.length === 1) timer = setTimeout(() => placeMenu(e.lngLat), 550); });
  ["touchmove", "touchend", "touchcancel", "dragstart", "zoomstart"].forEach((t) => map.on(t, cancel));
  window.Vehicles?.init(map);
}
function addRouteLayers() {
  if (map.getSource("route")) return;
  map.addSource("route", { type: "geojson", data: routeData });
  const casing = css("--surface");
  map.addLayer({ id: "route-casing", type: "line", source: "route", layout: { "line-cap": "round", "line-join": "round" }, paint: { "line-color": casing, "line-width": 9, "line-opacity": 0.9 } });
  map.addLayer({ id: "route-solid", type: "line", source: "route", filter: ["!", ["get", "dashed"]], layout: { "line-cap": "round", "line-join": "round" }, paint: { "line-color": ["get", "color"], "line-width": 5.5 } });
  map.addLayer({ id: "route-dash", type: "line", source: "route", filter: ["get", "dashed"], layout: { "line-join": "round" }, paint: { "line-color": ["get", "color"], "line-width": 4.5, "line-dasharray": [1, 1.6] } });
}
function decode(str) {
  let i = 0, lat = 0, lon = 0;
  const out = [];
  while (i < str.length) {
    let b, s = 0, r = 0;
    do { b = str.charCodeAt(i++) - 63; r |= (b & 31) << s; s += 5; } while (b >= 32);
    lat += r & 1 ? ~(r >> 1) : r >> 1;
    s = 0; r = 0;
    do { b = str.charCodeAt(i++) - 63; r |= (b & 31) << s; s += 5; } while (b >= 32);
    lon += r & 1 ? ~(r >> 1) : r >> 1;
    out.push([lon / 1e5, lat / 1e5]);
  }
  return out;
}
function mapPad() {
  const r = $("#sheet").getBoundingClientRect(), wide = matchMedia("(min-width: 760px)").matches;
  return wide ? { top: 80, left: r.right + 24, right: 72, bottom: 40 } : { top: 90, left: 24, right: 24, bottom: Math.max(120, innerHeight - r.top + 16) };
}
function clearMarkers() { markers.forEach((m) => m.remove()); markers = []; }
function pin(cls, lngLat, c) {
  if (!map) return null;
  const el = h("div", { class: "pin " + cls, style: c ? { "--c": c } : {} });
  const m = new maplibregl.Marker({ element: el }).setLngLat(lngLat).addTo(map);
  markers.push(m);
  return m;
}
function drawRoute(it, opts = {}) {
  clearMarkers();
  window.Vehicles?.highlight(it.legs.map((l) => l.trip_id).filter(Boolean));
  if (!map) return;
  const feats = [], bounds = new maplibregl.LngLatBounds();
  it.legs.forEach((l, i) => {
    const pts = decode(l.geometry);
    if (pts.length < 2) return;
    pts.forEach((p) => bounds.extend(p));
    feats.push({ type: "Feature", properties: { color: color(l), dashed: !l.line }, geometry: { type: "LineString", coordinates: pts } });
    if (i > 0 && l.line) pin("xfer", [l.from.lon, l.from.lat], color(l));
  });
  routeData = { type: "FeatureCollection", features: feats };
  map.getSource("route")?.setData(routeData);
  const f = it.legs[0].from, t = it.legs[it.legs.length - 1].to;
  pin("", [f.lon, f.lat]);
  pin("to", [t.lon, t.lat]);
  if (opts.fit !== false && !bounds.isEmpty()) map.fitBounds(bounds, { padding: mapPad(), maxZoom: 16, duration: 600 });
}
function clearRoute() {
  clearMarkers();
  window.Vehicles?.highlight([]);
  routeData = { type: "FeatureCollection", features: [] };
  map?.getSource("route")?.setData(routeData);
}
function placeMenu(ll) {
  popup?.remove();
  if (!map) return;
  const pick = (which) => async () => {
    popup.remove();
    const p = await api("reverse", { lat: ll.lat, lon: ll.lng }).catch(() => ({ title: "Dropped pin", sub: "", lat: ll.lat, lon: ll.lng }));
    setPlace(which, p);
    setTab("plan");
    plan();
  };
  popup = new maplibregl.Popup({ closeButton: false, offset: 8 }).setLngLat(ll)
    .setDOMContent(h("div", { class: "popup-actions" }, h("button", { onclick: pick("from") }, "From here"), h("button", { onclick: pick("to") }, "To here")))
    .addTo(map);
}
function showMe(p) {
  S.me = p;
  if (!map) return;
  userMarker?.remove();
  userMarker = new maplibregl.Marker({ element: h("div", { class: "dot-user" }) }).setLngLat([p.lon, p.lat]).addTo(map);
}
function locate() {
  return new Promise((res) => {
    if (!navigator.geolocation) return res(null);
    navigator.geolocation.getCurrentPosition(
      (pos) => { const p = { lat: pos.coords.latitude, lon: pos.coords.longitude }; showMe(p); res(p); },
      () => res(null), { enableHighAccuracy: true, timeout: 10000, maximumAge: 30000 });
  });
}

// ---------------------------------------------------------------- sheet
const sheet = $("#sheet"), wide = matchMedia("(min-width: 760px)");
const heights = () => ({ peek: 168, half: Math.round(innerHeight * 0.5), full: Math.round(innerHeight * 0.9) });
function setDetent(name) {
  S.detent = name;
  sheet.dataset.detent = name;
  sheet.style.height = "";
}
(function grabber() {
  const g = $("#grabber");
  let y0 = 0, h0 = 0, t0 = 0, moved = false;
  g.addEventListener("pointerdown", (e) => { y0 = e.clientY; h0 = sheet.offsetHeight; t0 = performance.now(); moved = false; sheet.classList.add("dragging"); g.setPointerCapture(e.pointerId); });
  g.addEventListener("pointermove", (e) => {
    if (!g.hasPointerCapture(e.pointerId)) return;
    const dy = y0 - e.clientY;
    if (Math.abs(dy) > 4) moved = true;
    if (moved) sheet.style.height = Math.min(heights().full, Math.max(120, h0 + dy)) + "px";
  });
  g.addEventListener("pointerup", (e) => {
    sheet.classList.remove("dragging");
    if (!moved) return cycle();
    const v = (y0 - e.clientY) / Math.max(1, performance.now() - t0);
    const target = sheet.offsetHeight + v * 180, hs = heights();
    setDetent(Object.keys(hs).reduce((a, k) => (Math.abs(hs[k] - target) < Math.abs(hs[a] - target) ? k : a), "peek"));
  });
  g.addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); cycle(); } });
  function cycle() { setDetent({ peek: "half", half: "full", full: "peek" }[S.detent]); }
})();

// ---------------------------------------------------------------- tabs and panes
function setTab(t) {
  S.tab = t;
  $$("#tabs [role=tab]").forEach((b) => { const on = b.dataset.tab === t; b.setAttribute("aria-selected", on); b.tabIndex = on ? 0 : -1; });
  $("#view-plan").hidden = t !== "plan";
  $("#view-near").hidden = t !== "near";
  $("#view-info").hidden = t !== "info";
  if (t !== "near") stopTimer();
  if (t === "near" && !S.stop) loadNearby();
  if (t === "info") loadInfo();
  if (!wide.matches && S.detent === "peek" && t !== "plan") setDetent("half");
}
$("#tabs").addEventListener("click", (e) => { const b = e.target.closest("[data-tab]"); if (b) setTab(b.dataset.tab); });
$("#tabs").addEventListener("keydown", (e) => {
  if (!["ArrowLeft", "ArrowRight"].includes(e.key)) return;
  const tabs = $$("#tabs [role=tab]"), i = tabs.findIndex((b) => b.dataset.tab === S.tab);
  const n = tabs[(i + (e.key === "ArrowRight" ? 1 : tabs.length - 1)) % tabs.length];
  n.focus(); setTab(n.dataset.tab);
});
function pane(view, name) {
  $$(`#view-${view} > .pane`).forEach((p) => (p.hidden = p.id !== `${view}-${name}`));
}
$$("[data-back]").forEach((b) => b.addEventListener("click", () => {
  if (b.dataset.back === "plan") { pane("plan", "main"); S.sel = -1; if (S.results[0]) drawRoute(S.results[0]); }
  else { stopTimer(); S.stop = null; pane("near", "main"); }
}));

// ---------------------------------------------------------------- places and search
const field = { from: $("#from"), to: $("#to") };
function setPlace(which, p) {
  S[which] = p;
  field[which].value = p ? p.title : "";
  $(`[data-clear=${which}]`).hidden = !p;
  hashWrite();
}
function recents() { return store.get("recents", []); }
function remember(p) {
  const r = [p, ...recents().filter((x) => !(x.lat === p.lat && x.lon === p.lon))].slice(0, 8);
  store.set("recents", r);
}
let sugTimer = 0, sugCtl = null;
function searching(on) { $("#plan-main").classList.toggle("searching", on); $("#suggest").hidden = !on; }
function suggestRow(p, ic, on) {
  return h("li", { role: "option" }, h("button", { onclick: on }, icon(ic), h("span", { class: "grow" }, h("span", { class: "t1" }, p.title), p.sub ? h("span", { class: "t2" }, p.sub) : null)));
}
function renderSuggest(items, which, q) {
  const ul = $("#suggest");
  ul.replaceChildren();
  const choose = (p) => () => { remember(p); setPlace(which, p); searching(false); field[which].blur(); plan(); };
  if (which === "from" && !q) ul.append(suggestRow({ title: "Current location", sub: "Use my position" }, "locate", () => { setPlace("from", null); searching(false); field.from.blur(); plan(); }));
  if (!q) {
    const r = recents();
    if (r.length) ul.append(h("li", { class: "head" }, "Recent", h("button", { class: "text-btn", onclick: () => { store.set("recents", []); renderSuggest([], which, "") ; } }, "Clear")));
    r.forEach((p) => ul.append(suggestRow(p, "clock", choose(p))));
  } else if (!items.length) ul.append(h("li", { class: "head" }, "No matches"));
  items.forEach((p) => ul.append(suggestRow(p, "pin", choose(p))));
}
function onType(which) {
  S.active = which;
  clearTimeout(sugTimer);
  const q = field[which].value.trim();
  $(`[data-clear=${which}]`).hidden = !field[which].value;
  searching(true);
  if (!wide.matches) setDetent("full");
  if (q.length < 2) return renderSuggest([], which, "");
  sugTimer = setTimeout(async () => {
    sugCtl?.abort(); sugCtl = new AbortController();
    try {
      const c = map ? map.getCenter() : { lat: 50.06, lng: 19.94 };
      renderSuggest(await api("geocode", { q, lat: c.lat, lon: c.lng }, sugCtl.signal), which, q);
    } catch (e) { if (e.name !== "AbortError") $("#suggest").replaceChildren(h("li", { class: "head" }, e.message)); }
  }, 220);
}
for (const w of ["from", "to"]) {
  field[w].addEventListener("input", () => { if (!field[w].value) S[w] = null; onType(w); });
  field[w].addEventListener("focus", () => onType(w));
  field[w].addEventListener("keydown", (e) => {
    if (e.key === "Enter") { e.preventDefault(); $("#suggest button")?.click(); }
    if (e.key === "Escape") { searching(false); field[w].blur(); }
  });
}
$$("[data-clear]").forEach((b) => b.addEventListener("click", () => {
  const w = b.dataset.clear;
  setPlace(w, null); clearResults(); field[w].focus();
}));
$("#swap").addEventListener("click", () => {
  const a = S.from, b = S.to;
  setPlace("from", b); setPlace("to", a);
  plan();
});
$("#plan-main").addEventListener("click", (e) => { if (!e.target.closest(".fields, #suggest")) { searching(false); document.activeElement?.blur?.(); } });

// ---------------------------------------------------------------- options
function radios(root, attr, get, set) {
  root.addEventListener("click", (e) => {
    const b = e.target.closest(`[${attr}]`);
    if (!b) return;
    set(b.getAttribute(attr));
    $$(`[${attr}]`, root).forEach((x) => { const on = x === b; x.setAttribute("aria-checked", on); x.tabIndex = on ? 0 : -1; });
  });
  root.addEventListener("keydown", (e) => {
    if (!["ArrowLeft", "ArrowRight"].includes(e.key)) return;
    const bs = $$(`[${attr}]`, root), i = bs.findIndex((x) => x.getAttribute(attr) === get());
    bs[(i + (e.key === "ArrowRight" ? 1 : bs.length - 1)) % bs.length].focus();
    bs[(i + (e.key === "ArrowRight" ? 1 : bs.length - 1)) % bs.length].click();
  });
}
radios($("#modes"), "data-mode", () => S.mode, (v) => { S.mode = v; $("#transit-filter").hidden = v !== "transit"; plan(); });
radios($("#by"), "data-by", () => S.by, (v) => { S.by = v; if (v === "arrive" && !S.at) setAt(new Date(Date.now() + 36e5)); updateWhen(); plan(); });
$("#transit-filter").addEventListener("click", (e) => {
  const b = e.target.closest("[data-t]");
  if (!b) return;
  const on = b.getAttribute("aria-pressed") !== "true";
  if (!on && Object.values(S.transit).filter(Boolean).length === 1) return;
  S.transit[b.dataset.t] = on;
  b.setAttribute("aria-pressed", on);
  plan();
});
function localInput(d) {
  const p = Object.fromEntries(new Intl.DateTimeFormat("sv-SE", { timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).formatToParts(d).map((x) => [x.type, x.value]));
  return `${p.year}-${p.month}-${p.day}T${p.hour}:${p.minute}`;
}
function setAt(d) { S.at = d ? localInput(d) : ""; $("#at").value = S.at; }
function updateWhen() {
  const other = S.at && S.at.slice(0, 10) !== localInput(new Date()).slice(0, 10);
  $("#when-text").textContent = S.at ? `${S.by === "arrive" ? "Arrive by" : "Leave at"} ${S.at.slice(11)}${other ? ", " + df.format(new Date(S.at + ":00")) : ""}` : "Leave now";
}
$("#when").addEventListener("click", () => {
  const open = $("#when-panel").hidden;
  $("#when-panel").hidden = !open;
  $("#when").setAttribute("aria-expanded", open);
});
$("#at").addEventListener("change", (e) => { S.at = e.target.value; updateWhen(); plan(); });
$("#now").addEventListener("click", () => { S.at = ""; S.by = "depart"; $("#at").value = ""; $$("#by [data-by]").forEach((x) => x.setAttribute("aria-checked", x.dataset.by === "depart")); updateWhen(); plan(); });

// ---------------------------------------------------------------- planning
function clearResults() { $("#results").replaceChildren(); $("#status").replaceChildren(); S.results = []; clearRoute(); }
function status(msg, err = false) { const s = $("#status"); s.textContent = msg; s.classList.toggle("error", err); }
let planTimer = 0;
function plan() {
  clearTimeout(planTimer);
  planTimer = setTimeout(runPlan, 120);
}
async function runPlan() {
  hashWrite();
  if (!S.to) return clearResults();
  ctl?.abort(); ctl = new AbortController();
  pane("plan", "main");
  let from = S.from;
  if (!from) {
    status("Finding your location...");
    from = await locate();
    if (!from) return status("Allow location access or choose a starting point.", true);
  }
  searching(false);
  $("#results").replaceChildren(h("li", { class: "skeleton" }), h("li", { class: "skeleton" }));
  status("");
  if (!wide.matches && S.detent === "peek") setDetent("half");
  const params = { from: `${from.lat},${from.lon}`, to: `${S.to.lat},${S.to.lon}`, mode: S.mode, by: S.by, n: 3 };
  if (S.mode === "transit") params.transit = Object.keys(S.transit).filter((k) => S.transit[k]).join(",");
  if (S.at) params.at = S.at;
  try {
    const r = await api("plan", params, ctl.signal);
    S.results = r.itineraries.map((it) => ({ ...it, from, legs: it.legs.map((l, i, a) => ({ ...l, from: i === 0 ? { ...l.from, name: S.from?.title || "Current location" } : l.from, to: i === a.length - 1 ? { ...l.to, name: S.to.title } : l.to })) }));
    renderResults(r);
  } catch (e) {
    if (e.name === "AbortError") return;
    $("#results").replaceChildren();
    clearRoute();
    status(e.message === "signed out" ? "" : `Could not plan the trip: ${e.message}`, true);
  }
}
function ribbon(it) {
  const total = it.duration_s;
  return h("div", { class: "ribbon", "aria-hidden": "true" }, it.legs.map((l) => {
    const share = l.duration_s / total, c = color(l);
    const lbl = [];
    if (l.line) { lbl.push(icon(MODE_ICON[l.mode] || "transit")); if (share > 0.14) lbl.push(l.line); }
    else if (share > 0.08) lbl.push(icon(MODE_ICON[l.mode] || "walk"));
    return h("span", { class: "seg-leg" + (l.line ? "" : " street") + (l.realtime ? " live" : ""), style: { "flex-grow": Math.max(l.duration_s, total * 0.04), "--c": c } }, lbl);
  }));
}
function summary(it) {
  const transit = it.legs.filter((l) => l.line);
  const bits = [];
  if (transit.length) bits.push(transit.length === 1 ? "Direct" : `${transit.length - 1} transfer${transit.length > 2 ? "s" : ""}`);
  const walk = it.legs.filter((l) => l.mode === "WALK").reduce((a, l) => a + l.distance_m, 0);
  if (walk && transit.length) bits.push(`${dist(walk)} walking`);
  if (!transit.length) bits.push(dist(it.legs.reduce((a, l) => a + l.distance_m, 0)));
  return bits.join(" · ");
}
function renderResults(r) {
  const ul = $("#results");
  ul.replaceChildren();
  if (!S.results.length) {
    clearRoute();
    return status("No route found. Try another time, mode or transit type.", true);
  }
  status(r.by === "arrive" ? "Arriving by your chosen time" : "");
  S.results.forEach((it, i) => {
    const first = it.legs.find((l) => l.line);
    const day = dayTag(it.start);
    ul.append(h("li", {}, h("button", { class: "result", onclick: () => openDetail(i), "aria-label": `${hm(it.start)} to ${hm(it.end)}, ${dur(it.duration_s)}, ${summary(it)}` },
      h("div", { class: "times" }, h("time", {}, hm(it.start)), icon("chev"), h("time", {}, hm(it.end)), h("span", { class: "dur" }, dur(it.duration_s))),
      ribbon(it),
      h("div", { class: "sub" }, summary(it), day ? ` · ${day}` : "", first ? rtTag(first.delay_s, first.realtime) : null))));
  });
  drawRoute(S.results[0]);
}

// ---------------------------------------------------------------- itinerary detail
function openDetail(i) {
  S.sel = i;
  const it = S.results[i];
  pane("plan", "detail");
  $("#detail-title").textContent = `${hm(it.start)} to ${hm(it.end)}`;
  $("#plan-detail").scrollTop = 0;
  const d = $("#detail");
  d.replaceChildren();
  it.legs.forEach((l) => d.append(stepFor(l)));
  const last = it.legs[it.legs.length - 1];
  $("#start-nav").onclick = () => window.Guide?.start(it);
  d.append(h("div", { class: "step end", style: { "--c": "var(--accent)" } }, h("div", { class: "t" }, hm(it.end)), h("div", { class: "body" }, h("h3", {}, last.to.name))));
  drawRoute(it);
  if (!wide.matches && S.detent === "full") setDetent("half");
}
function stepFor(l) {
  const c = color(l), late = l.realtime && l.delay_s ? mins(l.delay_s) : 0;
  const left = h("div", { class: "t" }, h("time", {}, hm(l.start)), l.realtime && late ? h("small", {}, `sched ${hm(l.scheduled_start)}`) : null);
  if (l.line) {
    const stops = l.stops || [];
    const board = l.from.stop_id
      ? h("button", { class: "stop-btn", onclick: () => showStop({ id: l.from.stop_id, name: l.from.name, lat: l.from.lat, lon: l.from.lon }) }, l.from.name)
      : l.from.name;
    return h("div", { class: "step", style: { "--c": c } }, left,
      h("div", { class: "body" },
        h("h3", {}, badge(l.line, c, l.mode), l.headsign ? `to ${l.headsign}` : ""),
        h("div", { class: "meta" }, "Board at ", board),
        h("div", { class: "meta" }, rtTag(l.delay_s, l.realtime), ` · ${dur(l.duration_s)} · ${providerOf(l.agency)?.name || l.agency || ""}`),
        stops.length ? h("details", {}, h("summary", {}, `${stops.length + 1} stop${stops.length ? "s" : ""}`), h("ul", {}, stops.map((s) => h("li", {}, s.name)), h("li", {}, `${l.to.name}, ${hm(l.end)}`))) : null));
  }
  const name = { WALK: "Walk", BICYCLE: "Cycle", CAR: "Drive" }[l.mode] || l.mode;
  return h("div", { class: `step street m-${l.mode.toLowerCase()}`, style: { "--c": c } }, left,
    h("div", { class: "body" }, h("h3", {}, icon(MODE_ICON[l.mode] || "walk"), `${name} ${dist(l.distance_m)}`),
      h("div", { class: "meta" }, `${dur(l.duration_s)} to ${l.to.name}`),
      l.steps?.length ? h("details", {}, h("summary", {}, "Directions"), h("ul", {}, l.steps.filter((s) => s.m > 0).map((s) => h("li", {}, `${s.dir.replaceAll("_", " ")} ${s.street} ${dist(s.m)}`)))) : null));
}

// ---------------------------------------------------------------- nearby and departures
let depTimer = 0;
function stopTimer() { clearInterval(depTimer); depTimer = 0; }
function times(deps) { return deps.map((d) => h("span", { class: "badge", style: { "--c": providerOf(d.agency)?.color || "#44505c" } }, d.line, h("i", {}, d.time))); }
async function loadNearby() {
  const c = S.me || (() => { const m = map ? map.getCenter() : { lat: 50.06, lng: 19.94 }; return { lat: m.lat, lon: m.lng }; })();
  $("#near-status").textContent = "Looking for stops...";
  try {
    const stops = await api("nearby", { lat: c.lat, lon: c.lon, r: 600 });
    $("#near-status").textContent = stops.length ? (S.me ? "Around your location" : "Around the map centre") : "No stops within 600 m. Move the map and refresh.";
    const ul = $("#near-list");
    ul.replaceChildren(...stops.map((s) => h("li", {}, h("button", { class: "stopcard", onclick: () => showStop(s) },
      h("div", { class: "top" }, h("b", {}, s.name), s.code ? h("small", {}, s.code) : null, h("span", {}, dist(s.distance_m))),
      h("div", { class: "next" }, s.departures.length ? times(s.departures) : h("span", { class: "rt plan" }, "No departures soon"))))));
  } catch (e) { $("#near-status").textContent = e.message === "signed out" ? "" : e.message; }
}
$("#near-refresh").addEventListener("click", () => { S.me = null; userMarker?.remove(); loadNearby(); });
async function showStop(s) {
  S.stop = s;
  setTab("near");
  pane("near", "detail");
  $("#stop-title").textContent = s.name;
  clearMarkers();
  if (s.lat && map) { pin("to", [s.lon, s.lat]); map.flyTo({ center: [s.lon, s.lat], zoom: Math.max(map.getZoom(), 15), padding: mapPad() }); }
  const load = async () => {
    try {
      const r = await api("departures", { stop: s.id, n: 14 });
      $("#stop-status").textContent = r.departures.length ? "" : "No departures soon.";
      $("#stop-list").replaceChildren(...r.departures.map((d) => h("li", { class: "dep" },
        badge(d.line, providerOf(d.agency)?.color || "#44505c", "BUS"),
        h("span", { class: "to" }, d.to || ""),
        h("span", { class: "t" }, h("time", {}, d.time), h("small", {}, rtTag(d.delay_s, d.realtime))))));
    } catch (e) { $("#stop-status").textContent = e.message; }
  };
  await load();
  stopTimer();
  depTimer = setInterval(() => (document.hidden ? 0 : load()), 30000);
}

// ---------------------------------------------------------------- about
async function loadInfo() {
  const box = $("#info");
  let i = {};
  try { i = await api("info"); } catch { /* shown empty */ }
  box.replaceChildren(
    h("section", {}, h("h3", {}, "Routing data"), h("div", {}, i.built_at ? `Graph built ${new Date(i.built_at).toLocaleString("en-GB", { timeZone: TZ })}` : "Unknown"), h("div", {}, i.osm_data ? `OpenStreetMap data from ${i.osm_data.slice(0, 10)}` : "")),
    h("section", {}, h("h3", {}, "Operators"), h("ul", {}, providers.map((p) => h("li", {}, h("span", { class: "swatch", style: { "--c": p.color } }), p.name)))),
    h("section", {}, h("h3", {}, "Sources"), h("div", {}, "Map data © OpenStreetMap contributors (ODbL). Tiles by OpenFreeMap. Timetables and live data from the operators and PKP Polskie Linie Kolejowe S.A. Operator colours are approximate.")),
  );
}
$("#clear-recents").addEventListener("click", () => store.set("recents", []));
$("#logout").addEventListener("click", async () => { await fetch("/api/logout", { method: "POST", credentials: "same-origin" }); location.hash = ""; location.reload(); });

// ---------------------------------------------------------------- hash state
function hashWrite() {
  const p = new URLSearchParams();
  const pl = (k, v) => v && p.set(k, `${v.lat.toFixed(5)},${v.lon.toFixed(5)},${v.title}`);
  pl("f", S.from); pl("t", S.to);
  if (S.mode !== "transit") p.set("m", S.mode);
  if (S.at) { p.set("at", S.at); p.set("by", S.by); }
  history.replaceState(null, "", p.toString() ? "#" + p : location.pathname);
}
function hashRead() {
  const p = new URLSearchParams(location.hash.slice(1));
  const pl = (s) => { if (!s) return null; const [lat, lon, ...t] = s.split(","); return isFinite(lat) && isFinite(lon) ? { lat: +lat, lon: +lon, title: t.join(",") || "Pin", sub: "" } : null; };
  if (p.get("f")) setPlace("from", pl(p.get("f")));
  if (p.get("t")) setPlace("to", pl(p.get("t")));
  if (["walk", "bike", "car"].includes(p.get("m"))) $(`[data-mode=${p.get("m")}]`).click();
  if (p.get("at")) { S.at = p.get("at"); $("#at").value = S.at; if (p.get("by") === "arrive") $("[data-by=arrive]").click(); updateWhen(); }
}

// ---------------------------------------------------------------- start and login
$("#locate").addEventListener("click", async () => {
  const p = await locate();
  if (p && map) map.flyTo({ center: [p.lon, p.lat], zoom: Math.max(map.getZoom(), 14), padding: mapPad() });
});
function showLogin() { $("#login").hidden = false; $("#pass").focus(); }
$("#login-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const btn = $("#login-form .primary");
  btn.disabled = true;
  $("#login-err").textContent = "";
  try {
    const r = await fetch("/api/login", { method: "POST", credentials: "same-origin", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ secret: $("#pass").value }) });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(j.error || "Could not sign in");
    $("#pass").value = "";
    $("#login").hidden = true;
    start();
  } catch (err) { $("#login-err").textContent = err.message; }
  btn.disabled = false;
});

let started = false;
function start() {
  if (started) return;
  started = true;
  initMap();
  setDetent("peek");
  hashRead();
  if (S.to) plan();
}
(async function boot() {
  try { providers = (await (await fetch("/providers.json")).json()).providers; } catch { /* colours fall back to mode defaults */ }
  const r = await fetch("/api/session", { credentials: "same-origin" }).catch(() => null);
  if (r?.ok) start(); else showLogin();
  if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js").catch(() => {});
})();

// shared with guide.js (live navigation)
window.App = { localInput, S, api, h, icon, color, dist, dur, hm, mins, rtTag, badge, providerOf, setDetent, pane, mapPad, decode, store, $, $$, MODE_ICON, tf, getMap: () => map, getMe: () => userMarker, showMe, drawRoute, clearRoute, showLogin, replan: (r) => { S.results = [r]; S.sel = 0; openDetail(0); } };
