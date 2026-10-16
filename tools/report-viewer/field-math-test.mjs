import assert from "node:assert/strict";
import { averagePoynting, instantaneousPoynting } from "./field-math.js";

const eta0 = 376.730313668;
const electric = { real: [1, 0, 0], imaginary: [0, 0, 0] };
const magnetic = { real: [0, 1 / eta0, 0], imaginary: [0, 0, 0] };
const close = (actual, expected, tolerance = 1e-12) =>
  assert.ok(Math.abs(actual - expected) <= tolerance,
    `${actual} differs from ${expected}`);

// A forward, in-phase plane wave transports +Z average power.
const average = averagePoynting(electric, magnetic);
close(average[0], 0);
close(average[1], 0);
close(average[2], 0.5 / eta0);

// E and H reverse together after half a cycle, so instantaneous power does
// not reverse. It vanishes at the quarter-cycle zero crossing.
close(instantaneousPoynting(electric, magnetic, 0)[2], 1 / eta0);
close(instantaneousPoynting(electric, magnetic, Math.PI / 2)[2], 0);
close(instantaneousPoynting(electric, magnetic, Math.PI)[2], 1 / eta0);

// The reconstructed animation is seamless at its 0/360-degree boundary.
const first = instantaneousPoynting(electric, magnetic, 0);
const last = instantaneousPoynting(electric, magnetic, 2 * Math.PI);
last.forEach((value, index) => close(value, first[index]));

// A 90-degree E/H phase offset has zero time-average real power.
const reactiveMagnetic = {
  real: [0, 0, 0], imaginary: [0, 1 / eta0, 0],
};
averagePoynting(electric, reactiveMagnetic)
  .forEach(value => close(value, 0));

console.log("field-math tests passed");
