import assert from "node:assert/strict";
import {
  analyzeCartesianPolarization,
  analyzePolarization,
  electricSpin,
  instantaneousElectric,
  stokesParameters,
} from "./polarization-math.js";

const close = (actual, expected, tolerance = 1e-10) =>
  assert.ok(Math.abs(actual - expected) <= tolerance,
    `${actual} differs from ${expected}`);
const closeVector = (actual, expected, tolerance = 1e-10) =>
  actual.forEach((value, index) => close(value, expected[index], tolerance));
const absoluteDot = (left, right) => Math.abs(left.reduce(
  (sum, value, index) => sum + value * right[index], 0));
const complex = (real, imaginary = 0) => ({ real, imaginary });

// These are the same exact convention fixtures used by polarization-test.rkt.
let state = analyzePolarization(complex(1), complex(0));
assert.equal(state.sense, "linear");
assert.equal(state.axialRatio, Infinity);
close(state.tiltDegrees, 0);

const rootHalf = 1 / Math.sqrt(2);
state = analyzePolarization(complex(rootHalf), complex(rootHalf));
assert.equal(state.sense, "linear");
close(state.tiltDegrees, 45);

const rhcp = analyzePolarization(complex(rootHalf), complex(0, -rootHalf));
const lhcp = analyzePolarization(complex(rootHalf), complex(0, rootHalf));
assert.equal(rhcp.sense, "rhcp");
assert.equal(lhcp.sense, "lhcp");
close(rhcp.signedCircularity, 1);
close(lhcp.signedCircularity, -1);
close(rhcp.axialRatio, 1);
close(lhcp.axialRatio, 1);
assert.equal(rhcp.tiltDegrees, null);
assert.equal(lhcp.tiltDegrees, null);

const chi = Math.PI / 6, psi = Math.PI / 6;
const rotated = analyzePolarization(
  complex(Math.cos(chi) * Math.cos(psi), Math.sin(chi) * Math.sin(psi)),
  complex(Math.cos(chi) * Math.sin(psi), -Math.sin(chi) * Math.cos(psi)));
close(rotated.signedCircularity, Math.sin(2 * chi));
close(rotated.ellipticityDegrees, 30);
close(rotated.axialRatio, Math.sqrt(3));
close(rotated.tiltDegrees, 30);

const original = analyzePolarization(complex(0.8, 0.1), complex(-0.2, 0.55));
const phase = complex(7 * Math.cos(0.73), 7 * Math.sin(0.73));
const multiply = (left, right) => complex(
  left.real * right.real - left.imaginary * right.imaginary,
  left.real * right.imaginary + left.imaginary * right.real);
const transformed = analyzePolarization(
  multiply(phase, complex(0.8, 0.1)), multiply(phase, complex(-0.2, 0.55)));
close(transformed.signedCircularity, original.signedCircularity);
close(transformed.axialRatio, original.axialRatio);
close(transformed.tiltDegrees, original.tiltDegrees);

const zero = analyzePolarization(complex(0), complex(0));
assert.equal(zero.sense, "undefined");
assert.equal(zero.axialRatio, null);
assert.equal(zero.signedCircularity, null);

const stokes = stokesParameters(complex(0.8, 0.1), complex(-0.2, 0.55));
close(stokes.s0 ** 2, stokes.s1 ** 2 + stokes.s2 ** 2 + stokes.s3 ** 2);

// The following mirror near-field-polarization-test.rkt.
const linear = { real: [2, 0, 0], imaginary: [0, 0, 0] };
let ellipse = analyzeCartesianPolarization(linear);
close(ellipse.majorAmplitude, 2);
close(ellipse.minorAmplitude, 0);
close(absoluteDot(ellipse.majorAxis, [1, 0, 0]), 1);
assert.equal(ellipse.minorAxis, null);
closeVector(instantaneousElectric(linear, Math.PI), [-2, 0, 0]);

const positive = { real: [1, 0, 0], imaginary: [0, 1, 0] };
const negative = { real: [1, 0, 0], imaginary: [0, -1, 0] };
closeVector(instantaneousElectric(positive, Math.PI / 2), [0, -1, 0]);
closeVector(instantaneousElectric(negative, Math.PI / 2), [0, 1, 0]);
closeVector(electricSpin(linear), [0, 0, 0]);
closeVector(electricSpin(positive), [0, 0, 1]);
closeVector(electricSpin(negative), [0, 0, -1]);

ellipse = analyzeCartesianPolarization({ real: [2, 0, 0], imaginary: [0, 1, 0] });
close(ellipse.majorAmplitude, 2);
close(ellipse.minorAmplitude, 1);
close(ellipse.axialRatio, 2);

ellipse = analyzeCartesianPolarization({
  real: [rootHalf, rootHalf, 0], imaginary: [0, 0, -0.5],
});
close(ellipse.majorAmplitude, 1);
close(ellipse.minorAmplitude, 0.5);
close(absoluteDot(ellipse.majorAxis, [rootHalf, rootHalf, 0]), 1);
close(absoluteDot(ellipse.minorAxis, [0, 0, 1]), 1);
assert.equal(analyzeCartesianPolarization({
  real: [0, 0, 0], imaginary: [0, 0, 0],
}), null);

console.log("polarization math tests passed");
