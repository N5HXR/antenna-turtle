export function crossVector(left, right) {
  return [
    left[1] * right[2] - left[2] * right[1],
    left[2] * right[0] - left[0] * right[2],
    left[0] * right[1] - left[1] * right[0],
  ];
}

export function instantaneousVector(phasor, phaseRadians) {
  const cosine = Math.cos(phaseRadians), sine = Math.sin(phaseRadians);
  return phasor.real.map((value, index) =>
    value * cosine - phasor.imaginary[index] * sine);
}

// The signed instantaneous projection of a field phasor on one Cartesian
// component.  Unlike vector magnitude, this preserves polarity for a
// diverging color scale.
export function instantaneousComponent(phasor, component, phaseRadians) {
  return phasor.real[component] * Math.cos(phaseRadians)
    - phasor.imaginary[component] * Math.sin(phaseRadians);
}

export function averagePoynting(electric, magnetic) {
  const realCross = crossVector(electric.real, magnetic.real);
  const imaginaryCross = crossVector(electric.imaginary, magnetic.imaginary);
  return realCross.map((value, index) =>
    0.5 * (value + imaginaryCross[index]));
}

export function instantaneousPoynting(electric, magnetic, phaseRadians) {
  return crossVector(
    instantaneousVector(electric, phaseRadians),
    instantaneousVector(magnetic, phaseRadians));
}
