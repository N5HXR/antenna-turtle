import assert from "node:assert/strict";
import { loadImpedance } from "./nec2c-inspector.js";

const frequencyMhz = 14.2;
const inductive = loadImpedance({
  topology: "series", resistance_ohms: 0, inductance_h: 33.6e-6, capacitance_f: 0,
}, frequencyMhz);
assert.equal(inductive.real, 0);
assert.ok(Math.abs(inductive.imaginary - 2997.833373761524) < 1e-9);

const lossy = loadImpedance({
  topology: "series", resistance_ohms: 500, inductance_h: 10e-6, capacitance_f: 0,
}, frequencyMhz);
assert.equal(lossy.real, 500);
assert.ok(lossy.imaginary > 890 && lossy.imaginary < 893);

const parallel = loadImpedance({
  topology: "parallel", resistance_ohms: 1000, inductance_h: 10e-6, capacitance_f: 100e-12,
}, frequencyMhz);
assert.ok(Number.isFinite(parallel.real));
assert.ok(Number.isFinite(parallel.imaginary));

console.log("NEC2C report inspector tests passed");
