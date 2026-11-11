export function loadImpedance(load, frequencyMhz) {
  const omega = 2 * Math.PI * Number(frequencyMhz) * 1e6;
  const resistance = Number(load?.resistance_ohms) || 0;
  const inductance = Number(load?.inductance_h) || 0;
  const capacitance = Number(load?.capacitance_f) || 0;
  if (load?.topology === "parallel") {
    const conductance = resistance > 0 ? 1 / resistance : 0;
    const susceptance = (capacitance > 0 ? omega * capacitance : 0) -
      (inductance > 0 ? 1 / (omega * inductance) : 0);
    const denominator = conductance ** 2 + susceptance ** 2;
    return denominator > 0
      ? { real: conductance / denominator, imaginary: -susceptance / denominator }
      : { real: Infinity, imaginary: 0 };
  }
  return {
    real: resistance,
    imaginary: (inductance > 0 ? omega * inductance : 0) -
      (capacitance > 0 ? 1 / (omega * capacitance) : 0),
  };
}

// NEC's segment-current scalar is referenced to the authored start-to-end
// direction.  Reflected or independently authored collinear wires may reverse
// that direction at a junction even when the physical current vector is
// continuous.  Choose the sign of the largest Cartesian direction component
// so instantaneous colors use one canonical orientation for a straight run.
export function canonicalWireSign(start, end) {
  const delta = [0, 1, 2].map(index => Number(end[index]) - Number(start[index]));
  const axis = delta.reduce((best, value, index) =>
    Math.abs(value) > Math.abs(delta[best]) ? index : best, 0);
  return delta[axis] < 0 ? -1 : 1;
}

// Express a scalar NEC current phase in the canonical direction used by the
// viewer. Negating a phasor rotates it by 180 degrees; wrap the result onto the
// principal interval so reflected wire halves remain visually continuous.
export function canonicalCurrentPhase(phaseDegrees, wireSign = 1) {
  const oriented = Number(phaseDegrees) + (wireSign < 0 ? 180 : 0);
  return ((oriented + 180) % 360 + 360) % 360 - 180;
}

// Recover the physical, instantaneous Cartesian current vector from NEC's
// scalar current.  NEC references the scalar to the wire's authored
// start-to-end direction, so multiplying by that unit tangent removes the
// arbitrary endpoint convention.
export function instantaneousWireCurrent(current, phaseDegrees, start, end) {
  const radians = Number(phaseDegrees) * Math.PI / 180;
  const scalar = (Number(current?.real) || 0) * Math.cos(radians) -
    (Number(current?.imaginary) || 0) * Math.sin(radians);
  const delta = [0, 1, 2].map(index => Number(end[index]) - Number(start[index]));
  const length = Math.hypot(...delta);
  return length > 0
    ? delta.map(component => component === 0 ? 0 : scalar * component / length)
    : [0, 0, 0];
}

// Encode a signed XYZ direction with three opponent spectra:
//   +X red / -X cyan, +Y green / -Y magenta, +Z blue / -Z yellow.
// Direction sets the mixture. Magnitude raises that mixture out of black, as
// if each opponent pair had its own negative-color -> black -> positive-color
// ramp. At full magnitude, reversing a vector produces its complementary
// color; low-current conductors naturally darken toward black.
export function opponentCurrentColor(vector, maximum) {
  const value = [0, 1, 2].map(index => Number(vector[index]) || 0);
  const magnitude = Math.hypot(...value);
  const amount = Math.min(1, magnitude / Math.max(Number(maximum), Number.EPSILON));
  if (magnitude <= Number.EPSILON || amount <= Number.EPSILON) return [0, 0, 0];
  const weights = value.map(Math.abs);
  const weightSum = weights.reduce((sum, component) => sum + component, 0);
  const pairs = [
    value[0] < 0 ? [0, 1, 1] : [1, 0, 0],
    value[1] < 0 ? [1, 0, 1] : [0, 1, 0],
    value[2] < 0 ? [1, 1, 0] : [0, 0, 1],
  ];
  const brightness = Math.sqrt(amount);
  return [0, 1, 2].map(channel => brightness * pairs.reduce((sum, pair, axis) =>
    sum + weights[axis] * pair[channel], 0) / weightSum);
}
