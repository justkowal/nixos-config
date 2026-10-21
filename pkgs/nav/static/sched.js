"use strict";
// Timetable playback for vehicles without a live position. A trip is a list of [distance along the shape, arrival, departure] (seconds
// since its service day began); between two stops the vehicle eases out of one and into the next, and it stands for the dwell time.
(() => {
  // returns the distance and speed at time t; `hint` carries the last stop index so a frame costs O(1)
  function position(st, t, hint) {
    const n = st.length;
    let i = hint && hint.i < n - 1 ? hint.i : 0;
    while (i > 0 && st[i][2] > t) i--;
    while (i < n - 1 && st[i + 1][1] <= t) i++;
    if (hint) hint.i = i;
    const a = st[i];
    if (t < a[1]) return { s: a[0], v: 0, phase: i === 0 ? "before" : "dwell" };
    if (t <= a[2] || i === n - 1) return { s: a[0], v: 0, phase: i === n - 1 ? "after" : "dwell" };
    const b = st[i + 1], span = Math.max(1, b[1] - a[2]), u = Math.min(1, Math.max(0, (t - a[2]) / span));
    const e = u * u * (3 - 2 * u), de = (6 * u * (1 - u)) / span;
    return { s: a[0] + (b[0] - a[0]) * e, v: (b[0] - a[0]) * de, phase: "run" };
  }
  window.Sched = { position };
})();
