"use strict";
const $ = (id) => document.getElementById(id);
const KEY = "lab-token";
let armed = null;
let sceneKey = "";

function token() { try { return localStorage.getItem(KEY) || ""; } catch (e) { return ""; } }

async function api(path, opts) {
  const res = await fetch(path, Object.assign({ headers: { Authorization: "Bearer " + token() } }, opts));
  if (res.status === 401) throw new Error("unauthorized");
  if (!res.ok) throw new Error("HTTP " + res.status);
  return res.json();
}

function age(ts) {
  const s = Math.max(0, Date.now() / 1000 - ts);
  if (s < 90) return "now";
  if (s < 5400) return Math.round(s / 60) + " min ago";
  if (s < 172800) return Math.round(s / 3600) + " h ago";
  return Math.round(s / 86400) + " d ago";
}

function show(connected) {
  $("unlock").hidden = connected;
  for (const id of ["devices-section", "scenes-section", "activity-section"]) $(id).hidden = !connected;
}

function render(s) {
  $("host").textContent = "Talking to " + s.host;
  const dev = $("devices");
  dev.replaceChildren(...s.devices.map((d) => {
    const li = document.createElement("li");
    const dot = document.createElement("span");
    dot.className = "dot" + (d.online ? "" : " off");
    const name = document.createElement("span");
    name.className = "grow";
    name.textContent = d.title + (d.self ? " (this one)" : "");
    const os = document.createElement("span");
    os.className = "dim";
    os.textContent = d.os;
    li.append(dot, name, os);
    return li;
  }));
  // the buttons are only rebuilt when the scene list changes: replacing them every poll would eat a tap
  // that lands mid-refresh and wipe the "tap again" state
  const key = JSON.stringify(s.scenes);
  if (key !== sceneKey) {
    sceneKey = key;
    $("scenes").replaceChildren(...s.scenes.map((x) => {
      const b = document.createElement("button");
      b.textContent = x.title;
      b.dataset.name = x.name;
      b.addEventListener("click", () => runScene(b, x));
      return b;
    }));
  }
  const act = $("activity");
  act.replaceChildren(...s.activity.map((a) => {
    const li = document.createElement("li");
    const t = document.createElement("span");
    t.className = "grow";
    t.textContent = a.text;
    const when = document.createElement("span");
    when.className = "dim num";
    when.textContent = age(a.ts);
    li.append(t, when);
    return li;
  }));
  if (!s.activity.length) act.replaceChildren(Object.assign(document.createElement("li"), { textContent: "Nothing yet" }));
}

async function runScene(btn, scene) {
  // a second tap within three seconds confirms, so a stray touch cannot lock the desktop
  if (armed !== scene.name) {
    armed = scene.name;
    btn.classList.add("armed");
    btn.textContent = "Tap again: " + scene.title;
    setTimeout(() => { if (armed === scene.name) { armed = null; btn.classList.remove("armed"); btn.textContent = scene.title; } }, 3000);
    return;
  }
  armed = null;
  btn.classList.remove("armed");
  btn.textContent = scene.title;
  try {
    await api("/api/scene/" + encodeURIComponent(scene.name), { method: "POST", headers: { Authorization: "Bearer " + token() } });
    $("status").textContent = scene.title + " started";
  } catch (e) {
    $("status").textContent = "Could not start " + scene.title + ": " + e.message;
  }
  setTimeout(refresh, 800);
}

async function refresh() {
  if (!token()) { show(false); return; }
  try {
    render(await api("/api/state"));
    show(true);
    $("status").textContent = "";
  } catch (e) {
    if (e.message === "unauthorized") { show(false); $("status").textContent = "That token was not accepted."; }
    else $("status").textContent = "Not reachable: " + e.message;
  }
}

$("save").addEventListener("click", () => {
  try { localStorage.setItem(KEY, $("token").value.trim()); } catch (e) { /* private mode */ }
  $("token").value = "";
  refresh();
});
refresh();
setInterval(refresh, 5000);
