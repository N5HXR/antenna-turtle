const LHCP = [255, 32, 128];
const LINEAR = [128, 255, 32];
const RHCP = [32, 128, 255];
const AXIAL_LINEAR = [48, 24, 128];
const AXIAL_CIRCULAR = [255, 240, 48];
const UNDEFINED = [20, 20, 26];

function interpolate(left, right, fraction) {
  return left.map((value, index) => value + fraction * (right[index] - value));
}

export function gainBrightness(gain, minimum, maximum) {
  if (minimum === maximum) return 1;
  const fraction = Math.max(0, Math.min(1, (gain - minimum) / (maximum - minimum)));
  return 0.1 + 1.15 * fraction ** 1.2;
}

export function signedCircularityRgb(circularity) {
  if (!Number.isFinite(circularity)) return [...UNDEFINED];
  const bounded = Math.max(-1, Math.min(1, circularity));
  return bounded < 0
    ? interpolate(LHCP, LINEAR, bounded + 1)
    : interpolate(LINEAR, RHCP, bounded);
}

export function axialRatioRgb(ratio) {
  if (ratio === null || ratio === undefined || Number.isNaN(ratio) || ratio < 1)
    return [...UNDEFINED];
  return interpolate(AXIAL_LINEAR, AXIAL_CIRCULAR,
    Number.isFinite(ratio) ? 1 / ratio : 0);
}

export function polarizationSurfaceRgb(mode, state, gain, minimum, maximum) {
  const base = mode === "axial-ratio"
    ? axialRatioRgb(state?.axialRatio) : signedCircularityRgb(state?.signedCircularity);
  const brightness = gainBrightness(gain, minimum, maximum);
  return base.map(channel => Math.max(0, Math.min(255, channel * brightness)));
}

export function arrlRadiusFactor(relativeGainDb) {
  return 0.89 ** ((-Math.max(-100, Math.min(0, relativeGainDb))) / 2);
}

export function sphericalFrame(thetaRadians, phiRadians, tiltDegrees = 0) {
  const tilt = tiltDegrees * Math.PI / 180;
  const direction = [
    Math.sin(thetaRadians) * Math.cos(phiRadians),
    Math.sin(thetaRadians) * Math.sin(phiRadians),
    Math.cos(thetaRadians),
  ];
  const thetaAxis = [
    Math.cos(thetaRadians) * Math.cos(phiRadians),
    Math.cos(thetaRadians) * Math.sin(phiRadians),
    -Math.sin(thetaRadians),
  ];
  const phiAxis = [-Math.sin(phiRadians), Math.cos(phiRadians), 0];
  const combine = (a, b) => thetaAxis.map((value, index) =>
    a * value + b * phiAxis[index]);
  return {
    direction, thetaAxis, phiAxis,
    majorAxis: combine(Math.cos(tilt), Math.sin(tilt)),
    minorAxis: combine(-Math.sin(tilt), Math.cos(tilt)),
  };
}
