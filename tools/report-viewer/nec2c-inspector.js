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
