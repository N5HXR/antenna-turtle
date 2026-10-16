import assert from "node:assert/strict";
import {
  availablePlots,
  interpolatePortSamples,
  nearestSample,
  normalizedImpedance,
  returnLoss,
  samplesForPort,
  sParameterGroups,
  vswr,
  vswrAxisRange,
} from "./plot-data.js";

const measurements = {
  ports: [{ name: "feed", reference_impedance_ohms: 50 }],
  port_samples: [
    { port: "feed", frequency_mhz: 1100, s11_db: -6,
      reflection_coefficient: { magnitude: 0.5 } },
    { port: "feed", frequency_mhz: 900, s11_db: -20,
      reflection_coefficient: { real: 0.1, imaginary: 0 } },
  ],
  s_parameters: [
    { from: "input", to: "output", frequency_mhz: 1100, db: -1 },
    { from: "input", to: "output", frequency_mhz: 900, db: -2 },
  ],
};

assert.deepEqual(samplesForPort(measurements, "feed").map(s => s.frequency_mhz),
  [900, 1100]);
assert.equal(returnLoss(measurements.port_samples[0]), 6);
assert.equal(vswr(measurements.port_samples[0]), 3);
assert.deepEqual(vswrAxisRange(measurements.port_samples), [1, 3.1]);
assert.deepEqual(vswrAxisRange([
  { reflection_coefficient: { magnitude: 0 } },
]), [1, 1.1]);
assert.equal(nearestSample(samplesForPort(measurements, "feed"), 1000).frequency_mhz, 900);
assert.deepEqual(normalizedImpedance(
  { impedance_ohms: { real: 50, imaginary: 25 } }, 50),
  { real: 1, imaginary: 0.5 });
const interpolated = interpolatePortSamples([
  { port: "feed", frequency_mhz: 900,
    impedance_ohms: { real: 40, imaginary: -20 } },
  { port: "feed", frequency_mhz: 1000,
    impedance_ohms: { real: 60, imaginary: 10 } },
], 50, 2);
assert.equal(interpolated.length, 4);
const resonance = interpolated.find(sample => sample.interpolated &&
  Math.abs(sample.impedance_ohms.imaginary) < 1e-10);
assert.ok(resonance);
assert.ok(Math.abs(resonance.frequency_mhz - 966.6666667) < 1e-6);
assert.ok(Math.abs(resonance.impedance_ohms.real - 53.3333333) < 1e-6);
assert.ok(Number.isFinite(resonance.s11_db));
assert.equal(sParameterGroups(measurements).get("output←input")[0].frequency_mhz, 900);
assert.equal(availablePlots(measurements)[1][0], "s11");
assert.equal(availablePlots(measurements).at(-1)[0], "s-parameters");
console.log("plot data tests passed");
