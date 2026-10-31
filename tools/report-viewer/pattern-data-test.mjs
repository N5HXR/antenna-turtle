import assert from "node:assert/strict";
import {
  componentGainRange,
  dbPowerInterpolate,
  elevationPlaneDirection,
  globalGainRange,
  interpolatedGain,
  interpolatedPolarization,
  patternTable,
  polarDisplayScale,
  quantizedGain,
} from "./pattern-data.js";

assert.ok(Math.abs(dbPowerInterpolate(0, -10, 0.5) - (-2.596373105)) < 1e-8);

const pattern = {
  theta_values: [0, 90, 180],
  phi_values: [0, 90, 180, 270],
  samples: [],
};
for (const theta of pattern.theta_values) {
  for (const phi of pattern.phi_values) {
    pattern.samples.push({ theta_deg: theta, phi_deg: phi,
      total_gain_db: theta / 9 + phi / 90,
      e_theta: { real: theta / 90, imaginary: phi / 90 },
      e_phi: { real: 1 + theta / 90, imaginary: 1 + phi / 90 },
      axial_ratio: 2, tilt_degrees: 30, polarization: "right" });
  }
}
const table = patternTable(pattern);
assert.deepEqual(globalGainRange(pattern, "total"), { minimum: 0, peak: 23 });
for (const sample of pattern.samples)
  sample.vertical_gain_db = sample.total_gain_db - 12;
assert.deepEqual(componentGainRange(pattern, "vertical"), {
  minimum: -12, peak: 11, referencePeak: 23,
  relativeMinimum: -35, relativePeak: -12,
});
assert.equal(interpolatedGain(pattern, table, 90, 0, "total"), 0);
assert.equal(interpolatedGain(pattern, table, 0, 0, "total"), 10);
const expectedMidpoint = dbPowerInterpolate(
  dbPowerInterpolate(0, 1, 0.5), dbPowerInterpolate(10, 11, 0.5), 0.5);
assert.ok(Math.abs(interpolatedGain(pattern, table, 45, 45, "total")
  - expectedMidpoint) < 1e-10);
assert.equal(interpolatedGain(pattern, table, 0, 360, "total"), 10);
const polarization = interpolatedPolarization(pattern, table, 45, 45);
assert.ok(Math.abs(polarization.eTheta.real - 0.5) < 1e-12);
assert.ok(Math.abs(polarization.eTheta.imaginary - 0.5) < 1e-12);
assert.ok(Math.abs(polarization.phaseDifferenceDegrees) < 1e-12);
assert.equal(polarization.axialRatio, 2);
assert.equal(polarization.tiltDegrees, 30);
assert.equal(polarization.sense, "right");

assert.deepEqual(polarDisplayScale([-72, -60, -25, 0, 3], [-60, 0]), {
  radius: [0, 0, 35, 60, 60], range: [0, 60],
  tickvals: [0, 10, 20, 30, 40, 50, 60],
  ticktext: ["-60", "-50", "-40", "-30", "-20", "-10", "0"],
});
assert.equal(quantizedGain(-0.01), 0);
assert.equal(quantizedGain(-2.99), 0);
assert.equal(quantizedGain(-3), -3);
assert.equal(quantizedGain(-5.99), -3);
assert.equal(quantizedGain(-31), -30);

assert.deepEqual(elevationPlaneDirection(0, 25), { elevation: 0, azimuth: 25 });
assert.deepEqual(elevationPlaneDirection(90, 25), { elevation: 90, azimuth: 25 });
assert.deepEqual(elevationPlaneDirection(135, 25), { elevation: 45, azimuth: 205 });
assert.deepEqual(elevationPlaneDirection(180, 25), { elevation: 0, azimuth: 205 });
assert.deepEqual(elevationPlaneDirection(225, 25), { elevation: -45, azimuth: 205 });
assert.deepEqual(elevationPlaneDirection(315, 25), { elevation: -45, azimuth: 25 });

console.log("pattern data tests passed");
