export function complexVectorMagnitude(value) {
  return Math.sqrt(value.real.reduce((sum, component, index) =>
    sum + component ** 2 + value.imaginary[index] ** 2, 0));
}

export function subtractPhasors(left, right) {
  return {
    real: left.real.map((value, index) => value - right.real[index]),
    imaginary: left.imaginary.map((value, index) => value - right.imaginary[index]),
  };
}

export function surfaceCurrent(normal, magneticOutside, magneticInside) {
  const jump = subtractPhasors(magneticOutside, magneticInside);
  const cross = values => [
    normal[1] * values[2] - normal[2] * values[1],
    normal[2] * values[0] - normal[0] * values[2],
    normal[0] * values[1] - normal[1] * values[0],
  ];
  return { real: cross(jump.real), imaginary: cross(jump.imaginary) };
}

export function surfaceCharge(normal, fluxOutside, fluxInside) {
  const jump = subtractPhasors(fluxOutside, fluxInside);
  const dot = values => values.reduce((sum, value, index) =>
    sum + normal[index] * value, 0);
  return { real: dot(jump.real), imaginary: dot(jump.imaginary) };
}

export function instantaneousVector(phasor, phaseRadians) {
  const cosine = Math.cos(phaseRadians), sine = Math.sin(phaseRadians);
  return phasor.real.map((value, index) =>
    value * cosine - phasor.imaginary[index] * sine);
}
