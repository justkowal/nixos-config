const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

global.window = {};
eval(fs.readFileSync(path.join(__dirname, "../static/scene3d.js"), "utf8"));
eval(fs.readFileSync(path.join(__dirname, "../static/roads3d.js"), "utf8"));
const R3D = window.Roads3D;

const anchor = { lon: 19.9, lat: 50.06 };
const roadFeat = (cls, brunnel = null, layer = 0) => ({
  properties: { class: cls, brunnel, layer },
  geometry: {
    type: "LineString",
    coordinates: [[19.9, 50.06], [19.905, 50.06], [19.91, 50.062]],
  },
});
const railFeat = (cls = "rail", electrified = "yes", brunnel = null, layer = 0) => ({
  properties: { class: cls, electrified, brunnel, layer },
  geometry: {
    type: "LineString",
    coordinates: [[19.9, 50.065], [19.905, 50.065], [19.91, 50.065]],
  },
});

test("isRail and isElectrified correctly identify transit types", () => {
  assert.ok(R3D.isRail({ class: "rail" }));
  assert.ok(R3D.isRail({ class: "tram" }));
  assert.ok(R3D.isRail({ subclass: "rail" }));
  assert.ok(!R3D.isRail({ class: "primary" }));

  assert.ok(R3D.isElectrified({ class: "rail", electrified: "contact_line" }));
  assert.ok(R3D.isElectrified({ class: "rail", electrified: "yes" }));
  assert.ok(R3D.isElectrified({ class: "tram" }), "tram is electrified by default");
  assert.ok(!R3D.isElectrified({ class: "rail", electrified: "no" }));
  assert.ok(!R3D.isElectrified({ class: "primary" }));
});

test("road geometry creates asphalt surface and concrete curbs", () => {
  const res = R3D.build({ features: [roadFeat("primary")], anchor });
  assert.equal(res.stats.roadCount, 1);
  assert.ok(res.meshes.road_asphalt, "asphalt mesh generated");
  assert.ok(res.meshes.road_concrete, "curb mesh generated");
  assert.ok(res.meshes.road_asphalt.triangles > 0);
  assert.ok(res.meshes.road_concrete.triangles > 0);
});

test("bridge geometry adds bridge deck, parapets and vertical support piers", () => {
  const res = R3D.build({ features: [roadFeat("primary", "bridge", 1)], anchor });
  assert.ok(res.meshes.road_concrete.triangles > 20, "concrete bridge structure generated");

  // Check vertices elevation: should be elevated around bridge height (~5.2m)
  const v = res.meshes.road_asphalt.vertex;
  let maxZ = -1e9;
  for (let i = 0; i < v.length / 7; i++) {
    maxZ = Math.max(maxZ, v[i * 7 + 2]);
  }
  assert.ok(maxZ > 4.5 && maxZ < 6.5, `bridge deck elevated to ${maxZ}m`);
});

test("rail geometry builds ballast bed, twin steel rails, and catenary lines", () => {
  const res = R3D.build({ features: [railFeat("rail", "yes")], anchor });
  assert.equal(res.stats.railCount, 1);
  assert.equal(res.stats.electrifiedCount, 1);

  assert.ok(res.meshes.rail_ballast, "ballast mesh built");
  assert.ok(res.meshes.rail_steel, "twin steel rails built");
  assert.ok(res.meshes.rail_traction, "overhead catenary wires & masts built");

  assert.ok(res.meshes.rail_ballast.triangles > 0);
  assert.ok(res.meshes.rail_steel.triangles > 0);
  assert.ok(res.meshes.rail_traction.triangles > 0);

  // Check wire heights in rail_traction mesh
  const tv = res.meshes.rail_traction.vertex;
  let maxWireZ = -1e9, minWireZ = 1e9;
  for (let i = 0; i < tv.length / 7; i++) {
    const z = tv[i * 7 + 2];
    maxWireZ = Math.max(maxWireZ, z);
    minWireZ = Math.min(minWireZ, z);
  }
  assert.ok(maxWireZ >= 6.4, `upper catenary mast reaches ${maxWireZ}m`);
  assert.ok(minWireZ <= 1.0, `masts contact the ground`);
});

test("non-electrified rail skips catenary wires and poles", () => {
  const res = R3D.build({ features: [railFeat("rail", "no")], anchor });
  assert.equal(res.stats.railCount, 1);
  assert.equal(res.stats.electrifiedCount, 0);
  assert.ok(res.meshes.rail_ballast);
  assert.ok(res.meshes.rail_steel);
  assert.equal(res.meshes.rail_traction, null, "no traction wires on non-electrified track");
});

test("tunnel features generate tunnel portals", () => {
  const res = R3D.build({ features: [roadFeat("primary", "tunnel", -1)], anchor });
  assert.ok(res.meshes.road_concrete.triangles > 10, "tunnel portals generated");
});

test("Roads3D.build supports positional arguments (features, anchor, groundFn)", () => {
  const res = R3D.build([roadFeat("primary")], anchor, (x, y) => 5.0);
  assert.equal(res.stats.roadCount, 1);
  assert.ok(res.meshes.road_asphalt);
  assert.ok(res.meshes.road_asphalt.vertex.length > 0);
  // Check ground elevation offset is applied
  const vz = res.meshes.road_asphalt.vertex[2];
  assert.ok(vz >= 4.9, `ground offset applied: ${vz}`);
});

test("TriBuffer.toMesh creates Uint16Array for small meshes and Uint32Array for meshes > 65535 vertices", () => {
  const tbSmall = new R3D.TriBuffer();
  tbSmall.tri([0, 0, 0], [1, 0, 0], [0, 1, 0]);
  const meshSmall = tbSmall.toMesh();
  assert.ok(meshSmall.index instanceof Uint16Array, "small mesh uses Uint16Array");
  assert.equal(meshSmall.triangles, 1);

  const tbLarge = new R3D.TriBuffer();
  // Simulate large vertex buffer with 66000 vertices (66000 * 7 floats)
  tbLarge.v = new Array(66000 * 7).fill(0);
  const meshLarge = tbLarge.toMesh();
  assert.ok(meshLarge.index instanceof Uint32Array, "large mesh uses Uint32Array");
  assert.equal(meshLarge.triangles, 22000);
  assert.equal(meshLarge.index[65536], 65536);
});
