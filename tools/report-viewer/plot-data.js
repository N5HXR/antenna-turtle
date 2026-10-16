export function portNames(measurements) {
  return (measurements?.ports || []).map(port => String(port.name));
}

export function samplesForPort(measurements, portName) {
  return (measurements?.port_samples || [])
    .filter(sample => String(sample.port) === String(portName))
    .slice()
    .sort((left, right) => left.frequency_mhz - right.frequency_mhz);
}

export function reflectionMagnitude(sample) {
  const reflection = sample.reflection_coefficient || {};
  if (Number.isFinite(reflection.magnitude)) return reflection.magnitude;
  return Math.hypot(reflection.real || 0, reflection.imaginary || 0);
}

export function normalizedImpedance(sample, referenceImpedance) {
  const impedance = sample.impedance_ohms || {};
  return {
    real: impedance.real / referenceImpedance,
    imaginary: impedance.imaginary / referenceImpedance,
  };
}

function sampleAt(left, right, amount, referenceImpedance) {
  const real = left.impedance_ohms.real +
    (right.impedance_ohms.real - left.impedance_ohms.real) * amount;
  const imaginary = left.impedance_ohms.imaginary +
    (right.impedance_ohms.imaginary - left.impedance_ohms.imaginary) * amount;
  const frequency_mhz = left.frequency_mhz +
    (right.frequency_mhz - left.frequency_mhz) * amount;
  const denominator = (real + referenceImpedance) ** 2 + imaginary ** 2;
  const reflectionReal = denominator > 0
    ? (real ** 2 + imaginary ** 2 - referenceImpedance ** 2) / denominator : 1;
  const reflectionImaginary = denominator > 0
    ? 2 * referenceImpedance * imaginary / denominator : 0;
  const magnitude = Math.hypot(reflectionReal, reflectionImaginary);
  return {
    port: left.port,
    frequency_mhz,
    impedance_ohms: { real, imaginary },
    reflection_coefficient: {
      real: reflectionReal,
      imaginary: reflectionImaginary,
      magnitude,
    },
    s11_db: magnitude > 0 ? 20 * Math.log10(magnitude) : -Infinity,
    interpolated: true,
  };
}

export function interpolatePortSamples(samples, referenceImpedance, subdivisions = 20) {
  if (samples.length < 2 || !Number.isFinite(referenceImpedance) || subdivisions < 1)
    return samples.slice();
  const result = [];
  for (let index = 0; index < samples.length - 1; index += 1) {
    const left = samples[index];
    const right = samples[index + 1];
    result.push(left);
    const amounts = [];
    for (let step = 1; step < subdivisions; step += 1)
      amounts.push(step / subdivisions);
    const leftX = left.impedance_ohms?.imaginary;
    const rightX = right.impedance_ohms?.imaginary;
    if (Number.isFinite(leftX) && Number.isFinite(rightX) && leftX * rightX < 0)
      amounts.push(-leftX / (rightX - leftX));
    amounts.sort((a, b) => a - b);
    let previous = -1;
    for (const amount of amounts) {
      if (Math.abs(amount - previous) < 1e-10) continue;
      result.push(sampleAt(left, right, amount, referenceImpedance));
      previous = amount;
    }
  }
  result.push(samples.at(-1));
  return result;
}

export function returnLoss(sample) {
  return -sample.s11_db;
}

export function nearestSample(samples, frequencyMHz) {
  if (!samples.length || !Number.isFinite(frequencyMHz)) return null;
  return samples.reduce((nearest, sample) =>
    Math.abs(sample.frequency_mhz - frequencyMHz) <
      Math.abs(nearest.frequency_mhz - frequencyMHz) ? sample : nearest);
}

export function vswr(sample) {
  const magnitude = reflectionMagnitude(sample);
  return magnitude >= 1 ? Infinity : (1 + magnitude) / (1 - magnitude);
}

export function vswrAxisRange(samples) {
  const finiteValues = samples.map(vswr).filter(Number.isFinite);
  const maximum = Math.max(1, ...finiteValues);
  return [1, maximum > 1 ? 1 + (maximum - 1) * 1.05 : 1.1];
}

export function sParameterGroups(measurements) {
  const groups = new Map();
  for (const sample of measurements?.s_parameters || []) {
    const key = `${sample.to}←${sample.from}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(sample);
  }
  for (const samples of groups.values())
    samples.sort((left, right) => left.frequency_mhz - right.frequency_mhz);
  return groups;
}

export function availablePlots(measurements) {
  const plots = [
    ["smith", "Smith chart"],
    ["s11", "S11 magnitude (dB)"],
    ["return-loss", "return loss"],
    ["vswr", "VSWR"],
    ["impedance", "impedance R / X"],
  ];
  if ((measurements?.s_parameters || []).length)
    plots.push(["s-parameters", "S-parameters"]);
  return plots;
}
