const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
global.window = {};
global.document = { documentElement: {} };
global.getComputedStyle = () => ({ getPropertyValue: () => "#e7e9ec" });
eval(fs.readFileSync(path.join(__dirname, "../static/daylight.js"), "utf8"));
const D = window.Daylight, deg = (r) => (r * 180) / Math.PI;
const KRK = [50.0614, 19.9371];

test("solar altitude at solstice and equinox noon matches the textbook values", () => {
  // solar noon in Krakow is about 10:42 UTC at the solstice (equation of time included)
  const jun = D.sunPosition(new Date("2026-06-21T10:42:00Z"), ...KRK);
  assert.ok(Math.abs(deg(jun.alt) - 63.4) < 1.0, `June noon altitude ${deg(jun.alt).toFixed(1)}`);
  const mar = D.sunPosition(new Date("2026-03-20T10:56:00Z"), ...KRK);
  assert.ok(Math.abs(deg(mar.alt) - 39.9) < 1.0, `equinox altitude ${deg(mar.alt).toFixed(1)}`);
  const dec = D.sunPosition(new Date("2026-12-21T10:47:00Z"), ...KRK);
  assert.ok(Math.abs(deg(dec.alt) - 16.5) < 1.0, `December altitude ${deg(dec.alt).toFixed(1)}`);
});

test("the sun is in the south at noon, east in the morning, west in the evening, below the horizon at midnight", () => {
  const az = (iso) => deg(D.sunPosition(new Date(iso), ...KRK).az);
  assert.ok(Math.abs(az("2026-06-21T10:42:00Z") - 180) < 3);
  assert.ok(az("2026-06-21T06:00:00Z") > 60 && az("2026-06-21T06:00:00Z") < 140);
  assert.ok(az("2026-06-21T16:00:00Z") > 220 && az("2026-06-21T16:00:00Z") < 300);
  assert.ok(D.sunPosition(new Date("2026-06-21T22:00:00Z"), ...KRK).alt < 0);
});

test("sky state is bright by day, warm at the horizon and dark with lamps on at night", () => {
  const noon = D.skyState(55), dusk = D.skyState(2), night = D.skyState(-20);
  assert.ok(noon.night < 0.01 && noon.day > 0.99);
  assert.ok(night.night > 0.99 && night.day < 0.01);
  assert.ok(dusk.sunColor[0] > dusk.sunColor[2] * 1.5, "red dominates a low sun");
  assert.ok(Math.max(...night.ambient) < Math.max(...noon.ambient) * 0.5);
  assert.ok(night.sky[2] > night.sky[0], "night sky is bluish");
  assert.ok(D.skyState(-5).night > 0.4 && D.skyState(-5).night < 0.95, "twilight is in between");
});

test("fixed and cycling time of day", () => {
  D.setMinutes(14 * 60 + 5);
  assert.equal(D.clockText(), "14:05");
  D.setMinutes(-30);
  assert.equal(D.minutes, 1410);
  D.setLive(); assert.equal(D.mode, "live");
});

test("sun times follow the real day: long summer days, short winter days, noon near the middle", () => {
  D.setDay("2026-06-21");
  let st = D.sunTimes();
  assert.ok(st.dayLength > 16 * 60 && st.dayLength < 16.4 * 60, `June day ${st.dayLength} min`);
  assert.ok(st.sunrise > 4 * 60 && st.sunrise < 6 * 60, `June sunrise ${D.hm(st.sunrise)}`);
  assert.ok(st.sunset > 20.4 * 60 && st.sunset < 21.5 * 60, `June sunset ${D.hm(st.sunset)}`);
  assert.ok(Math.abs(st.noon - (st.sunrise + st.sunset) / 2) < 10);
  assert.ok(st.dawn < st.sunrise && st.dusk > st.sunset, "civil twilight brackets the day");
  D.setDay("2026-12-21");
  st = D.sunTimes();
  assert.ok(st.dayLength > 7.8 * 60 && st.dayLength < 8.4 * 60, `December day ${st.dayLength} min`);
  assert.ok(st.sunrise > 7 * 60 && st.sunrise < 8 * 60, `December sunrise ${D.hm(st.sunrise)}`);
  assert.match(D.sunText(), /Sunrise 07:\d\d, sunset 15:\d\d/);
  D.setDay(null);
});

test("the shown day sets the light: noon of a December day is lower than noon of a June day", () => {
  const scene = { light: null, setLight(l) { this.light = l; } };
  D.enable(true);
  D.setDay("2026-06-21"); D.setMinutes(13 * 60 + 40); D.apply(scene, null); const june = scene.light.sun[2];
  D.setDay("2026-12-21"); D.setMinutes(12 * 60 + 40); D.apply(scene, null); const dec = scene.light.sun[2];
  assert.ok(june > dec + 0.3, `${june} vs ${dec}`);
  D.setDay("2026-06-21"); D.setMinutes(23 * 60); D.apply(scene, null);
  assert.ok(scene.light.night > 0.9);
  D.setDay("2026-06-21"); D.setMinutes(21 * 60 + 25); D.apply(scene, null);
  assert.ok(scene.light.night > 0.3 && scene.light.night < 0.95, "dusk after the late June sunset is a twilight, not full night");
  D.setDay(null); D.enable(false);
});

test("apply sets neutral light outside diorama and a night factor inside it", () => {
  const scene = { light: null, setLight(l) { this.light = l; } };
  D.enable(false); D.apply(scene, null);
  assert.equal(scene.light.night, 0);
  D.enable(true); D.setMinutes(2 * 60); D.apply(scene, null);
  assert.ok(scene.light.night > 0.9, "2 am is night");
  D.setMinutes(13 * 60); D.apply(scene, null);
  assert.ok(scene.light.night < 0.05, "1 pm is day");
  assert.ok(scene.light.sun[2] > 0.25, "the sun is above the horizon at 1 pm in any season");
});

test("weather simulation adjusts sky, horizon, fog, and sun lighting", () => {
  const clear = D.skyState(45, "clear");
  const rain = D.skyState(45, "rain");
  const fog = D.skyState(45, "fog");
  const snow = D.skyState(45, "snow");

  assert.ok(rain.sunColor[0] < clear.sunColor[0] * 0.5, "rain dims the sun");
  assert.ok(fog.fogDensity > clear.fogDensity, "fog increases fog density");
  assert.ok(snow.ambient[0] > clear.ambient[0] * 0.9, "snow has bright ambient reflection");

  D.setWeather("rain");
  assert.equal(D.weather.condition, "rain");
  D.setWeather("clear");
  assert.equal(D.weather.condition, "clear");
});

test("realtime pace replay advances simulation time at 1x speed", () => {
  D.setMinutes(12 * 60); // 12:00
  D.play(1.0, "replay");
  assert.equal(D.mode, "replay");
  assert.equal(D.speed, 1.0);
  D.pause();
  assert.equal(D.mode, "fixed");
});

test("base map ground illumination follows time of day, brightness, and sun color", () => {
  // Midday: bright, balanced sun
  const noonState = D.skyState(55, "clear");
  const noonLight = D.groundIllumination(noonState);
  assert.ok(noonLight[0] > 0.85 && noonLight[1] > 0.85 && noonLight[2] > 0.85, `Noon is bright: ${noonLight}`);
  assert.ok(Math.abs(noonLight[0] - noonLight[1]) < 0.1, "Noon is balanced in tint");

  // Sunset: warm amber / red dominance
  const sunsetState = D.skyState(2, "clear");
  const sunsetLight = D.groundIllumination(sunsetState);
  assert.ok(sunsetLight[0] > sunsetLight[2] * 1.25, `Sunset has warm amber/red glow: ${sunsetLight}`);

  // Night: dimmed, cool blueish tint
  const nightState = D.skyState(-25, "clear");
  const nightLight = D.groundIllumination(nightState);
  assert.ok(nightLight[0] < 0.35 && nightLight[1] < 0.35, `Night is dark: ${nightLight}`);
  assert.ok(nightLight[2] > nightLight[0], `Night has cool moonlight tone: ${nightLight}`);

  // Custom layer definition is exposed
  assert.ok(typeof D.createIlluminationLayer === "function");
  const layer = D.createIlluminationLayer();
  assert.equal(layer.id, "base-map-illumination");
  assert.equal(layer.type, "custom");
});

