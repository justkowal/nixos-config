"use strict";
// Explore: general map browsing. Search, categories, place cards. Data is open only: OpenStreetMap, Wikipedia/Wikidata/Commons, Mangrove reviews,
// plus your own private ratings and notes stored on this server.
(() => {
  const A = window.App;
  const { api, h, icon, $, store } = A;
  const dist = A.dist;
  const CATS = [["all", "All"], ["food", "Food"], ["cafe", "Cafes"], ["bar", "Bars"], ["groceries", "Groceries"], ["pharmacy", "Pharmacies"], ["health", "Health"], ["fuel", "Fuel and charging"],
                ["atm", "ATMs"], ["parking", "Parking"], ["toilets", "Toilets"], ["hotels", "Hotels"], ["sights", "Sights"], ["parks", "Parks"], ["shops", "Shops"]];
  const OSM_ID = /^[NWR]\d{1,12}$/;
  let map = null, active = "all", place = null, searchedAt = null, marker = null, baseLayers = [], typeTimer = 0, typeCtl = null;

  async function send(method, path, body) {
    const r = await fetch(path, { method, credentials: "same-origin", headers: { "Content-Type": "application/json" }, body: body ? JSON.stringify(body) : undefined });
    if (r.status === 401) { A.showLogin(); throw new Error("signed out"); }
    if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || `error ${r.status}`);
    return r.json();
  }
  const center = () => {
    if (map) { const c = map.getCenter(); return { lat: c.lat, lon: c.lng }; }
    if (A.S.me) return A.S.me;
    return { lat: 50.06, lon: 19.94 };
  };
  const radiusFor = (z) => (z >= 16 ? 400 : z >= 15 ? 700 : z >= 14 ? 1200 : z >= 13 ? 2000 : 3000);
  const status = (t, err) => { const s = $("#ex-status"); s.textContent = t; s.classList.toggle("error", !!err); };

  // ---- map layers
  function layers() {
    if (!map.getSource("poi")) map.addSource("poi", { type: "geojson", data: { type: "FeatureCollection", features: [] } });
    const css = (n, d) => getComputedStyle(document.documentElement).getPropertyValue(n).trim() || d;
    const font = (map.getStyle().layers.find((l) => l.layout && l.layout["text-font"]) || { layout: {} }).layout["text-font"] || ["Noto Sans Regular"];
    if (!map.getLayer("poi-dot")) map.addLayer({ id: "poi-dot", type: "circle", source: "poi", paint: { "circle-radius": ["interpolate", ["linear"], ["zoom"], 10, 5, 16, 9], "circle-color": css("--accent", "#0b6e5c"), "circle-stroke-color": "#ffffff", "circle-stroke-width": 2 } });
    if (!map.getLayer("poi-label")) map.addLayer({ id: "poi-label", type: "symbol", source: "poi", minzoom: 14, layout: { "text-field": ["get", "title"], "text-font": font, "text-size": 12, "text-offset": [0, 1.2], "text-anchor": "top", "text-optional": true },
      paint: { "text-color": css("--ink", "#111"), "text-halo-color": css("--surface", "#fff"), "text-halo-width": 1.6 } });
    baseLayers = map.getStyle().layers.filter((l) => l["source-layer"] === "poi").map((l) => l.id);
  }
  function setMarkers(list) {
    map?.getSource("poi")?.setData({ type: "FeatureCollection", features: list.map((p) => ({ type: "Feature", properties: { id: p.id, title: p.title }, geometry: { type: "Point", coordinates: [p.lon, p.lat] } })) });
  }
  function init(m) {
    map = m;
    const startNearby = () => {
      layers();
      if ($("#explore-place").hidden && !searchedAt) loadCat("all", true);
    };
    map.on("style.load", startNearby);
    if (map.isStyleLoaded()) startNearby();
    map.on("click", (e) => {
      if (A.S.tab !== "explore") return;
      const f = map.queryRenderedFeatures(e.point, { layers: ["poi-dot", ...baseLayers].filter((id) => map.getLayer(id)) })[0];
      if (!f) return;
      if (f.layer.id === "poi-dot") return openPlace(f.properties.id);
      if (f.properties.name) openCoords({ lat: f.geometry.coordinates[1], lon: f.geometry.coordinates[0], title: f.properties.name });
    });
    map.on("mouseenter", "poi-dot", () => (map.getCanvas().style.cursor = "pointer"));
    map.on("mouseleave", "poi-dot", () => (map.getCanvas().style.cursor = ""));
    map.on("moveend", () => {
      if (!searchedAt) return;
      const c = center(), moved = Math.hypot((c.lat - searchedAt.lat) * 110540, (c.lon - searchedAt.lon) * 71000);
      $("#ex-here").hidden = moved < radiusFor(map.getZoom()) * 0.5;
    });
    $("#locate")?.addEventListener("click", () => {
      if (A.S.tab === "explore") {
        map?.once?.("moveend", () => {
          if (A.S.tab === "explore") loadCat(active || "all", true);
        });
      }
    });
  }

  // ---- categories
  function buildChips() {
    const box = $("#cats");
    box.replaceChildren();
    CATS.forEach(([k, name]) => box.append(h("button", { class: "chip", "aria-pressed": k === active ? "true" : "false", "data-cat": k, onclick: () => (active === k ? (k === "all" ? loadCat("all") : clearCat()) : loadCat(k)) }, name)));
    box.after(h("button", { id: "ex-here", class: "text-btn", hidden: true, onclick: () => loadCat(active || "all") }, "Search this area"));
  }
  function clearCat() {
    loadCat("all");
  }
  const $$all = (s) => [...document.querySelectorAll(s)];
  async function loadCat(cat = "all", keepDetent = false) {
    active = cat;
    $$all("#cats .chip").forEach((b) => b.setAttribute("aria-pressed", b.dataset.cat === cat ? "true" : "false"));
    $("#ex-suggest").hidden = true;
    const c = center(), r = radiusFor(map ? map.getZoom() : 14);
    status("Searching...");
    $("#ex-results").replaceChildren(h("li", { class: "skeleton" }), h("li", { class: "skeleton" }));
    try {
      const out = await api("explore", { cat, lat: c.lat, lon: c.lon, r });
      searchedAt = c; $("#ex-here").hidden = true;
      setMarkers(out.places);
      const isAll = cat === "all" || !cat;
      const count = out.places.length;
      if (count) {
        status(isAll ? `${count} places nearby within ${dist(r)}` : `${count} ${out.category.toLowerCase()} within ${dist(r)}`);
      } else {
        status(isAll ? `No places found within ${dist(r)}. Move the map and search again.` : `No ${out.category.toLowerCase()} within ${dist(r)}. Zoom out or move the map and search again.`);
      }
      $("#ex-results").replaceChildren(...out.places.map((p) => placeRow(p)));
      if (!isAll && out.places.length && map?.getZoom() > 15) map.easeTo({ zoom: 14.5, duration: 400 });
      if (!keepDetent && !A.sheetWide() && A.S.detent === "peek") A.setDetent("half");
    } catch (e) { $("#ex-results").replaceChildren(); status(e.message === "signed out" ? "" : `Could not search: ${e.message}`, true); }
  }
  function openBadge(open) {
    if (open == null) return null;
    return h("span", { class: "rt " + (open ? "live" : "plan") }, open ? "Open" : "Closed");
  }
  function placeRow(p) {
    return h("li", {}, h("button", { onclick: () => (OSM_ID.test(p.id) ? openPlace(p.id) : openCoords(p)) },
      icon("pin"), h("span", { class: "grow" }, h("span", { class: "t1" }, p.title), h("span", { class: "t2" }, [p.cat, p.dist_m != null ? dist(p.dist_m) : p.sub].filter(Boolean).join(" · "))), openBadge(p.open)));
  }

  // ---- search
  function onType() {
    clearTimeout(typeTimer);
    const q = $("#ex-q").value.trim();
    $("#ex-clear").hidden = !$("#ex-q").value;
    const box = $("#ex-suggest");
    if (q.length < 2) { box.hidden = true; return; }
    box.hidden = false;
    typeTimer = setTimeout(async () => {
      typeCtl?.abort(); typeCtl = new AbortController();
      try {
        const c = center();
        const items = await api("geocode", { q, lat: c.lat, lon: c.lon }, typeCtl.signal);
        box.replaceChildren(...(items.length ? items.map((p) => h("li", {}, h("button", { onclick: () => { box.hidden = true; $("#ex-q").blur(); p.osm ? openPlace(p.osm) : openCoords(p); } },
          icon("pin"), h("span", { class: "grow" }, h("span", { class: "t1" }, p.title), h("span", { class: "t2" }, [p.cat, p.sub].filter(Boolean).join(" · ")))))) : [h("li", { class: "head" }, "No matches")]));
      } catch (e) { if (e.name !== "AbortError") box.replaceChildren(h("li", { class: "head" }, e.message)); }
    }, 220);
  }

  // ---- place card
  function show(name) { A.pane("explore", name); }
  function pinAt(p) {
    marker?.remove();
    if (!map) return;
    marker = new maplibregl.Marker({ element: h("div", { class: "pin to" }) }).setLngLat([p.lon, p.lat]).addTo(map);
    map.flyTo({ center: [p.lon, p.lat], zoom: Math.max(map.getZoom(), 16.2), padding: A.mapPad(), duration: 700 });
  }
  async function openPlace(id) {
    show("place"); $("#place-title").textContent = ""; $("#place").replaceChildren(h("div", { class: "skeleton" }), h("div", { class: "skeleton" }));
    if (!A.sheetWide() && A.S.detent === "peek") A.setDetent("half");
    try {
      const card = await api("place", { id });
      render(card);
      history.replaceState(null, "", "#p=" + card.id);
      api("place/more", { id }).then((m) => fillMore(card, m)).catch(() => fillMore(card, null));
    } catch (e) { $("#place").replaceChildren(h("p", { class: "status error" }, e.message === "signed out" ? "" : `Could not load this place: ${e.message}`)); }
  }
  async function openCoords(p) {
    show("place"); $("#place").replaceChildren(h("div", { class: "skeleton" }));
    if (!A.sheetWide() && A.S.detent === "peek") A.setDetent("half");
    try { const card = await api("place", { lat: p.lat, lon: p.lon, name: p.title || "" }); render(card); api("place/more", { id: card.id }).then((m) => fillMore(card, m)).catch(() => fillMore(card, null)); history.replaceState(null, "", "#p=" + card.id); return; } catch { /* not a mapped place: plain card */ }
    let addr = p.sub || "";
    if (!addr) { try { addr = (await api("reverse", { lat: p.lat, lon: p.lon })).sub || ""; } catch { /* no address */ } }
    render({ id: `X${p.lat.toFixed(5)},${p.lon.toFixed(5)}`, title: p.title || "Dropped pin", cat: "Place", lat: p.lat, lon: p.lon, address: addr, attributes: [], hours: { raw: null, open: null, text: "", week: [] }, plain: true });
  }
  const row = (label, node) => (node ? h("div", { class: "kv" }, h("span", { class: "k" }, label), h("span", { class: "v" }, node)) : null);
  const link = (href, text, ext) => h("a", { href, ...(ext ? { target: "_blank", rel: "noopener noreferrer" } : {}) }, text);
  function render(card) {
    place = card;
    $("#place-title").textContent = card.title;
    pinAt(card);
    const hrs = card.hours || {};
    const saved = h("button", { class: "act", "aria-pressed": !!card.saved, onclick: () => toggleSave(card, saved) }, icon("pin"), card.saved ? "Saved" : "Save");
    const share = h("button", { class: "act", onclick: () => doShare(card) }, icon("swap"), "Share");
    const dir = h("button", { class: "primary", onclick: () => directions(card) }, icon("nav"), "Directions");
    const body = [
      h("div", { id: "place-media" }),
      h("div", { class: "place-head" }, h("h1", {}, card.title), h("div", { class: "t2" }, [card.cat, card.address].filter(Boolean).join(" · "))),
      hrs.text ? h("div", { class: "place-open" }, openBadge(hrs.open), " ", h("b", {}, hrs.text)) : null,
      h("div", { class: "acts" }, dir, saved, share, card.phone ? h("a", { class: "act", href: "tel:" + card.phone.replace(/[^\d+]/g, "") }, "Call") : null, card.website ? h("a", { class: "act", href: card.website, target: "_blank", rel: "noopener noreferrer" }, "Website") : null),
      card.attributes?.length ? h("div", { class: "attrs" }, card.attributes.map((a) => h("span", { class: "attr" }, a))) : null,
      h("div", { id: "place-about" }),
      hrs.week?.length ? h("details", { class: "sect" }, h("summary", {}, "Opening hours"), h("ul", { class: "plain" }, hrs.week.map((d) => h("li", {}, d)))) : hrs.raw ? row("Hours", hrs.raw) : null,
      h("div", { class: "kvs" }, row("Address", card.address), row("Phone", card.phone && link("tel:" + card.phone.replace(/[^\d+]/g, ""), card.phone)), row("Email", card.email && link("mailto:" + card.email, card.email)), row("Website", card.website && link(card.website, card.website.replace(/^https?:\/\/(www\.)?/, ""), true)),
        row("Coordinates", `${card.lat.toFixed(5)}, ${card.lon.toFixed(5)}`), card.osm_url ? row("OpenStreetMap", link(card.osm_url, "View and edit this place", true)) : null),
      h("section", { class: "sect", id: "place-reviews" }, h("h3", {}, "Reviews"), h("div", { id: "open-reviews", class: "t2" }, card.plain ? "Reviews are available for mapped places." : "Looking for open reviews..."), notebox(card)),
    ];
    $("#place").replaceChildren(...body.filter(Boolean));
  }
  function fillMore(card, m) {
    if (!place || place.id !== card.id) return;
    const about = $("#place-about"), media = $("#place-media"), rev = $("#open-reviews");
    if (m?.photo) media?.replaceChildren(h("figure", { class: "photo" }, h("img", { src: m.photo, alt: card.title, loading: "lazy", onerror: (e) => e.target.closest("figure").remove() }), h("figcaption", {}, "Photo: Wikimedia Commons")));
    if (m?.description) about?.replaceChildren(h("section", { class: "sect" }, h("h3", {}, "About"), h("p", { class: "about" }, m.description.text),
      h("p", { class: "credit" }, "Source: ", m.description.url ? link(m.description.url, m.description.source, true) : m.description.source, ` (${m.description.license})`)));
    if (!rev) return;
    const r = m?.reviews;
    rev.replaceChildren(...(r && r.count ? [h("div", { class: "avg" }, h("b", {}, `${r.average} / 5`), ` from ${r.count} open review${r.count > 1 ? "s" : ""}`), ...r.reviews.slice(0, 5).map((x) => h("blockquote", {}, h("b", {}, `${x.rating} / 5`), x.text ? ` ${x.text}` : "", x.date ? h("span", { class: "t2" }, ` ${x.date}`) : null)),
      h("p", { class: "credit" }, "Open reviews from Mangrove Reviews (CC BY).")]
      : [h("p", {}, "No open reviews for this place yet."), h("p", { class: "credit" }, "Only open sources are used: Mangrove Reviews has few places in Poland, and Google, Yelp and similar services are proprietary. Your own rating below stays private on this server.")]));
  }
  function notebox(card) {
    let rating = card.note?.rating || 0;
    const stars = h("div", { class: "stars", role: "group", "aria-label": "Your rating" });
    const text = h("textarea", { rows: 3, maxlength: 1500, placeholder: "Private note: what was it like?", "aria-label": "Your private note" }, card.note?.text || "");
    const paint = () => [...stars.children].forEach((b, i) => b.setAttribute("aria-pressed", i < rating));
    for (let n = 1; n <= 5; n++) stars.append(h("button", { class: "star", "aria-label": `${n} of 5`, onclick: () => { rating = rating === n ? 0 : n; paint(); } }, icon("star")));
    paint();
    const msg = h("span", { class: "t2", role: "status" });
    const save = h("button", { class: "text-btn", onclick: async () => { try { await send("POST", "/api/v1/notes", { place: card.id, rating, text: text.value }); msg.textContent = "Saved privately"; } catch (e) { msg.textContent = e.message; } } }, "Save my rating");
    return h("div", { class: "mine" }, h("div", { class: "t1" }, "Your rating"), stars, text, h("div", { class: "row-end" }, msg, save));
  }
  function directions(card) {
    A.setPlace("to", { title: card.title, sub: card.address || card.cat, lat: card.lat, lon: card.lon });
    A.setTab("plan");
    A.runPlan();
  }
  async function toggleSave(card, btn) {
    try {
      if (card.saved) await send("DELETE", "/api/v1/saved?id=" + encodeURIComponent(card.id));
      else await send("POST", "/api/v1/saved", { id: card.id, title: card.title, lat: card.lat, lon: card.lon, cat: card.cat });
      card.saved = !card.saved;
      btn.setAttribute("aria-pressed", card.saved);
      btn.lastChild.textContent = card.saved ? "Saved" : "Save";
    } catch (e) { btn.title = e.message; }
  }
  async function doShare(card) {
    const url = OSM_ID.test(card.id) ? `${location.origin}/#p=${card.id}` : `https://www.openstreetmap.org/?mlat=${card.lat}&mlon=${card.lon}#map=18/${card.lat}/${card.lon}`;
    try { if (navigator.share) await navigator.share({ title: card.title, url }); else { await navigator.clipboard.writeText(url); $("#place-title").textContent = "Link copied"; setTimeout(() => ($("#place-title").textContent = card.title), 1500); } } catch { /* cancelled */ }
  }

  // ---- saved places
  async function loadSaved() {
    try {
      const list = await api("saved");
      $("#saved-box").hidden = !list.length;
      $("#saved-list").replaceChildren(...list.map((p) => placeRow({ id: p.id, title: p.title, cat: p.cat, lat: p.lat, lon: p.lon })));
    } catch { /* not signed in yet or offline */ }
  }

  function back() {
    place = null; marker?.remove(); marker = null;
    history.replaceState(null, "", location.pathname);
    show("main");
    loadSaved();
    if (!searchedAt) loadCat(active || "all", true);
  }
  function onShow() {
    if ($("#explore-place").hidden) {
      loadSaved();
      if (!searchedAt) loadCat(active || "all", true);
    }
  }
  function fromHash() {
    const id = new URLSearchParams(location.hash.slice(1)).get("p");
    if (id && OSM_ID.test(id)) openPlace(id);
  }

  buildChips();
  $("#ex-q").addEventListener("input", onType);
  $("#ex-q").addEventListener("focus", () => { onType(); if (!A.sheetWide()) A.setDetent("full"); });
  $("#ex-q").addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); $("#ex-suggest button")?.click(); } if (e.key === "Escape") { $("#ex-suggest").hidden = true; $("#ex-q").blur(); } });
  $("#ex-clear").addEventListener("click", () => { $("#ex-q").value = ""; $("#ex-clear").hidden = true; $("#ex-suggest").hidden = true; $("#ex-q").focus(); });

  window.Explore = { init, back, onShow, fromHash, openPlace, openCoords };
  if (typeof window !== "undefined" && window.App?.getMap?.()) {
    init(window.App.getMap());
  }
})();
