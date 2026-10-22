"use strict";
// Live guidance: follows the device along the chosen itinerary, snaps GPS fixes to it, replans when off route.
// Only runs while the page is in the foreground: browsers pause geolocation for backgrounded PWAs, so a wake lock keeps the screen on.
(() => {
  const A = window.App;
  const { S, api, h, icon, hm, dist, dur, $ } = A;
  const K = 111320;
  const G = { on: false, it: null, pts: [], legs: [], hint: 0, off: 0, watch: 0, wake: null, voice: A.store.get("voice", false), follow: true, lastKey: "", lastReroute: 0,
              stopAlong: {}, said: new Set(), notice: "", noticeUntil: 0, lastEval: 0, evalDelays: "", target: 0, sim: 0, lastFix: null, timer: 0, heading: null, arrivedAt: 0 };

  const DIR = { LEFT: ["Turn left", -90], RIGHT: ["Turn right", 90], SLIGHTLY_LEFT: ["Bear left", -45], SLIGHTLY_RIGHT: ["Bear right", 45], HARD_LEFT: ["Turn sharp left", -135], HARD_RIGHT: ["Turn sharp right", 135],
                UTURN_LEFT: ["Make a U-turn", 180], UTURN_RIGHT: ["Make a U-turn", 180], CONTINUE: ["Continue", 0], DEPART: ["Head out", 0], CIRCLE_CLOCKWISE: ["Take the roundabout", 0], CIRCLE_COUNTERCLOCKWISE: ["Take the roundabout", 0] };
  const GENERIC = /^(path|sidewalk|footway|crossing|steps|cycleway|service road|track|-?)$/i;

  // ---- geometry in metres around the route
  let k = 1;
  const xy = (lon, lat) => [lon * k * K, lat * 110540];
  const gap = (a, b) => { const [ax, ay] = xy(a.lon, a.lat), [bx, by] = xy(b.lon, b.lat); return Math.hypot(ax - bx, ay - by); };
  function build(it) {
    const mid = it.legs[0].from.lat;
    k = Math.cos((mid * Math.PI) / 180);
    const pts = [], legs = [];
    let cum = 0;
    it.legs.forEach((l, li) => {
      let g = A.decode(l.geometry || "");
      if (g.length < 2) g = [[l.from.lon, l.from.lat], [l.to.lon, l.to.lat]];
      const i0 = pts.length;
      for (const [lon, lat] of g) {
        const [x, y] = xy(lon, lat);
        const last = pts[pts.length - 1];
        if (last) cum += Math.hypot(x - last.x, y - last.y);
        pts.push({ x, y, lon, lat, cum });
      }
      legs.push({ li, i0, i1: pts.length - 1, c0: pts[i0].cum, c1: cum });
    });
    G.pts = pts; G.legs = legs; G.hint = 0; G.stopAlong = {}; G.said.clear();
  }
  function project(px, py, a, b) {
    let best = { d: Infinity };
    for (let i = a; i <= b; i++) {
      const p = G.pts[i], q = G.pts[i + 1];
      const dx = q.x - p.x, dy = q.y - p.y, len2 = dx * dx + dy * dy;
      const t = len2 ? Math.max(0, Math.min(1, ((px - p.x) * dx + (py - p.y) * dy) / len2)) : 0;
      const d = Math.hypot(px - (p.x + t * dx), py - (p.y + t * dy));
      if (d < best.d) best = { d, i, along: p.cum + t * Math.sqrt(len2) };
    }
    return best;
  }
  function snap(px, py) {
    let best = project(px, py, Math.max(0, G.hint - 3), Math.min(G.pts.length - 2, G.hint + 90));
    if (best.d > 120) best = project(px, py, 0, G.pts.length - 2);
    G.hint = best.i;
    return best;
  }
  const legAt = (along) => G.legs.find((l) => along <= l.c1 + 0.5) || G.legs[G.legs.length - 1];
  const limitFor = (leg) => (leg.line ? 130 : leg.mode === "CAR" ? 60 : 40);

  // ---- speech and haptics
  function say(text) {
    if (G.voice && "speechSynthesis" in window) {
      speechSynthesis.cancel();
      const u = new SpeechSynthesisUtterance(text);
      u.lang = "en-GB";
      speechSynthesis.speak(u);
    }
    navigator.vibrate?.(120);
  }

  // ---- instruction for the current position
  function late(l) { return l.realtime && l.delay_s >= 60 ? `, ${A.mins(l.delay_s)} min late` : ""; }
  function instruction(along, pos, now) {
    const seg = legAt(along), L = G.it.legs[seg.li], next = G.it.legs[seg.li + 1];
    const left = Math.max(0, seg.c1 - along);
    if (!L.line) {
      const steps = (L.steps || []).filter((s) => s.m > 0);
      const total = steps.reduce((a, s) => a + s.m, 0) || 1, scale = (seg.c1 - seg.c0) / total;
      const prog = along - seg.c0;
      let acc = 0, idx = 0;
      for (; idx < steps.length; idx++) { if (prog < acc + steps[idx].m * scale) break; acc += steps[idx].m * scale; }
      const nxt = steps[idx + 1];
      const thenTxt = next?.line ? `Then board ${next.line} to ${next.headsign || next.to.name}, ${hm(next.start)}${late(next)}` : "";
      if (nxt && left > 60) {
        const [verb, deg] = DIR[nxt.dir.toUpperCase()] || ["Continue", 0];
        const onto = GENERIC.test(nxt.street) ? "" : ` onto ${nxt.street}`;
        return { key: `s${seg.li}-${idx}`, deg, meters: acc + steps[idx].m * scale - prog, text: verb + onto, then: thenTxt };
      }
      const target = next?.line ? next.from.name : L.to.name;
      return { key: `e${seg.li}`, deg: 0, meters: left, text: next?.line ? `Walk to ${target}` : `Continue to ${target}`, then: thenTxt };
    }
    const stops = [...(L.stops || []), { name: L.to.name, lat: L.to.lat, lon: L.to.lon }];
    const boarded = along > seg.c0 + 100 || (pos.speed ?? 0) > 4;
    if (!boarded) {
      const wait = Math.round((Date.parse(L.start) - now) / 60000);
      return { key: `b${seg.li}`, leg: seg.li, icon: L.mode, meters: null, text: `Board ${L.line} to ${L.headsign || L.to.name}`,
               then: `${L.from.name}, ${hm(L.start)}${late(L)}${wait > 0 ? `, in ${wait} min` : wait === 0 ? ", now" : ""}` };
    }
    // position of each stop along the route, so a skipped GPS fix cannot leave the countdown behind
    if (!G.stopAlong[seg.li]) G.stopAlong[seg.li] = stops.map((st) => project(...xy(st.lon, st.lat), seg.i0, Math.max(seg.i0, seg.i1 - 1)).along);
    let i = G.stopAlong[seg.li].findIndex((a) => a > along + 25);
    if (i < 0) i = stops.length - 1;
    const remaining = stops.length - i;
    return { key: `t${seg.li}-${remaining === 1 ? "last" : i}`, leg: seg.li, icon: L.mode, meters: left,
             text: remaining === 1 ? `Get off at ${L.to.name}` : `${remaining} stops to ${L.to.name}`,
             then: remaining > 1 ? `Next stop: ${stops[i].name}` : next ? `Then ${next.line ? "board " + next.line : "walk to " + next.to.name}` : "" };
  }

  // ---- UI
  function render(ins, now) {
    const arrow = $("#g-arrow");
    arrow.replaceChildren(ins.icon ? icon(A.MODE_ICON[ins.icon] || "transit") : icon("arrow"));
    arrow.style.transform = ins.icon ? "" : `rotate(${ins.deg}deg)`;
    $("#g-dist").textContent = ins.meters != null ? dist(Math.max(0, ins.meters)) : "";
    $("#g-text").textContent = ins.text;
    $("#g-then").textContent = ins.then || "";
    const tl = (ins.leg && G.it.legs[ins.leg].line ? G.it.legs[ins.leg] : null) || G.it.legs.slice(legAt(G.cur || 0).li).find((l) => l.line);
    $("#g-live").replaceChildren(tl ? A.rtTag(tl.delay_s, tl.realtime) : "");
    $("#g-notice").textContent = now < G.noticeUntil ? G.notice : "";
    const last = G.it.legs[G.it.legs.length - 1], end = Date.parse(last.end);
    $("#g-eta").textContent = `Arrive ${hm(last.end)}`;
    $("#g-left").textContent = ` · ${dur(Math.max(0, (end - now) / 1000))}`;
  }
  function follow(pos) {
    const map = A.getMap();
    A.showMe({ lat: pos.lat, lon: pos.lon });
    if (!map || !G.follow) return;
    map.easeTo({ center: [pos.lon, pos.lat], zoom: G.it.legs[legAt(G.cur || 0).li].line ? 15.5 : 17, bearing: G.heading ?? map.getBearing(), pitch: window.Vehicles?.is3d?.() ? 55 : 0,
                 padding: { top: 190, bottom: 130, left: 0, right: 0 }, duration: 900, essential: true });
  }

  // ---- fixes
  function onFix(f) {
    if (!G.on) return;
    if (f.acc > 100) return;
    const now = Date.now();
    const prev = G.lastFix;
    if (f.heading != null && !Number.isNaN(f.heading) && (f.speed ?? 0) > 1) G.heading = f.heading;
    else if (prev && gap(f, prev) > 8) {
      const [ax, ay] = xy(prev.lon, prev.lat), [bx, by] = xy(f.lon, f.lat);
      G.heading = ((Math.atan2(bx - ax, by - ay) * 180) / Math.PI + 360) % 360;
    }
    if (!prev || gap(f, prev) > 3) G.lastFix = f;
    const [x, y] = xy(f.lon, f.lat);
    const s = snap(x, y);
    G.cur = s.along;
    const seg = legAt(s.along), leg = G.it.legs[seg.li];
    G.off = s.d > limitFor(leg) ? G.off + 1 : 0;
    if (G.off >= 3) { G.off = 0; return reroute(f); }
    const ins = instruction(s.along, { x, y, speed: f.speed }, now);
    if (leg.line && leg.trip_id && ins.key.startsWith("t")) window.Vehicles?.rideSync?.(leg.trip_id, f);  // aboard: the vehicle is where the passenger is
    const finalLeg = seg.li === G.it.legs.length - 1;
    if (finalLeg && !leg.line && seg.c1 - s.along < 25) return arrive();
    render(ins, now);
    if (ins.key !== G.lastKey) { G.lastKey = ins.key; say(ins.text + (ins.meters != null && ins.meters > 80 ? `, in ${dist(ins.meters).replace(" m", " metres")}` : "")); }
    else if (ins.meters != null && ins.meters < 120 && !G.said.has(ins.key + "n")) { G.said.add(ins.key + "n"); say(ins.text); }
    follow({ lat: f.lat, lon: f.lon });
  }
  function arrive() {
    $("#g-arrow").replaceChildren(icon("flag"));
    $("#g-arrow").style.transform = "";
    $("#g-dist").textContent = "";
    $("#g-text").textContent = "You have arrived";
    $("#g-then").textContent = G.it.legs[G.it.legs.length - 1].to.name;
    say("You have arrived");
    if (!G.arrivedAt) G.arrivedAt = Date.now();
    setTimeout(() => G.arrivedAt && stop(), 15000);
  }
  const norm = (it, fromName) => ({ ...it, legs: it.legs.map((l, i, a) => ({ ...l, from: i === 0 && fromName ? { ...l.from, name: fromName } : l.from, to: i === a.length - 1 ? { ...l.to, name: S.to.title } : l.to })) });
  function note(text) { G.notice = text; G.noticeUntil = Date.now() + 15000; say(text); }
  // best way to reach the destination from origin: first try to arrive by the target, else the earliest arrival
  async function search(origin, notBefore, target) {
    const base = { from: `${origin.lat},${origin.lon}`, to: `${S.to.lat},${S.to.lon}`, mode: S.mode, n: 3 };
    if (S.mode === "transit") {
      base.transit = Object.keys(S.transit).filter((q) => S.transit[q]).join(",");
      for (const [k, v] of Object.entries(S.headroom || {})) {
        if (v > 0) base[`headroom_${k}`] = v;
      }
    }
    if (target) {
      const r = await api("plan", { ...base, by: "arrive", at: A.localInput(new Date(target)) });
      const ok = r.itineraries.filter((i) => Date.parse(i.end) <= target + 30000 && Date.parse(i.start) >= notBefore - 60000);
      if (ok.length) return ok.reduce((a, b) => (Date.parse(b.start) > Date.parse(a.start) ? b : a));
    }
    const r = await api("plan", { ...base, by: "depart", at: A.localInput(new Date(notBefore)) });
    return r.itineraries.length ? r.itineraries.reduce((a, b) => (Date.parse(b.end) < Date.parse(a.end) ? b : a)) : null;
  }
  // can the traveller still make every vehicle, given live times? returns the projected arrival
  function projection(along, now) {
    const cur = legAt(along);
    let t = now, bad = null;
    G.it.legs.forEach((l, i) => {
      if (i < cur.li) return;
      if (l.line) {
        const boardedHere = i === cur.li && along > cur.c0 + 100;
        if (!boardedHere && t > Date.parse(l.start) + 45000 && !bad) bad = { leg: i, why: `${l.line} will be missed` };
        t = Math.max(t, Date.parse(l.end));
      } else {
        const seg = G.legs[i], rest = i === cur.li ? (seg.c1 - along) / Math.max(1, seg.c1 - seg.c0) : 1;
        t += l.duration_s * rest * 1000;
      }
    });
    return { arrive: t, bad };
  }
  async function evaluate(f, force) {
    const now = Date.now();
    if (!G.on || G.busy || now - G.lastEval < 45000 && !force) return;
    const fp = G.it.legs.filter((l) => l.line).map((l) => `${l.start}|${l.end}`).join(",");
    if (!force && fp === G.evalDelays) return;
    G.lastEval = now; G.busy = true;
    try {
      const pos = f || G.lastFix;
      if (!pos) return;
      const { arrive, bad } = projection(G.cur || 0, now);
      G.evalDelays = fp;
      const late = arrive > G.target + 5 * 60000;
      if (!bad && !late && !force) return;
      const seg = legAt(G.cur || 0), L = G.it.legs[seg.li];
      const onBoard = L.line && (G.cur || 0) > seg.c0 + 100;
      const origin = onBoard ? { lat: L.to.lat, lon: L.to.lon } : { lat: pos.lat, lon: pos.lon };
      const notBefore = onBoard ? Date.parse(L.end) : now;
      const cand = await search(origin, notBefore, G.target);
      if (!cand) return;
      const better = bad || force || Date.parse(cand.end) <= arrive - 3 * 60000;
      if (!better) return;
      const fresh = norm(cand, onBoard ? L.to.name : "Current location");
      G.it = onBoard ? { ...fresh, start: G.it.start, legs: [...G.it.legs.slice(0, seg.li + 1), ...fresh.legs] } : fresh;
      G.lastKey = ""; G.hint = 0;
      build(G.it);
      A.drawRoute(G.it, { fit: false });
      note(`${bad ? bad.why + ". " : "Delays changed. "}New route, arriving ${hm(G.it.end)}${Date.parse(G.it.end) > G.target + 60000 ? ", " + A.mins((Date.parse(G.it.end) - G.target) / 1000) + " min later than planned" : ""}`);
    } catch { /* keep the current route */ } finally { G.busy = false; }
  }
  async function reroute(f) {
    if (Date.now() - G.lastReroute < 20000) return;
    G.lastReroute = Date.now();
    $("#g-text").textContent = "Rerouting...";
    say("Rerouting");
    await evaluate(f, true);
  }

  // ---- live times of the trips still ahead
  async function refreshTrips() {
    await refreshTripsInner();
    evaluate();
  }
  async function refreshTripsInner() {
    const cur = legAt(G.cur || 0).li;
    for (const [i, l] of G.it.legs.entries()) {
      if (i < cur || !l.line || !l.trip_id || i > cur + 1) continue;
      try {
        const day = new Intl.DateTimeFormat("sv-SE", { timeZone: "Europe/Warsaw" }).format(new Date(l.scheduled_start));
        const t = await api("trip", { id: l.trip_id, date: day });
        const at = (name) => t.stops.find((s) => s.stop === name);
        const a = at(l.from.name), b = at(l.to.name);
        if (a && a.realtime) { l.delay_s = a.delay_s; l.realtime = true; l.start = new Date(Date.parse(l.scheduled_start) + (a.delay_s || 0) * 1000).toISOString(); }
        if (b && b.realtime) l.end = new Date(Date.parse(l.scheduled_end) + (b.delay_s || 0) * 1000).toISOString();
      } catch { /* keep the last known times */ }
    }
  }

  // ---- lifecycle
  function wake() {
    if (!G.on || !navigator.wakeLock) return;
    navigator.wakeLock.request("screen").then((l) => { G.wake = l; }).catch(() => {});
  }
  function start(it) {
    G.it = JSON.parse(JSON.stringify(it));
    build(G.it);
    G.on = true; G.follow = true; G.lastKey = ""; G.lastFix = null; G.heading = null; G.off = 0; G.arrivedAt = 0; G.cur = 0; G.target = Date.parse(G.it.end); G.evalDelays = ''; G.lastEval = 0;
    $("#sheet").hidden = true; $("#tabs").hidden = true; $("#mapctl").hidden = true; $("#guide").hidden = false;
    $("#g-voice").setAttribute("aria-pressed", G.voice);
    $("#g-recenter").hidden = true;
    A.drawRoute(G.it, { fit: false });
    wake();
    if (window.__sim) simulate();
    else if (navigator.geolocation) {
      G.watch = navigator.geolocation.watchPosition((p) => onFix({ lat: p.coords.latitude, lon: p.coords.longitude, acc: p.coords.accuracy, heading: p.coords.heading, speed: p.coords.speed }),
        (e) => { $("#g-text").textContent = e.code === 1 ? "Location access is blocked. Allow it for this site to navigate." : "Waiting for a GPS fix..."; },
        { enableHighAccuracy: true, maximumAge: 1000, timeout: 20000 });
    } else $("#g-text").textContent = "This device has no location support.";
    $("#g-text").textContent = "Waiting for a GPS fix...";
    G.timer = setInterval(() => (document.hidden ? 0 : refreshTrips()), 45000);
    refreshTrips();
  }
  function stop() {
    if (!G.on) return;
    G.on = false; G.arrivedAt = 0;
    if (G.watch) navigator.geolocation.clearWatch(G.watch);
    clearInterval(G.timer); clearInterval(G.sim); G.watch = 0; G.sim = 0;
    G.wake?.release?.().catch?.(() => {}); G.wake = null;
    speechSynthesis?.cancel?.();
    $("#guide").hidden = true; $("#sheet").hidden = false; $("#tabs").hidden = false; $("#mapctl").hidden = false;
    const map = A.getMap();
    map?.easeTo({ bearing: 0, pitch: window.Vehicles?.is3d?.() ? 58 : 0, padding: { top: 0, bottom: 0, left: 0, right: 0 }, duration: 500 });
    A.replan(G.it);
  }

  // development aid: #sim=1 replays the route at walking-to-bus speed so the UI can be checked without moving
  function simulate() {
    let s = 0;
    G.sim = setInterval(() => {
      s += window.__simSpeed || 14;
      const total = G.pts[G.pts.length - 1].cum;
      if (s > total) s = total;
      let i = 0;
      while (i < G.pts.length - 2 && G.pts[i + 1].cum < s) i++;
      const p = G.pts[i], q = G.pts[i + 1], t = q.cum > p.cum ? (s - p.cum) / (q.cum - p.cum) : 0;
      const heading = ((Math.atan2(q.x - p.x, q.y - p.y) * 180) / Math.PI + 360) % 360;
      onFix({ lat: p.lat + (q.lat - p.lat) * t, lon: p.lon + (q.lon - p.lon) * t, acc: 5, heading, speed: 10 });
    }, 1000);
  }

  $("#g-end").addEventListener("click", stop);
  $("#g-voice").addEventListener("click", () => { G.voice = !G.voice; A.store.set("voice", G.voice); $("#g-voice").setAttribute("aria-pressed", G.voice); if (G.voice) say("Voice guidance on"); });
  $("#g-recenter").addEventListener("click", () => { G.follow = true; $("#g-recenter").hidden = true; });
  document.addEventListener("visibilitychange", () => { if (!document.hidden) wake(); });
  let tries = 0;
  const hook = setInterval(() => {
    const map = A.getMap();
    if (!map) { if (++tries > 20) clearInterval(hook); return; }
    clearInterval(hook);
    map.on("dragstart", (e) => { if (G.on && e.originalEvent) { G.follow = false; $("#g-recenter").hidden = false; } });
  }, 500);

  window.Guide = { start, stop, _onFix: onFix };
})();
