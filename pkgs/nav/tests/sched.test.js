const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
global.window = {};
eval(fs.readFileSync(path.join(__dirname, "../static/sched.js"), "utf8"));
const P = window.Sched.position;
const st = [[0, 100, 130], [500, 190, 210], [1500, 330, 330]];

test("stands before the first departure, dwells at stops and ends at the last", () => {
  assert.deepEqual([P(st, 50).s, P(st, 50).phase], [0, "before"]);
  assert.deepEqual([P(st, 120).s, P(st, 120).v, P(st, 120).phase], [0, 0, "dwell"]);
  assert.deepEqual([P(st, 200).s, P(st, 200).phase], [500, "dwell"]);
  assert.deepEqual([P(st, 999).s, P(st, 999).phase], [1500, "after"]);
});

test("runs monotonically between stops, easing in and out, and averages the right speed", () => {
  let last = -1, vmax = 0;
  for (let t = 130; t <= 190; t += 0.5) { const p = P(st, t); assert.ok(p.s >= last); last = p.s; vmax = Math.max(vmax, p.v); }
  assert.ok(Math.abs(P(st, 130.01).v) < 0.5 && Math.abs(P(st, 189.99).v) < 0.5, "starts and ends at rest");
  assert.ok(Math.abs(P(st, 160).s - 250) < 1, "halfway in time is halfway in distance");
  assert.ok(vmax > 500 / 60 && vmax < 500 / 60 * 1.6, `peak ${vmax} m/s`);
});

test("the stop index hint gives the same answers going forward and back", () => {
  const h = { i: 0 };
  for (const t of [50, 140, 205, 300, 140, 60, 500]) assert.deepEqual(P(st, t, h), P(st, t));
});
