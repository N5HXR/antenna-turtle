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
