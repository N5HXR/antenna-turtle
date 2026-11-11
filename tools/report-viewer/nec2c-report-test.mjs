import assert from "node:assert/strict";
import {
  canonicalCurrentPhase,
  canonicalWireSign,
  instantaneousWireCurrent,
  loadImpedance,
  opponentCurrentColor,
} from "./nec2c-inspector.js";

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

assert.deepEqual(instantaneousWireCurrent({ real: 2, imaginary: 0 }, 0,
  [0, 0, 0], [1, 0, 0]), [2, 0, 0]);
assert.deepEqual(instantaneousWireCurrent({ real: -2, imaginary: 0 }, 0,
  [1, 0, 0], [0, 0, 0]), [2, 0, 0]);
const quarterCycle = instantaneousWireCurrent({ real: 0, imaginary: 2 }, 90,
  [0, 0, 0], [0, 1, 0]);
assert.ok(Math.abs(quarterCycle[1] + 2) < 1e-12);

const positiveX = opponentCurrentColor([1, 0, 0], 1);
const negativeX = opponentCurrentColor([-1, 0, 0], 1);
assert.ok(positiveX[0] > positiveX[1] && positiveX[0] > positiveX[2]);
assert.ok(negativeX[0] < negativeX[1] && negativeX[0] < negativeX[2]);
const positiveY = opponentCurrentColor([0, 1, 0], 1);
const negativeY = opponentCurrentColor([0, -1, 0], 1);
assert.ok(positiveY[1] > positiveY[0] && positiveY[1] > positiveY[2]);
assert.ok(negativeY[1] < negativeY[0] && negativeY[1] < negativeY[2]);
const positiveZ = opponentCurrentColor([0, 0, 1], 1);
const negativeZ = opponentCurrentColor([0, 0, -1], 1);
assert.ok(positiveZ[2] > positiveZ[0] && positiveZ[2] > positiveZ[1]);
assert.ok(negativeZ[2] < negativeZ[0] && negativeZ[2] < negativeZ[1]);
positiveX.forEach((component, index) =>
  assert.ok(Math.abs(component + negativeX[index] - 1) < 1e-12));
const mixedVector = [0.2, -0.7, 0.4];
const mixedMaximum = Math.hypot(...mixedVector);
const mixed = opponentCurrentColor(mixedVector, mixedMaximum);
const reversedMixed = opponentCurrentColor(mixedVector.map(component => -component), mixedMaximum);
mixed.forEach((component, index) => {
  assert.ok(component >= 0 && component <= 1);
  assert.ok(Math.abs(component + reversedMixed[index] - 1) < 1e-12);
});
const zeroColor = opponentCurrentColor([0, 0, 0], 1);
assert.deepEqual(zeroColor, [0, 0, 0]);
const halfCurrent = opponentCurrentColor([0.25, 0, 0], 1);
assert.ok(halfCurrent[0] > 0 && halfCurrent[0] < positiveX[0]);
assert.deepEqual(halfCurrent.slice(1), [0, 0]);

console.log("NEC2C report inspector tests passed");
