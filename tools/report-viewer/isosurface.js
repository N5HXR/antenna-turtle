const cubeCorners = [
  [0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0],
  [0, 0, 1], [1, 0, 1], [1, 1, 1], [0, 1, 1],
];

// Six tetrahedra sharing the 0-6 body diagonal.  Tetrahedra avoid the
// ambiguous saddle cases of a compact marching-cubes implementation.
const cubeTetrahedra = [
  [0, 5, 1, 6], [0, 1, 2, 6], [0, 2, 3, 6],
  [0, 3, 7, 6], [0, 7, 4, 6], [0, 4, 5, 6],
];

function interpolate(left, right, threshold) {
  const span = right.value - left.value;
  const mix = Math.abs(span) < Number.EPSILON
    ? 0.5 : Math.max(0, Math.min(1, (threshold - left.value) / span));
  return [
    left.point[0] + (right.point[0] - left.point[0]) * mix,
    left.point[1] + (right.point[1] - left.point[1]) * mix,
    left.point[2] + (right.point[2] - left.point[2]) * mix,
  ];
}

function emitTriangle(positions, a, b, c) {
  positions.push(...a, ...b, ...c);
}

function polygonizeTetrahedron(positions, vertices, threshold) {
  const inside = [], outside = [];
  vertices.forEach(vertex =>
    (vertex.value >= threshold ? inside : outside).push(vertex));
  if (inside.length === 0 || inside.length === 4) return;
  if (inside.length === 1 || inside.length === 3) {
    const lone = inside.length === 1 ? inside[0] : outside[0];
    const others = inside.length === 1 ? outside : inside;
    const triangle = others.map(vertex => interpolate(lone, vertex, threshold));
    if (inside.length === 1) emitTriangle(positions, ...triangle);
    else emitTriangle(positions, triangle[0], triangle[2], triangle[1]);
    return;
  }
  const [a, b] = inside, [c, d] = outside;
  const ac = interpolate(a, c, threshold);
  const ad = interpolate(a, d, threshold);
  const bc = interpolate(b, c, threshold);
  const bd = interpolate(b, d, threshold);
  emitTriangle(positions, ac, bc, ad);
  emitTriangle(positions, ad, bc, bd);
}

export function marchingTetrahedra({
  dimensions, coordinates, values, valueAt, threshold, stride = 1,
  transform = point => point,
}) {
  const [nx, ny, nz] = dimensions;
  const sampleIndex = (x, y, z) => x + nx * (y + ny * z);
  const scalarAt = valueAt ?? ((x, y, z) => values[sampleIndex(x, y, z)]);
  const positions = [];
  for (let z = 0; z < nz - 1; z += stride) {
    const nextZ = Math.min(z + stride, nz - 1);
    for (let y = 0; y < ny - 1; y += stride) {
      const nextY = Math.min(y + stride, ny - 1);
      for (let x = 0; x < nx - 1; x += stride) {
        const nextX = Math.min(x + stride, nx - 1);
        const indices = [x, y, z];
        const next = [nextX, nextY, nextZ];
        const vertices = cubeCorners.map(offset => {
          const ix = offset[0] ? next[0] : indices[0];
          const iy = offset[1] ? next[1] : indices[1];
          const iz = offset[2] ? next[2] : indices[2];
          return {
            point: transform([coordinates[0][ix], coordinates[1][iy], coordinates[2][iz]]),
            value: scalarAt(ix, iy, iz),
          };
        });
        const above = vertices.some(vertex => vertex.value >= threshold);
        const below = vertices.some(vertex => vertex.value < threshold);
        if (!above || !below) continue;
        for (const tetrahedron of cubeTetrahedra)
          polygonizeTetrahedron(positions,
            tetrahedron.map(index => vertices[index]), threshold);
      }
    }
  }
  return new Float32Array(positions);
}
