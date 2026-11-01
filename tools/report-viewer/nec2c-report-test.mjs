import assert from "node:assert/strict";
import { canonicalCurrentPhase, canonicalWireSign, loadImpedance } from "./nec2c-inspector.js";

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

assert.equal(canonicalWireSign([0, 0, 0], [2, 0, 0]), 1);
assert.equal(canonicalWireSign([0, 0, 0], [-2, 0, 0]), -1);
assert.equal(canonicalWireSign([0, 4, 0], [0, 1, 0]), -1);
assert.equal(canonicalWireSign([0, 0, 0], [0, 0, 0]), 1);

// Representative raw phases from two reflected folded-dipole halves. Once
// expressed in the same spatial direction, the apparent 180-degree jump
// collapses to the physical 1.6-degree difference.
assert.ok(Math.abs(canonicalCurrentPhase(-69.1, -1) - 110.9) < 1e-9);
assert.ok(Math.abs(canonicalCurrentPhase(112.5, 1) - 112.5) < 1e-9);
assert.equal(canonicalCurrentPhase(181, 1), -179);
assert.equal(canonicalCurrentPhase(-181, 1), 179);

console.log("NEC2C report inspector tests passed");
