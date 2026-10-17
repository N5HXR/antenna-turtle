export function gainOf(sample, component) {
  const value = sample?.[`${component}_gain_db`];
  return Number.isFinite(value) ? value : null;
}

export function dbPowerInterpolate(a, b, fraction) {
  if (!Number.isFinite(a)) return b;
  if (!Number.isFinite(b)) return a;
  const power = (1 - fraction) * 10 ** (a / 10) + fraction * 10 ** (b / 10);
  return 10 * Math.log10(Math.max(power, Number.MIN_VALUE));
}

function bracket(values, target) {
  if (target <= values[0]) return [0, 0, 0];
  if (target >= values.at(-1)) return [values.length - 1, values.length - 1, 0];
  for (let index = 0; index < values.length - 1; ++index) {
    if (target >= values[index] && target <= values[index + 1])
      return [index, index + 1,
        (target - values[index]) / (values[index + 1] - values[index])];
  }
  return [0, 0, 0];
}

export function patternTable(pattern) {
  const table = new Map();
  for (const sample of pattern.samples)
    table.set(`${sample.theta_deg}|${sample.phi_deg}`, sample);
  return table;
}

export function sampleAt(pattern, table, thetaIndex, phiIndex) {
  const theta = pattern.theta_values[thetaIndex];
  const phi = pattern.phi_values[(phiIndex + pattern.phi_values.length) % pattern.phi_values.length];
  return table.get(`${theta}|${phi}`);
}

export function interpolatedGain(pattern, table, elevation, azimuth, component) {
  const theta = 90 - elevation;
  const [ta, tb, tf] = bracket(pattern.theta_values, theta);
  const phis = pattern.phi_values;
  const normalized = ((azimuth % 360) + 360) % 360;
  let pa = 0;
  while (pa + 1 < phis.length && phis[pa + 1] <= normalized) ++pa;
  const pb = (pa + 1) % phis.length;
  const phiA = phis[pa];
  const phiB = pb === 0 ? phis[0] + 360 : phis[pb];
  const pf = phiB === phiA ? 0 : (normalized - phiA) / (phiB - phiA);
  const a = dbPowerInterpolate(
    gainOf(sampleAt(pattern, table, ta, pa), component),
    gainOf(sampleAt(pattern, table, ta, pb), component), pf);
  const b = dbPowerInterpolate(
    gainOf(sampleAt(pattern, table, tb, pa), component),
    gainOf(sampleAt(pattern, table, tb, pb), component), pf);
  return dbPowerInterpolate(a, b, tf);
}

export function globalGainRange(pattern, component) {
  const gains = pattern.samples.map(sample => gainOf(sample, component)).filter(Number.isFinite);
  if (!gains.length) return null;
  return { minimum: Math.min(...gains), peak: Math.max(...gains) };
}

export function componentGainRange(pattern, component, referenceComponent = "total") {
  const componentRange = globalGainRange(pattern, component);
  const referenceRange = globalGainRange(pattern, referenceComponent);
  if (!componentRange || !referenceRange) return null;
  return {
    minimum: componentRange.minimum,
    peak: componentRange.peak,
    referencePeak: referenceRange.peak,
    relativeMinimum: componentRange.minimum - referenceRange.peak,
    relativePeak: componentRange.peak - referenceRange.peak,
  };
}

// Plotly polar coordinates treat negative radii as points reflected through
// the origin. Decibel plots are naturally negative, so translate the physical
// scale to a nonnegative display radius and preserve the dB values as labels.
export function polarDisplayScale(values, range, tickStep = 10) {
  const [lower, upper] = range;
  const span = Math.max(upper - lower, Number.EPSILON);
  const radius = values.map(value => Math.max(lower, Math.min(upper, value)) - lower);
  const firstTick = Math.ceil(lower / tickStep) * tickStep;
  const ticktext = [];
  for (let value = firstTick; value <= upper + tickStep * 1e-9; value += tickStep)
    ticktext.push(value);
  return {
    radius,
    range: [0, span],
    tickvals: ticktext.map(value => value - lower),
    ticktext: ticktext.map(value => `${value}`),
  };
}

export function quantizedGain(relativeDb, step = 3) {
  const bounded = Math.max(-30, Math.min(0, relativeDb));
  const band = Math.floor((-bounded) / step);
  return band === 0 ? 0 : -step * band;
}
