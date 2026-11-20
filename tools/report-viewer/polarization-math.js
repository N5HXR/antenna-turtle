const ROOT_TWO = Math.sqrt(2);
const EPSILON = 1e-14;

function clamp(value, low, high) {
  return Math.max(low, Math.min(high, value));
}

function complexPower(value) {
  return value.real ** 2 + value.imaginary ** 2;
}

function complexAdd(left, right) {
  return {
    real: left.real + right.real,
    imaginary: left.imaginary + right.imaginary,
  };
}

function complexScale(value, scalar) {
  return { real: value.real * scalar, imaginary: value.imaginary * scalar };
}

function complexMultiply(left, right) {
  return {
    real: left.real * right.real - left.imaginary * right.imaginary,
    imaginary: left.real * right.imaginary + left.imaginary * right.real,
  };
}

function vectorDot(left, right) {
  return left.reduce((sum, value, index) => sum + value * right[index], 0);
}

function vectorScale(vector, scalar) {
  return vector.map(value => value * scalar);
}

function vectorAdd(left, right) {
  return left.map((value, index) => value + right[index]);
}

function vectorCross(left, right) {
  return [
    left[1] * right[2] - left[2] * right[1],
    left[2] * right[0] - left[0] * right[2],
    left[0] * right[1] - left[1] * right[0],
  ];
}

function vectorNormalize(vector) {
  const length = Math.sqrt(Math.max(0, vectorDot(vector, vector)));
  return length > EPSILON ? vectorScale(vector, 1 / length) : null;
}

export function stokesParameters(eTheta, ePhi) {
  const thetaPower = complexPower(eTheta);
  const phiPower = complexPower(ePhi);
  // eTheta * conjugate(ePhi)
  const crossReal = eTheta.real * ePhi.real + eTheta.imaginary * ePhi.imaginary;
  const crossImaginary = eTheta.imaginary * ePhi.real - eTheta.real * ePhi.imaginary;
  return {
    s0: thetaPower + phiPower,
    s1: thetaPower - phiPower,
    s2: 2 * crossReal,
    s3: 2 * crossImaginary,
  };
}

export function circularComponents(eTheta, ePhi) {
  const iEPhi = complexMultiply({ real: 0, imaginary: 1 }, ePhi);
  return {
    rhcp: complexScale(complexAdd(eTheta, iEPhi), 1 / ROOT_TWO),
    lhcp: complexScale(complexAdd(eTheta, complexScale(iEPhi, -1)), 1 / ROOT_TWO),
  };
}

// Antenna Turtle uses Re(E exp(+jwt)). Viewed from behind the antenna looking
// outward along propagation, E_phi = -j E_theta is therefore RHCP and has
// positive signed circularity.
export function analyzePolarization(eTheta, ePhi,
  { tolerance = 1e-12, minimumPower = 0 } = {}) {
  const stokes = stokesParameters(eTheta, ePhi);
  const circular = circularComponents(eTheta, ePhi);
  const rhcpPower = complexPower(circular.rhcp);
  const lhcpPower = complexPower(circular.lhcp);
  if (stokes.s0 <= minimumPower) {
    return {
      ...stokes, signedCircularity: null, axialRatio: null, tiltDegrees: null,
      ellipticityDegrees: null, sense: "undefined", ...circular,
      rhcpPower, lhcpPower,
    };
  }
  const signedCircularity = clamp(stokes.s3 / stokes.s0, -1, 1);
  const ellipticityRadians = 0.5 * Math.asin(signedCircularity);
  const minorMajor = Math.abs(Math.tan(ellipticityRadians));
  const axialRatio = minorMajor <= tolerance
    ? Infinity : Math.max(1, 1 / minorMajor);
  const linearStokes = Math.hypot(stokes.s1, stokes.s2) / stokes.s0;
  const tiltDegrees = linearStokes > tolerance
    ? 0.5 * Math.atan2(stokes.s2, stokes.s1) * 180 / Math.PI : null;
  const sense = Math.abs(signedCircularity) <= tolerance
    ? "linear" : signedCircularity > 0 ? "rhcp" : "lhcp";
  return {
    ...stokes, signedCircularity, axialRatio, tiltDegrees,
    ellipticityDegrees: ellipticityRadians * 180 / Math.PI,
    sense, ...circular, rhcpPower, lhcpPower,
  };
}

export function instantaneousElectric(electric, phaseRadians) {
  const cosine = Math.cos(phaseRadians), sine = Math.sin(phaseRadians);
  return electric.real.map((value, index) =>
    value * cosine - electric.imaginary[index] * sine);
}

export function electricSpin(electric) {
  const energy = electric.real.reduce((sum, value, index) =>
    sum + value ** 2 + electric.imaginary[index] ** 2, 0);
  if (energy <= 1e-28) return [0, 0, 0];
  // Im(conjugate(E) x E) = 2 Re(E) x Im(E).
  return vectorScale(vectorCross(electric.real, electric.imaginary), 2 / energy);
}

function principalCoefficients(aa, bb, ab, eigenvalue) {
  const raw = Math.abs(ab) > EPSILON
    ? [ab, eigenvalue - aa]
    : aa >= bb ? [1, 0] : [0, 1];
  return vectorScale(raw, 1 / Math.hypot(...raw));
}

// Analyze the full 3-D Cartesian trajectory Re(E exp(+jwt)). The returned
// amplitudes are physical field semi-axis magnitudes; axes are unit vectors.
export function analyzeCartesianPolarization(electric) {
  const cosineAxis = [...electric.real];
  const sineAxis = electric.imaginary.map(value => -value);
  const aa = vectorDot(cosineAxis, cosineAxis);
  const bb = vectorDot(sineAxis, sineAxis);
  const ab = vectorDot(cosineAxis, sineAxis);
  const trace = aa + bb;
  const discriminant = Math.sqrt(Math.max(0, (aa - bb) ** 2 + 4 * ab ** 2));
  const majorEigenvalue = (trace + discriminant) / 2;
  const minorEigenvalue = Math.max(0, (trace - discriminant) / 2);
  if (majorEigenvalue <= 1e-28) return null;
  const majorAmplitude = Math.sqrt(majorEigenvalue);
  const minorAmplitude = Math.sqrt(minorEigenvalue);
  const coefficients = principalCoefficients(aa, bb, ab, majorEigenvalue);
  const majorAxis = vectorNormalize(vectorAdd(
    vectorScale(cosineAxis, coefficients[0]),
    vectorScale(sineAxis, coefficients[1])));
  const minorAxis = minorAmplitude > majorAmplitude * 1e-12
    ? vectorNormalize(vectorAdd(
      vectorScale(cosineAxis, -coefficients[1]),
      vectorScale(sineAxis, coefficients[0])))
    : null;
  const normal = minorAxis ? vectorNormalize(vectorCross(majorAxis, minorAxis)) : null;
  return {
    electric, majorAxis, minorAxis, normal, majorAmplitude, minorAmplitude,
    axialRatio: minorAmplitude > majorAmplitude * 1e-12
      ? majorAmplitude / minorAmplitude : Infinity,
  };
}
