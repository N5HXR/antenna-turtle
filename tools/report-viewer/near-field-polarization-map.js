import { analyzePolarization } from "./polarization-math.js";

const AXIS_INDEX = { x: 0, y: 1, z: 2 };

export const signedCircularityColorscale = [
  [0, "rgb(255,32,128)"],
  [0.5, "rgb(128,255,32)"],
  [1, "rgb(32,128,255)"],
];

// Axial tilt is an orientation, so -90 and +90 degrees are the same color.
// The saturated cyclic ramp avoids a false discontinuity and stays distinct
// from the signed-circularity ramp.
export const axialTiltColorscale = [
  [0, "rgb(255,32,128)"],
  [0.25, "rgb(128,32,255)"],
  [0.5, "rgb(32,255,128)"],
  [0.75, "rgb(255,224,32)"],
  [1, "rgb(255,32,128)"],
];

function interpolateColor(left, right, fraction) {
  return left.map((value, index) => value + fraction * (right[index] - value));
}

export function axialTiltRgb(tiltDegrees) {
  if (!Number.isFinite(tiltDegrees)) return [20, 20, 26];
  const position = (((tiltDegrees + 90) % 180 + 180) % 180) / 180;
  const parse = css => css.match(/\d+/g).map(Number);
  for (let index = 1; index < axialTiltColorscale.length; ++index) {
    const [rightStop, rightCss] = axialTiltColorscale[index];
    if (position <= rightStop) {
      const [leftStop, leftCss] = axialTiltColorscale[index - 1];
      return interpolateColor(parse(leftCss), parse(rightCss),
        (position - leftStop) / (rightStop - leftStop));
    }
  }
  return [255, 32, 128];
}

function complexAt(values, axis) {
  const index = AXIS_INDEX[String(axis).toLowerCase()];
  if (index === undefined || !Array.isArray(values) || values.length !== 6) return null;
  return { real: Number(values[2 * index]), imaginary: Number(values[2 * index + 1]) };
}

function basisOrientation(section) {
  const u = AXIS_INDEX[String(section?.u_axis).toLowerCase()];
  const v = AXIS_INDEX[String(section?.v_axis).toLowerCase()];
  const normal = AXIS_INDEX[String(section?.normal_axis).toLowerCase()];
  if (u === undefined || v === undefined || normal === undefined) return null;
  const permutation = [u, v, normal];
  if (new Set(permutation).size !== 3) return null;
  const inversions = permutation.reduce((count, value, index) => count +
    permutation.slice(index + 1).filter(next => value > next).length, 0);
  return inversions % 2 === 0 ? 1 : -1;
}

function complexMagnitude(value) {
  return Math.hypot(value?.real || 0, value?.imaginary || 0);
}

export function projectedPolarization(eU, eV, orientation = 1) {
  const projected = analyzePolarization(eU, eV);
  if (projected.signedCircularity === null) return projected;
  const signedCircularity = Math.sign(orientation || 1)
    * projected.signedCircularity;
  return {
    ...projected,
    signedCircularity,
    sense: Math.abs(signedCircularity) <= 1e-12
      ? "linear" : signedCircularity > 0 ? "rhcp" : "lhcp",
  };
}

export function nearFieldPolarization(sample, section) {
  const electric = sample?.electric;
  const eU = complexAt(electric, section?.u_axis);
  const eV = complexAt(electric, section?.v_axis);
  const eNormal = complexAt(electric, section?.normal_axis);
  const orientation = basisOrientation(section);
  if (!eU || !eV || !eNormal || orientation === null) return null;
  const projected = projectedPolarization(eU, eV, orientation);
  if (projected.signedCircularity === null) return null;
  const projectedMagnitude = Math.sqrt(projected.s0);
  const normalMagnitude = complexMagnitude(eNormal);
  return {
    ...projected,
    eU,
    eV,
    eNormal,
    projectedMagnitude,
    normalMagnitude,
    totalMagnitude: Math.hypot(projectedMagnitude, normalMagnitude),
    orientation,
  };
}
