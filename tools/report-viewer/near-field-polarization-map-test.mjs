import assert from "node:assert/strict";
import {
  axialTiltRgb,
  nearFieldPolarization,
  projectedPolarization,
} from "./near-field-polarization-map.js";

const xy = { u_axis: "x", v_axis: "y", normal_axis: "z" };
const yx = { u_axis: "y", v_axis: "x", normal_axis: "z" };
const sample = electric => ({ electric });

const linear = nearFieldPolarization(sample([2, 0, 0, 0, 3, 4]), xy);
assert.equal(linear.sense, "linear");
assert.equal(linear.axialRatio, Infinity);
assert.equal(linear.tiltDegrees, 0);
assert.equal(linear.projectedMagnitude, 2);
assert.equal(linear.normalMagnitude, 5);

const rhcp = nearFieldPolarization(sample([1, 0, 0, -1, 0, 0]), xy);
assert.ok(Math.abs(rhcp.signedCircularity - 1) < 1e-12);
assert.equal(rhcp.sense, "rhcp");
assert.ok(Math.abs(rhcp.axialRatio - 1) < 1e-12);

const reversed = nearFieldPolarization(sample([1, 0, 0, -1, 0, 0]), yx);
assert.ok(Math.abs(reversed.signedCircularity - 1) < 1e-12);
assert.equal(reversed.orientation, -1);

const tilted = nearFieldPolarization(sample([1, 0, 1, 0, 0, 0]), xy);
assert.ok(Math.abs(tilted.tiltDegrees - 45) < 1e-12);

assert.equal(nearFieldPolarization(sample(null), xy), null);
assert.equal(nearFieldPolarization(sample([1, 0, 0, 0, 0, 0]),
  { u_axis: "x", v_axis: "x", normal_axis: "z" }), null);

assert.deepEqual(axialTiltRgb(-90), axialTiltRgb(90));
assert.deepEqual(axialTiltRgb(-90), [255, 32, 128]);
assert.deepEqual(axialTiltRgb(0), [32, 255, 128]);
assert.deepEqual(axialTiltRgb(null), [20, 20, 26]);

const projected = projectedPolarization(
  { real: 1, imaginary: 0 }, { real: 0, imaginary: -1 }, -1);
assert.ok(Math.abs(projected.signedCircularity + 1) < 1e-12);
assert.equal(projected.sense, "lhcp");

console.log("near-field polarization map tests passed");
