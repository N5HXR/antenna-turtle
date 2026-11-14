import assert from "node:assert/strict";
import {
  arrlRadiusFactor,
  axialRatioRgb,
  gainBrightness,
  polarizationSurfaceRgb,
  signedCircularityRgb,
  sphericalFrame,
} from "./far-field-polarization.js";

const close = (actual, expected, tolerance = 1e-10) =>
  assert.ok(Math.abs(actual - expected) <= tolerance,
    `${actual} differs from ${expected}`);
const closeVector = (actual, expected) =>
  actual.forEach((value, index) => close(value, expected[index]));

close(gainBrightness(-20, -20, 10), 0.1);
close(gainBrightness(10, -20, 10), 1.25);
close(gainBrightness(-5, -20, 10), 0.1 + 1.15 * 0.5 ** 1.2);
close(gainBrightness(3, 3, 3), 1);

closeVector(signedCircularityRgb(-1), [255, 32, 128]);
closeVector(signedCircularityRgb(0), [128, 255, 32]);
closeVector(signedCircularityRgb(1), [32, 128, 255]);
closeVector(signedCircularityRgb(-0.5), [191.5, 143.5, 80]);
closeVector(signedCircularityRgb(0.5), [80, 191.5, 143.5]);
closeVector(axialRatioRgb(1), [255, 240, 48]);
closeVector(axialRatioRgb(2), [151.5, 132, 88]);
closeVector(axialRatioRgb(Infinity), [48, 24, 128]);
closeVector(polarizationSurfaceRgb("signed-circularity",
  { signedCircularity: 1 }, -20, -20, 10), [3.2, 12.8, 25.5]);

close(arrlRadiusFactor(0), 1);
assert.ok(arrlRadiusFactor(-20) < arrlRadiusFactor(-3));

const frame = sphericalFrame(Math.PI / 2, 0, 0);
closeVector(frame.direction, [1, 0, 0]);
closeVector(frame.majorAxis, [0, 0, -1]);
closeVector(frame.minorAxis, [0, 1, 0]);
close(frame.direction.reduce((sum, value, index) =>
  sum + value * frame.majorAxis[index], 0), 0);

console.log("far-field polarization tests passed");
