"use strict";
// Fleets: which vehicle models run for which operator, and how they are put together from meshes.
// The model families below are confirmed from operator and press sources (Solaris Urbino 10.5 m, 12 m and 18 m and Bombardier NGT6 and Stadler Lajkonik trams in Krakow;
// Pesa Twist, Pesa Swing and Moderus Beta trams, and Solaris buses in the Katowice conurbation; Newag Impuls 2 four car units at Koleje Slaskie).
// The live feeds do not say which vehicle is which, so the choice per vehicle is a deterministic draw from approximate shares (approx: true).
// Lengths and sections are close to the real vehicles but modelled, not measured.
(() => {
  // length in metres of each mesh, so cars can be laid out end to end
  const LEN = { bus12: 12, busMid: 10.5, bus18F: 8.8, bus18R: 8.2, bellowsBus: 1.4, coach12: 12.3, tram105: 13.4, tramEnd: 8.6, tramMid: 8.6, bellowsTram: 1.2, railEnd: 20, railMid: 20, icCoach: 24.5, loco: 18 };
  const F = (m) => [m, true];  // flipped copy of an end car, so its nose faces the rear
  const VARIANTS = {
    urbino12: { name: "Solaris Urbino 12", parts: [["bus12"]] },
    urbino18: { name: "Solaris Urbino 18 (articulated)", parts: [["bus18F"], ["bellowsBus"], F("bus18R")] },
    midi: { name: "Solaris Urbino 10.5 midi", parts: [["busMid"]] },
    coach: { name: "Intercity coach", parts: [["coach12"]] },
    tram3: { name: "Three section low-floor tram (NGT6, Pesa Twist class)", parts: [F("tramEnd"), ["bellowsTram"], ["tramMid"], ["bellowsTram"], ["tramEnd"]] },
    tram5: { name: "Long four body low-floor tram (Stadler Lajkonik class)", parts: [F("tramEnd"), ["bellowsTram"], ["tramMid"], ["bellowsTram"], ["tramMid"], ["bellowsTram"], ["tramEnd"]] },
    tram2: { name: "Two section tram (Pesa Swing, Moderus Beta class)", parts: [F("tramEnd"), ["bellowsTram"], ["tramEnd"]] },
    tram105: { name: "Konstal 105N pair", parts: [F("tram105"), ["tram105"]] },
    emu3: { name: "Three car electric unit", parts: [F("railEnd"), ["railMid"], ["railEnd"]] },
    emu4: { name: "Four car electric unit (Newag Impuls 2 class)", parts: [F("railEnd"), ["railMid"], ["railMid"], ["railEnd"]] },
    ic: { name: "Locomotive hauled coaches", parts: [["icCoach"], ["icCoach"], ["icCoach"], ["icCoach"], ["loco"]] },
  };
  // shares are approximations; `confirmed` lists the families the sources name for that operator
  const FLEETS = [
    { match: /w Krakowie|Mobilis/i, BUS: { urbino12: 55, urbino18: 27, midi: 18 }, TRAM: { tram3: 55, tram5: 35, tram105: 10 }, confirmed: "Solaris Urbino 10.5, 12, 18; Bombardier NGT6; Stadler Lajkonik" },
    { match: /^ZTP/i, TRAM: { tram3: 55, tram5: 35, tram105: 10 }, confirmed: "Bombardier NGT6; Stadler Lajkonik" },
    { match: /Transportu Metropolitalnego/i, BUS: { urbino12: 60, urbino18: 28, midi: 12 }, TRAM: { tram3: 45, tram2: 30, tram105: 25 }, TROLLEYBUS: { urbino12: 100 }, confirmed: "Solaris Urbino; Pesa Twist, Swing; Moderus Beta; Konstal 105N" },
    { match: /Koleje Śląskie/i, RAIL: { emu4: 55, emu3: 45 }, confirmed: "Newag Impuls 2 (four car)" },
    { match: /Małopolskie|Polregio/i, RAIL: { emu3: 100 } },
    { match: /Intercity/i, RAIL: { ic: 100 } },
    { match: /w Częstochowie/i, BUS: { urbino12: 70, midi: 30 }, TRAM: { tram105: 100 } },
    { match: /Jurajska/i, BUS: { coach: 70, midi: 30 } },
  ];
  const DEFAULT = { BUS: { urbino12: 100 }, TROLLEYBUS: { urbino12: 100 }, TRAM: { tram3: 100 }, RAIL: { emu3: 100 } };

  function hash(str) { let h = 2166136261; for (let i = 0; i < str.length; i++) { h ^= str.charCodeAt(i); h = Math.imul(h, 16777619); } return (h >>> 0) / 4294967296; }
  function draw(weights, r) { const e = Object.entries(weights), total = e.reduce((a, [, w]) => a + w, 0); let acc = 0; for (const [k, w] of e) { acc += w / total; if (r <= acc) return k; } return e[e.length - 1][0]; }

  // cars laid end to end, centred on the vehicle: [{mesh, c (metres from the centre), flip}]
  function layout(parts) {
    const total = parts.reduce((a, p) => a + LEN[p[0]], 0);
    let pos = -total / 2;
    const cars = parts.map(([mesh, flip]) => { const c = pos + LEN[mesh] / 2; pos += LEN[mesh]; return { mesh, c, flip: !!flip }; });
    return { cars, total };
  }
  function variantFor(agency, mode, id) {
    const fleet = FLEETS.find((f) => f.match.test(agency || "") && f[mode]);
    const table = (fleet && fleet[mode]) || DEFAULT[mode] || DEFAULT.BUS;
    const key = draw(table, hash(id + "|v"));
    return { key, ...VARIANTS[key], ...layout(VARIANTS[key].parts), approx: true, confirmed: fleet ? fleet.confirmed || null : null };
  }

  // colour variation: a small deterministic shift of the livery body colour per vehicle (fresh paint, faded paint), so a fleet is not a row of clones
  const toRgb = (hex) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255);
  function rgbToHsl([r, g, b]) {
    const mx = Math.max(r, g, b), mn = Math.min(r, g, b), l = (mx + mn) / 2, d = mx - mn;
    if (!d) return [0, 0, l];
    const s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn);
    const h = mx === r ? ((g - b) / d + (g < b ? 6 : 0)) / 6 : mx === g ? ((b - r) / d + 2) / 6 : ((r - g) / d + 4) / 6;
    return [h, s, l];
  }
  function hslToRgb([h, s, l]) {
    if (!s) return [l, l, l];
    const q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q;
    const f = (t) => { t = (t + 1) % 1; return t < 1 / 6 ? p + (q - p) * 6 * t : t < 1 / 2 ? q : t < 2 / 3 ? p + (q - p) * (2 / 3 - t) * 6 : p; };
    return [f(h + 1 / 3), f(h), f(h - 1 / 3)];
  }
  const clamp = (x, a, b) => Math.min(b, Math.max(a, x));
  function jitter(bodyHex, id, amount = 1) {
    const [h, s, l] = rgbToHsl(toRgb(bodyHex)), r1 = hash(id + "|h") - 0.5, r2 = hash(id + "|s") - 0.5, r3 = hash(id + "|l") - 0.5;
    return hslToRgb([(h + r1 * 0.014 * amount + 1) % 1, clamp(s + r2 * 0.1 * amount, 0, 1), clamp(l + r3 * 0.09 * amount, 0.04, 0.97)]).map((v) => Math.round(v * 255));
  }
  // any colour at all, for things with no livery (private cars): uniformly random hue, with realistic saturation and lightness bands
  function randomColor(id) {
    const r = hash(id + "|c"), kind = hash(id + "|k");
    if (kind < 0.34) return hslToRgb([0, 0, 0.12 + hash(id + "|g") * 0.8]).map((v) => Math.round(v * 255));          // black, greys, white
    return hslToRgb([r, 0.35 + hash(id + "|s") * 0.55, 0.28 + hash(id + "|l") * 0.4]).map((v) => Math.round(v * 255));  // any hue
  }

  window.Fleet = { LEN, VARIANTS, FLEETS, variantFor, layout, jitter, randomColor, hash, draw };
})();
