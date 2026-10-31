import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { createPlotWorkspace, Plotly } from "./plot-workspace.js";
import { makeCollapsibleSettingsPanel } from "./panel-collapse.js";
import { loadImpedance } from "./nec2c-inspector.js";
import { averagePoynting, instantaneousPoynting } from "./field-math.js";
import {
  componentGainRange,
  elevationPlaneDirection,
  gainOf,
  globalGainRange,
  interpolatedGain,
  interpolatedPolarization,
  patternTable,
  polarDisplayScale,
  quantizedGain,
  sampleAt,
} from "./pattern-data.js";

const palettes = {
  mmana: [[-30,[12,20,180]],[-20,[0,100,255]],[-10,[0,230,255]],[-6,[0,238,95]],
    [-3,[235,255,18]],[-1.5,[255,192,18]],[-0.5,[255,58,18]],[0,[255,20,205]]],
  magma: [[-30,[0,0,4]],[-26.25,[28,16,68]],[-22.5,[79,18,123]],[-18.75,[129,37,129]],
    [-15,[181,54,122]],[-11.25,[229,80,100]],[-7.5,[251,135,97]],[-3.75,[254,194,135]],[0,[252,253,191]]],
  inferno: [[-30,[0,0,4]],[-26.25,[31,12,72]],[-22.5,[85,15,109]],[-18.75,[136,34,106]],
    [-15,[186,54,85]],[-11.25,[227,89,51]],[-7.5,[249,140,10]],[-3.75,[249,201,50]],[0,[252,255,164]]],
  viridis: [[-30,[68,1,84]],[-26.25,[72,40,120]],[-22.5,[62,74,137]],[-18.75,[49,104,142]],
    [-15,[38,130,142]],[-11.25,[31,158,137]],[-7.5,[53,183,121]],[-3.75,[109,205,89]],[0,[253,231,37]]],
  grayscale: [[-30,[24,24,24]],[-20,[92,92,92]],[-10,[174,174,174]],[0,[255,255,255]]],
  electric: [[-30,[0,0,4]],[-26.25,[0,0,48]],[-22.5,[0,0,105]],[-18.75,[35,0,145]],
    [-15,[85,0,175]],[-11.25,[145,0,205]],[-7.5,[215,0,235]],[-3.75,[255,45,245]],[0,[255,190,255]]],
};
palettes.sdr = palettes.magma;

function stopColor(rgb) {
  return new THREE.Color(rgb[0] / 255, rgb[1] / 255, rgb[2] / 255);
}

function colorAt(paletteName, relativeDb) {
  const selected = palettes[paletteName] || palettes.mmana;
  const bounded = Math.max(-30, Math.min(0, relativeDb));
  for (let index = 1; index < selected.length; ++index) {
    if (bounded <= selected[index][0]) {
      const [aStop, a] = selected[index - 1];
      const [bStop, b] = selected[index];
      return stopColor(a).lerp(stopColor(b), (bounded - aStop) / (bStop - aStop));
    }
  }
  return stopColor(selected.at(-1)[1]);
}

function cssColor(rgb) {
  return `rgb(${rgb.join(",")})`;
}

function threeColorCss(color) {
  return `rgb(${Math.round(color.r * 255)},${Math.round(color.g * 255)},${Math.round(color.b * 255)})`;
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, character => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  })[character]);
}

function formatEngineering(value, units) {
  if (!Number.isFinite(value)) return `unavailable ${units}`.trim();
  if (value === 0) return `0 ${units}`.trim();
  const prefixes = [[1e9, "G"], [1e6, "M"], [1e3, "k"], [1, ""],
    [1e-3, "m"], [1e-6, "µ"], [1e-9, "n"], [1e-12, "p"]];
  const magnitude = Math.abs(value);
  const [scale, prefix] = prefixes.find(([candidate]) => magnitude >= candidate) || [1e-12, "p"];
  return `${(value / scale).toPrecision(4)} ${prefix}${units}`.trim();
}

function impedanceMagnitude(impedance) {
  return Math.hypot(impedance.real, impedance.imaginary);
}

function dbRelative(value, reference) {
  return 20 * Math.log10(Math.max(Number.EPSILON, value) /
    Math.max(Number.EPSILON, reference));
}

function fieldVector(sample, quantity) {
  const values = sample?.[quantity];
  if (!Array.isArray(values) || values.length !== 6) return null;
  return [[values[0], values[1]], [values[2], values[3]], [values[4], values[5]]];
}

function complexMagnitude([real, imaginary]) {
  return Math.hypot(real, imaginary);
}

function vectorEnvelope(vector) {
  return vector ? Math.hypot(...vector.map(complexMagnitude)) : 0;
}

function instantaneousVector(vector, phaseDegrees) {
  if (!vector) return [0, 0, 0];
  const phase = phaseDegrees * Math.PI / 180;
  return vector.map(([real, imaginary]) => real * Math.cos(phase) - imaginary * Math.sin(phase));
}

function averagePoyntingSample(sample) {
  const electric = fieldVector(sample, "electric");
  const magnetic = fieldVector(sample, "magnetic");
  if (!electric || !magnetic) return null;
  return averagePoynting(complexVectorPhasor(electric), complexVectorPhasor(magnetic));
}

function complexVectorPhasor(vector) {
  return {
    real: vector.map(component => component[0]),
    imaginary: vector.map(component => component[1]),
  };
}

function instantaneousPoyntingSample(sample, phaseDegrees) {
  const electric = fieldVector(sample, "electric");
  const magnetic = fieldVector(sample, "magnetic");
  if (!electric || !magnetic) return null;
  return instantaneousPoynting(
    complexVectorPhasor(electric), complexVectorPhasor(magnetic),
    phaseDegrees * Math.PI / 180);
}

function feedCentroid(data) {
  const points = data.geometry.wires.filter(wire => wire.feed).map(wire =>
    new THREE.Vector3(...wire.start).lerp(new THREE.Vector3(...wire.end), wire.feed.fraction));
  if (!points.length) return new THREE.Vector3();
  return points.reduce((sum, point) => sum.add(point), new THREE.Vector3())
    .multiplyScalar(1 / points.length);
}

function cylinderBetween(start, end, radius, material) {
  const a = new THREE.Vector3(...start);
  const b = new THREE.Vector3(...end);
  const delta = b.clone().sub(a);
  const mesh = new THREE.Mesh(
    new THREE.CylinderGeometry(radius, radius, delta.length(), 14, 1, false), material);
  mesh.position.copy(a.clone().add(b).multiplyScalar(0.5));
  mesh.quaternion.setFromUnitVectors(new THREE.Vector3(0, 1, 0), delta.normalize());
  return mesh;
}

function addGeometry(data, group) {
  const authoredBounds = new THREE.Box3();
  const surfacePatches = data.geometry.surface_patches || [];
  const dielectricVolumes = data.geometry.dielectric_volumes || [];
  for (const patch of surfacePatches) {
    for (const corner of patch.corners || []) {
      authoredBounds.expandByPoint(new THREE.Vector3(...corner));
    }
  }
  for (const wire of data.geometry.wires) {
    authoredBounds.expandByPoint(new THREE.Vector3(...wire.start));
    authoredBounds.expandByPoint(new THREE.Vector3(...wire.end));
  }
  for (const volume of dielectricVolumes) {
    authoredBounds.expandByPoint(new THREE.Vector3(...volume.minimum));
    authoredBounds.expandByPoint(new THREE.Vector3(...volume.maximum));
  }
  const presentationRadius = Math.max(
    authoredBounds.getSize(new THREE.Vector3()).length() * 0.0012, 1e-7);
  const segments = [];
  const markers = [];
  let surfaceMesh = null;
  const surfaceVertexRanges = [];
  const surfaceVertexKeys = [];
  const surfaceCornerPatches = new Map();
  const dielectricMeshes = [];
  for (const volume of dielectricVolumes) {
    const minimum = new THREE.Vector3(...volume.minimum);
    const maximum = new THREE.Vector3(...volume.maximum);
    const size = maximum.clone().sub(minimum);
    const geometry = new THREE.BoxGeometry(size.x, size.y, size.z);
    const mesh = new THREE.Mesh(geometry, new THREE.MeshBasicMaterial({
      color: 0x31efff, transparent: true, opacity: 0.18,
      side: THREE.DoubleSide, depthWrite: false, toneMapped: false,
    }));
    mesh.position.copy(minimum.clone().add(maximum).multiplyScalar(0.5));
    mesh.renderOrder = 0;
    mesh.userData.dielectricVolume = volume;
    group.add(mesh);
    const outline = new THREE.LineSegments(
      new THREE.EdgesGeometry(geometry),
      new THREE.LineBasicMaterial({ color: 0x7df9ff, transparent: true, opacity: 0.72 }));
    outline.position.copy(mesh.position);
    outline.renderOrder = 2;
    group.add(outline);
    dielectricMeshes.push(mesh);
  }
  if (surfacePatches.length) {
    const positions = [];
    const colors = [];
    const edgePoints = [];
    const base = new THREE.Color(0xc58d35);
    for (const [patchIndex, patch] of surfacePatches.entries()) {
      const corners = (patch.corners || []).map(point => new THREE.Vector3(...point));
      const cornerKeys = corners.map(point => point.toArray()
        .map(coordinate => Number(coordinate).toPrecision(12)).join(","));
      for (const key of cornerKeys) {
        if (!surfaceCornerPatches.has(key)) surfaceCornerPatches.set(key, []);
        surfaceCornerPatches.get(key).push(patchIndex);
      }
      const firstVertex = positions.length / 3;
      if (corners.length < 3) {
        surfaceVertexRanges.push([firstVertex, 0]);
        continue;
      }
      for (let index = 1; index + 1 < corners.length; ++index) {
        positions.push(...corners[0].toArray(), ...corners[index].toArray(),
          ...corners[index + 1].toArray());
        surfaceVertexKeys.push(cornerKeys[0], cornerKeys[index], cornerKeys[index + 1]);
        for (let vertex = 0; vertex < 3; ++vertex) colors.push(base.r, base.g, base.b);
      }
      surfaceVertexRanges.push([firstVertex, positions.length / 3 - firstVertex]);
      for (let index = 0; index < corners.length; ++index) {
        edgePoints.push(corners[index], corners[(index + 1) % corners.length]);
      }
    }
    const surfaceGeometry = new THREE.BufferGeometry();
    surfaceGeometry.setAttribute("position",
      new THREE.Float32BufferAttribute(positions, 3));
    surfaceGeometry.setAttribute("color",
      new THREE.Float32BufferAttribute(colors, 3));
    surfaceGeometry.computeVertexNormals();
    surfaceMesh = new THREE.Mesh(surfaceGeometry, new THREE.MeshBasicMaterial({
      vertexColors: true, transparent: true, opacity: 0.78,
      side: THREE.DoubleSide, depthWrite: true, toneMapped: false,
    }));
    surfaceMesh.renderOrder = 1;
    surfaceMesh.userData.baseColor = 0xc58d35;
    group.add(surfaceMesh);
    const edgeGeometry = new THREE.BufferGeometry().setFromPoints(edgePoints);
    const edges = new THREE.LineSegments(edgeGeometry, new THREE.LineBasicMaterial({
      color: 0xffd98a, transparent: true, opacity: 0.34,
    }));
    edges.renderOrder = 2;
    group.add(edges);
  }
  const feedMaterial = new THREE.MeshStandardMaterial({
    color: 0xff42d0, emissive: 0xff1498, emissiveIntensity: 1.2,
    depthTest: false,
  });
  for (const wire of data.geometry.wires) {
    const radius = Math.max(wire.diameter / 2, presentationRadius);
    const count = Math.max(1, Number(wire.segment_count) || 1);
    const start = new THREE.Vector3(...wire.start);
    const end = new THREE.Vector3(...wire.end);
    for (let index = 0; index < count; ++index) {
      const a = start.clone().lerp(end, index / count);
      const b = start.clone().lerp(end, (index + 1) / count);
      const baseColor = wire.color && wire.color !== "null"
        ? new THREE.Color(String(wire.color).replace(/\s+/g, "")) : new THREE.Color(0x8eeaff);
      const material = new THREE.MeshBasicMaterial({ color: baseColor, depthTest: false });
      const conductor = cylinderBetween(a.toArray(), b.toArray(), radius, material);
      conductor.renderOrder = 3;
      conductor.userData.segmentKey = `${wire.id}:${index + 1}`;
      conductor.userData.baseColor = baseColor.getHex();
      conductor.userData.wire = wire;
      conductor.userData.segmentIndex = index + 1;
      conductor.userData.segmentCount = count;
      conductor.userData.segmentCenter = a.clone().add(b).multiplyScalar(0.5).toArray();
      group.add(conductor);
      segments.push(conductor);
    }
    if (wire.feed) {
      const point = new THREE.Vector3(...wire.start).lerp(new THREE.Vector3(...wire.end), wire.feed.fraction);
      const marker = new THREE.Mesh(
        new THREE.SphereGeometry(radius * 2.8, 18, 10), feedMaterial);
      marker.position.copy(point);
      marker.renderOrder = 4;
      marker.userData.inspectorType = "feed";
      marker.userData.feed = wire.feed;
      marker.userData.wire = wire;
      group.add(marker);
      markers.push(marker);
    }
  }
  const portMaterials = {
    negative: new THREE.MeshStandardMaterial({ color: 0x36a3ff, emissive: 0x103caa,
      emissiveIntensity: 1, depthTest: false }),
    positive: new THREE.MeshStandardMaterial({ color: 0xff556f, emissive: 0xaa102c,
      emissiveIntensity: 1, depthTest: false }),
  };
  for (const port of data.geometry.ports || []) {
    for (const polarity of ["negative", "positive"]) {
      const marker = new THREE.Mesh(
        new THREE.SphereGeometry(presentationRadius * 3.1, 18, 10), portMaterials[polarity]);
      marker.position.set(...port[polarity]);
      marker.renderOrder = 6;
      marker.userData.inspectorType = "port";
      marker.userData.port = port;
      marker.userData.polarity = polarity;
      group.add(marker); markers.push(marker);
    }
  }
  const loadMaterial = new THREE.MeshStandardMaterial({
    color: 0xffa31a, emissive: 0xff4f00, emissiveIntensity: 1.25, depthTest: false,
  });
  for (const load of data.geometry.lumped_loads || []) {
    const marker = new THREE.Mesh(
      new THREE.OctahedronGeometry(presentationRadius * 5.2), loadMaterial);
    marker.position.set(...load.center);
    marker.renderOrder = 7;
    marker.userData.inspectorType = "load";
    marker.userData.load = load;
    group.add(marker); markers.push(marker);
  }
  if (data.geometry.grounded) {
    const bounds = new THREE.Box3().setFromObject(group);
    const extent = bounds.getSize(new THREE.Vector3()).length() || 1;
    const ground = new THREE.Mesh(
      new THREE.PlaneGeometry(extent * 2.2, extent * 2.2),
      new THREE.MeshStandardMaterial({
        color: 0x1d6174, transparent: true, opacity: 0.18,
        side: THREE.DoubleSide, depthWrite: false,
      }));
    ground.position.z = 0;
    group.add(ground);
  }
  return { segments, markers, surfaceMesh, surfacePatches, surfaceVertexRanges,
    surfaceVertexKeys, surfaceCornerPatches, dielectricMeshes, presentationRadius };
}

function patchCenter(patch) {
  if (Array.isArray(patch.center)) return new THREE.Vector3(...patch.center);
  const corners = patch.corners || [];
  return corners.reduce((sum, point) => sum.add(new THREE.Vector3(...point)),
    new THREE.Vector3()).multiplyScalar(corners.length ? 1 / corners.length : 0);
}

function pointInSurfacePatch(pointArray, patch) {
  const corners = (patch.corners || []).map(point => new THREE.Vector3(...point));
  if (corners.length < 3) return false;
  const point = new THREE.Vector3(...pointArray);
  const origin = corners[0];
  const u = corners[1].clone().sub(origin);
  const v = corners.at(-1).clone().sub(origin);
  const normal = u.clone().cross(v);
  const normalLength = normal.length();
  if (!(normalLength > 0)) return false;
  normal.multiplyScalar(1 / normalLength);
  const scale = Math.max(u.length(), v.length(), 1e-9);
  if (Math.abs(point.clone().sub(origin).dot(normal)) > scale * 0.025 + 1e-6) return false;
  const relative = point.clone().sub(origin);
  const uu = u.dot(u), uv = u.dot(v), vv = v.dot(v);
  const ru = relative.dot(u), rv = relative.dot(v);
  const denominator = uu * vv - uv * uv;
  if (!(Math.abs(denominator) > Number.EPSILON)) return false;
  const a = (ru * vv - rv * uv) / denominator;
  const b = (rv * uu - ru * uv) / denominator;
  return a >= -0.025 && a <= 1.025 && b >= -0.025 && b <= 1.025;
}

function groupSurfaceCurrents(patches, samples) {
  const groups = patches.map(() => []);
  const centers = patches.map(patchCenter);
  for (const sample of samples || []) {
    const point = sample.center || [];
    const candidates = [];
    for (let index = 0; index < patches.length; ++index) {
      if (pointInSurfacePatch(point, patches[index])) candidates.push(index);
    }
    if (!candidates.length) continue;
    const samplePoint = new THREE.Vector3(...point);
    const selected = candidates.reduce((best, index) =>
      samplePoint.distanceToSquared(centers[index]) < samplePoint.distanceToSquared(centers[best])
        ? index : best, candidates[0]);
    groups[selected].push(sample);
  }
  return groups;
}

function complexVectorEnvelope(vector) {
  return Math.sqrt((vector || []).reduce((sum, component) =>
    sum + (component?.real || 0) ** 2 + (component?.imaginary || 0) ** 2, 0));
}

function complexVectorInstantaneousMagnitude(vector, phaseDegrees) {
  const radians = phaseDegrees * Math.PI / 180;
  return Math.sqrt((vector || []).reduce((sum, component) => {
    const value = (component?.real || 0) * Math.cos(radians) -
      (component?.imaginary || 0) * Math.sin(radians);
    return sum + value * value;
  }, 0));
}

function dominantVectorPhase(vector) {
  const component = (vector || []).reduce((best, candidate) => {
    const magnitude = Math.hypot(candidate?.real || 0, candidate?.imaginary || 0);
    const bestMagnitude = Math.hypot(best?.real || 0, best?.imaginary || 0);
    return magnitude > bestMagnitude ? candidate : best;
  }, null);
  return Math.atan2(component?.imaginary || 0, component?.real || 0) * 180 / Math.PI;
}

function distanceToSegment(point, start, end) {
  const delta = end.clone().sub(start);
  const lengthSquared = delta.lengthSq();
  const fraction = lengthSquared
    ? Math.max(0, Math.min(1, point.clone().sub(start).dot(delta) / lengthSquared)) : 0;
  return point.distanceTo(start.clone().addScaledVector(delta, fraction));
}

function distanceToSurfacePatch(point, patch) {
  const corners = (patch.corners || []).map(value => new THREE.Vector3(...value));
  if (corners.length < 3) return Infinity;
  const origin = corners[0];
  const u = corners[1].clone().sub(origin);
  const v = corners.at(-1).clone().sub(origin);
  const relative = point.clone().sub(origin);
  const uu = u.dot(u), uv = u.dot(v), vv = v.dot(v);
  const ru = relative.dot(u), rv = relative.dot(v);
  const denominator = uu * vv - uv * uv;
  if (!(Math.abs(denominator) > Number.EPSILON)) return Infinity;
  const a = Math.max(0, Math.min(1, (ru * vv - rv * uv) / denominator));
  const b = Math.max(0, Math.min(1, (rv * uu - ru * uv) / denominator));
  return point.distanceTo(origin.clone().addScaledVector(u, a).addScaledVector(v, b));
}

function nearFieldPoint(section, uIndex, vIndex) {
  const coordinates = { x: 0, y: 0, z: 0 };
  coordinates[section.normal_axis] = Number(section.position);
  coordinates[section.u_axis] = Number(section.u_values[uIndex]);
  coordinates[section.v_axis] = Number(section.v_values[vIndex]);
  return new THREE.Vector3(coordinates.x, coordinates.y, coordinates.z);
}

const interiorRay = new THREE.Vector3(0.807, 0.361, 0.467).normalize();

function surfaceBodies(patches) {
  const grouped = new Map();
  for (const patch of patches) {
    const name = String(patch.body || "surface");
    if (!grouped.has(name)) grouped.set(name, []);
    grouped.get(name).push(patch);
  }
  return [...grouped.values()].map(bodyPatches => {
    const bounds = new THREE.Box3();
    const triangles = [];
    for (const patch of bodyPatches) {
      const corners = patch.corners || [];
      for (const corner of corners) bounds.expandByPoint(new THREE.Vector3(...corner));
      for (let index = 1; index + 1 < corners.length; ++index) {
        const a = corners[0], b = corners[index], c = corners[index + 1];
        triangles.push({
          ax: a[0], ay: a[1], az: a[2],
          e1x: b[0] - a[0], e1y: b[1] - a[1], e1z: b[2] - a[2],
          e2x: c[0] - a[0], e2y: c[1] - a[1], e2z: c[2] - a[2],
        });
      }
    }
    return { bounds, triangles };
  });
}

function rayTriangleDistance(point, triangle) {
  const { x: dx, y: dy, z: dz } = interiorRay;
  const px = dy * triangle.e2z - dz * triangle.e2y;
  const py = dz * triangle.e2x - dx * triangle.e2z;
  const pz = dx * triangle.e2y - dy * triangle.e2x;
  const determinant = triangle.e1x * px + triangle.e1y * py + triangle.e1z * pz;
  if (Math.abs(determinant) < 1e-12) return null;
  const inverse = 1 / determinant;
  const tx = point.x - triangle.ax, ty = point.y - triangle.ay, tz = point.z - triangle.az;
  const u = (tx * px + ty * py + tz * pz) * inverse;
  if (u < -1e-10 || u > 1 + 1e-10) return null;
  const qx = ty * triangle.e1z - tz * triangle.e1y;
  const qy = tz * triangle.e1x - tx * triangle.e1z;
  const qz = tx * triangle.e1y - ty * triangle.e1x;
  const v = (dx * qx + dy * qy + dz * qz) * inverse;
  if (v < -1e-10 || u + v > 1 + 1e-10) return null;
  const distance = (triangle.e2x * qx + triangle.e2y * qy + triangle.e2z * qz) * inverse;
  return distance > 1e-9 ? distance : null;
}

function pointInsideSurfaceBody(point, body) {
  if (!body.bounds.containsPoint(point)) return false;
  const hits = body.triangles.map(triangle => rayTriangleDistance(point, triangle))
    .filter(distance => distance !== null).sort((a, b) => a - b);
  let uniqueHits = 0, previous = null;
  for (const distance of hits) {
    const tolerance = 1e-8 * Math.max(1, Math.abs(distance));
    if (previous === null || Math.abs(distance - previous) > tolerance) {
      ++uniqueHits; previous = distance;
    }
  }
  return uniqueHits % 2 === 1;
}

function nearFieldExclusionMask(section, geometry) {
  const du = section.u_values.length > 1
    ? Math.abs(section.u_values[1] - section.u_values[0]) : 0;
  const dv = section.v_values.length > 1
    ? Math.abs(section.v_values[1] - section.v_values[0]) : 0;
  // Half a heat-map pixel removes source-coincident and immediately adjacent
  // evaluations without erasing a macroscopic region of valid near field.
  const guard = Math.max(1e-8, 0.55 * Math.hypot(du, dv));
  const wires = (geometry.wires || []).map(wire => ({
    start: new THREE.Vector3(...wire.start), end: new THREE.Vector3(...wire.end),
    radius: Math.max(0, Number(wire.diameter) / 2),
  }));
  // Reject almost every patch with scalar bounds before entering the vector
  // projection routine. A default car body has hundreds of patches and three
  // 121x121 field planes, so constructing vectors for every point/patch pair
  // would make opening an otherwise static report unnecessarily expensive.
  const patches = (geometry.surface_patches || []).map(patch => {
    const corners = patch.corners || [];
    return {
      patch,
      minimum: [0, 1, 2].map(axis =>
        Math.min(...corners.map(corner => Number(corner[axis]))) - guard),
      maximum: [0, 1, 2].map(axis =>
        Math.max(...corners.map(corner => Number(corner[axis]))) + guard),
    };
  });
  const bodies = surfaceBodies(geometry.surface_patches || []);
  const mask = [];
  for (let v = 0; v < section.v_values.length; ++v) {
    for (let u = 0; u < section.u_values.length; ++u) {
      const point = nearFieldPoint(section, u, v);
      const onWire = wires.some(wire =>
        distanceToSegment(point, wire.start, wire.end) <= wire.radius + guard);
      const onPatch = !onWire && patches.some(({ patch, minimum, maximum }) =>
        point.x >= minimum[0] && point.x <= maximum[0] &&
        point.y >= minimum[1] && point.y <= maximum[1] &&
        point.z >= minimum[2] && point.z <= maximum[2] &&
        distanceToSurfacePatch(point, patch) <= guard);
      const insidePec = !onWire && !onPatch && bodies.some(body =>
        pointInsideSurfaceBody(point, body));
      const inGround = Boolean(geometry.grounded) && point.z <= guard;
      mask.push(onWire || onPatch || insidePec || inGround);
    }
  }
  return mask;
}

function fitCamera(camera, controls, object, direction = new THREE.Vector3(1.6, 0, 1.15)) {
  const bounds = new THREE.Box3().setFromObject(object);
  const center = bounds.getCenter(new THREE.Vector3());
  const size = Math.max(bounds.getSize(new THREE.Vector3()).length(), 1e-6);
  controls.target.copy(center);
  camera.position.copy(center).add(direction.normalize().multiplyScalar(size * 1.25));
  camera.near = Math.max(size / 10000, 1e-7);
  camera.far = size * 100;
  camera.updateProjectionMatrix();
  controls.update();
}

function injectStyles() {
  const style = document.createElement("style");
  style.textContent = `
    #nec-tabs{position:fixed;z-index:9;top:18px;right:18px;display:flex;padding:3px;gap:3px;
      border:1px solid #31efff88;background:#06101de8;box-shadow:0 0 18px #00d9ff2f}
    #nec-tabs button{border:0;min-width:94px;color:#79b5c4;box-shadow:none}
    #nec-tabs button.active{color:#fff;background:#14344b;box-shadow:inset 0 -2px #ff3bd4}
    #nec-controls{left:18px;bottom:18px;width:min(470px,calc(100vw - 36px))}
    #nec-controls .opacity-value{display:inline-block;min-width:42px;text-align:right}
    #segment-controls[hidden],#segment-phase-row[hidden],#power-budget[hidden]{display:none}
    #current-scale-controls[hidden]{display:none}
    #segment-legend{margin-top:8px}.segment-legend-bar{height:10px;border:1px solid #78edff;
      background:linear-gradient(90deg,#1743ff,#f7fbff,#ff315f)}
    #segment-legend-labels{display:flex;justify-content:space-between;font-size:10px;color:#9ceeff}
    #power-budget{margin-top:8px;padding-top:7px;border-top:1px solid #31efff44;
      color:#fff45c;font-size:10px;line-height:1.45}
    #conductor-inspector{position:fixed;z-index:8;right:18px;bottom:18px;width:min(390px,calc(100vw - 36px));
      min-height:118px;font-size:11px;line-height:1.48;pointer-events:auto}
    #conductor-inspector[hidden],#current-profile[hidden]{display:none}
    #conductor-inspector .inspector-title{display:flex;align-items:center;justify-content:space-between;
      color:#fff;font-size:13px;margin-bottom:6px}
    #conductor-inspector .inspector-grid{display:grid;grid-template-columns:max-content 1fr;gap:2px 12px}
    #conductor-inspector .inspector-grid span:nth-child(odd){color:#8beeff}
    #conductor-inspector .inspector-note{margin-top:7px;color:#fff45c}
    #conductor-inspector button{margin-top:8px}
    #current-profile{position:fixed;z-index:7;right:18px;top:78px;width:min(720px,calc(100vw - 36px));
      height:min(390px,45vh);padding:8px}
    #current-profile-header{display:flex;align-items:center;justify-content:space-between;
      height:34px;color:#7df9ff;padding:0 5px}
    #current-profile-plot{height:calc(100% - 34px)}
    #pattern-legend{margin-top:10px}.pattern-legend-bar{height:12px;border:1px solid #78edff;
      border-radius:2px;box-shadow:0 0 8px #00d9ff25}
    .pattern-legend-scale{display:grid;grid-template-columns:46px 1fr;margin-top:4px;
      color:#d8fbff;font-size:10px}.pattern-legend-scale>span:first-child{color:#8beeff}
    .pattern-legend-ticks{display:flex;justify-content:space-between}
    #nec-controls[hidden],#pattern-2d[hidden],#viewport[hidden]{display:none}
    #pattern-2d{position:fixed;z-index:3;inset:78px 20px 18px}
    #pattern-2d .pattern-toolbar{position:absolute;z-index:2;left:10px;right:10px;top:0;
      display:flex;align-items:center;gap:10px;padding:9px 12px}
    #pattern-2d .pattern-toolbar input[type=range]{flex:1;min-width:90px}
    #pattern-polar{position:absolute;inset:58px 0 0;border:1px solid #31efff44}
    #plots-workspace{position:fixed;z-index:3;inset:78px 20px 18px}
    #near-field-workspace{position:fixed;z-index:3;inset:78px 20px 18px}
    #near-field-workspace[hidden]{display:none}
    #near-field-workspace .field-toolbar{position:absolute;z-index:2;left:10px;right:10px;top:0;
      display:flex;align-items:center;gap:8px;padding:9px 12px;flex-wrap:wrap}
    #near-field-workspace .field-toolbar input[type=range]{width:140px}
    #near-field-plot{position:absolute;inset:66px 0 0;border:1px solid #31efff44}
    #plots-workspace[hidden]{display:none}.plot-toolbar{position:absolute;z-index:2;left:10px;right:10px;
      top:0;display:flex;align-items:center;gap:10px;padding:9px 12px}
    .plot-toolbar #plot-frequency-note{margin-left:auto;color:#fff45c;font-size:10px}
    #plot-hover-readout{position:absolute;z-index:2;left:10px;right:10px;top:58px;height:38px;
      display:flex;align-items:center;padding:0 12px;border:1px solid #31efff44;
      background:#07101ddd;color:#d8fbff;font-size:10px;white-space:nowrap;overflow:auto}
    #network-plot{position:absolute;inset:102px 0 0;border:1px solid #31efff44}
    #network-plot .hoverlayer .hovertext,#network-plot .hoverlayer .axistext{display:none!important}
    @media(max-width:820px){#nec-tabs{top:8px;right:8px;max-width:calc(100vw - 16px);flex-wrap:wrap}
      #nec-tabs button{min-width:auto}#pattern-2d,#plots-workspace,#near-field-workspace{inset:92px 8px 8px}
      #near-field-plot{inset:104px 0 0}#conductor-inspector{right:8px;bottom:8px;width:calc(100vw - 16px)}
      #current-profile{right:8px;top:92px;width:calc(100vw - 16px)}}
  `;
  document.head.append(style);
}

export async function startNec2cReport(data) {
  injectStyles();
  document.getElementById("title").textContent = data.metadata.title;
  document.getElementById("subtitle").textContent = data.metadata.subtitle;
  document.getElementById("metadata").textContent = JSON.stringify(data.metadata, null, 2);

  const canvas = document.getElementById("viewport");
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true });
  renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
  renderer.setClearColor(0x030611, 1);
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(45, 1, 1e-7, 1e6);
  camera.up.set(0, 0, 1);
  const controls = new OrbitControls(camera, canvas);
  controls.enableDamping = true;
  scene.add(new THREE.HemisphereLight(0x7df9ff, 0x17082d, 2.5));
  const key = new THREE.DirectionalLight(0xff55d8, 3);
  key.position.set(2, -3, 4);
  scene.add(key);

  const geometryGroup = new THREE.Group();
  const patternGroup = new THREE.Group();
  const axisGroup = new THREE.Group();
  scene.add(geometryGroup, patternGroup, axisGroup);
  const geometryDisplay = addGeometry(data, geometryGroup);
  const geometrySegments = geometryDisplay.segments;
  const geometryMarkers = geometryDisplay.markers;
  const diagnostics = data.diagnostics && data.diagnostics !== "null" ? data.diagnostics : null;
  const segmentSamples = new Map((diagnostics?.segment_samples || []).map(sample =>
    [`${sample.wire_id}:${sample.segment}`, sample]));
  const surfaceCurrentGroups = groupSurfaceCurrents(
    geometryDisplay.surfacePatches, diagnostics?.surface_current_samples || []);
  const hasSurfaceCurrents = surfaceCurrentGroups.some(samples => samples.length);
  const volumeCurrentSamples = diagnostics?.volume_current_samples || [];
  const volumeCurrentMeshes = volumeCurrentSamples.map(sample => {
    const geometry = new THREE.BoxGeometry(...sample.size);
    const mesh = new THREE.Mesh(geometry, new THREE.MeshBasicMaterial({
      color: 0x31efff, transparent: true, opacity: 0.72,
      side: THREE.DoubleSide, depthWrite: false, toneMapped: false,
    }));
    mesh.position.set(...sample.center);
    mesh.renderOrder = 2;
    mesh.visible = false;
    geometryGroup.add(mesh);
    return { mesh, sample };
  });
  const hasVolumeCurrents = volumeCurrentMeshes.length > 0;
  const geometryBounds = new THREE.Box3().setFromObject(geometryGroup);
  const patternRadius = Math.max(geometryBounds.getSize(new THREE.Vector3()).length() * 0.68, 1e-4);
  const patternOrigin = feedCentroid(data);
  patternGroup.position.copy(patternOrigin);
  axisGroup.position.copy(patternOrigin);
  const axes = new THREE.AxesHelper(patternRadius * 0.22);
  axes.material.depthTest = false;
  axes.renderOrder = 5;
  axisGroup.add(axes);
  const table = patternTable(data.pattern);
  const totalRange = globalGainRange(data.pattern, "total");
  const referencePeak = totalRange.peak;

  const controlsPanel = document.createElement("section");
  controlsPanel.id = "nec-controls";
  controlsPanel.className = "panel";
  controlsPanel.innerHTML = `<div class="row"><label for="pattern-component">COMPONENT</label>
    <select id="pattern-component"><option value="total">total</option><option value="vertical">vertical (Eθ)</option>
    <option value="horizontal">horizontal (Eφ)</option></select></div>
    <div class="row"><label for="pattern-scale">RADIAL SCALE</label><select id="pattern-scale">
    <option value="arrl">ARRL modified log</option><option value="db">dB</option>
    <option value="linear">linear</option></select></div>
    <div class="row"><label for="pattern-palette">COLOR</label><select id="pattern-palette">
    <option value="mmana">MMANA</option><option value="magma">magma</option><option value="sdr">SDR</option>
    <option value="inferno">inferno</option><option value="viridis">viridis</option>
    <option value="grayscale">grayscale</option><option value="electric">electric</option></select></div>
    <div id="segment-controls" class="row"><label for="segment-display">CONDUCTORS</label>
    <select id="segment-display"><option value="geometry">model color</option>
    <option value="current-magnitude">current magnitude</option><option value="current-phase">current phase</option>
    <option value="current-instantaneous">instantaneous current</option>
    <option value="charge-magnitude">charge magnitude</option>
    <option value="charge-instantaneous">instantaneous charge</option>
    <option value="volume-current-magnitude">dielectric J magnitude</option>
    <option value="volume-current-phase">dielectric J phase</option>
    <option value="volume-current-x-instantaneous">instantaneous dielectric Jx</option>
    <option value="volume-current-y-instantaneous">instantaneous dielectric Jy</option>
    <option value="volume-current-z-instantaneous">instantaneous dielectric Jz</option></select>
    <label id="surface-smoothing-control"><input id="surface-smoothing" type="checkbox">
    SMOOTH PATCH CURRENTS</label></div>
    <div id="segment-phase-row" class="row" hidden><button id="segment-play" type="button">PAUSE</button>
    <label for="segment-phase">PHASE <span id="segment-phase-value">0°</span></label>
    <input id="segment-phase" type="range" min="0" max="359" step="1" value="0"></div>
    <div id="segment-legend" hidden><div class="segment-legend-bar"></div>
    <div id="segment-legend-labels"><span></span><span></span><span></span></div></div>
    <div id="current-scale-controls" class="row" hidden>
    <label for="current-reference">CURRENT REF</label><select id="current-reference">
    <option value="global">all conductors</option><option value="wire">selected wire</option>
    <option value="coax">selected coax</option><option value="fixed">fixed amperes</option></select>
    <input id="current-fixed-reference" type="number" min="1e-15" step="any" value="1" hidden
      aria-label="fixed current reference in amperes"></div>
    <div id="current-floor-row" class="row" hidden><label for="current-floor">FLOOR
    <span id="current-floor-value">−30 dB</span></label>
    <input id="current-floor" type="range" min="-80" max="-10" step="1" value="-30"></div>
    <div class="row"><label for="pattern-opacity">PATTERN OPACITY
    <span id="pattern-opacity-value" class="opacity-value">100%</span></label>
    <input id="pattern-opacity" type="range" min="0.1" max="1" step="0.05" value="1"></div>
    <div class="row"><label><input id="model-visible" type="checkbox" checked> MODEL</label>
    <label><input id="pattern-visible" type="checkbox" checked> PATTERN</label>
    <label><input id="axes-visible" type="checkbox" checked> AXES</label>
    <label><input id="inspector-enabled" type="checkbox" checked> MARKERS / INSPECTOR</label>
    <button id="reset-view" type="button">RESET VIEW</button></div>
    <div class="row"><label><input id="color-bands" type="checkbox"> 3 dB COLOR BANDS</label></div>
    <div id="pattern-legend"><div class="pattern-legend-bar"></div>
    <div class="pattern-legend-scale"><span>REL</span><div class="pattern-legend-ticks" data-scale="relative"></div></div>
    <div class="pattern-legend-scale"><span>dBi</span><div class="pattern-legend-ticks" data-scale="absolute"></div></div></div>
    <div id="pattern-detail"></div><div style="font-size:10px;color:#9ceeff;margin-top:4px">
    XYZ: <span style="color:#ff5555">X boom</span> · <span style="color:#55ff55">Y elements</span> ·
    <span style="color:#6688ff">Z vertical</span></div><div id="power-budget"></div>`;
  document.body.append(controlsPanel);
  makeCollapsibleSettingsPanel(controlsPanel);
  const inspector = document.createElement("section");
  inspector.id = "conductor-inspector";
  inspector.className = "panel";
  inspector.hidden = true;
  document.body.append(inspector);
  const currentProfile = document.createElement("section");
  currentProfile.id = "current-profile";
  currentProfile.className = "panel";
  currentProfile.hidden = true;
  currentProfile.innerHTML = `<div id="current-profile-header"><span></span>
    <button id="current-profile-close" type="button">CLOSE</button></div>
    <div id="current-profile-plot"></div>`;
  document.body.append(currentProfile);
  currentProfile.querySelector("#current-profile-close").addEventListener("click", () => {
    currentProfile.hidden = true;
  });
  const componentSelect = controlsPanel.querySelector("#pattern-component");
  const scaleSelect = controlsPanel.querySelector("#pattern-scale");
  const paletteSelect = controlsPanel.querySelector("#pattern-palette");
  const opacitySlider = controlsPanel.querySelector("#pattern-opacity");
  const colorBands = controlsPanel.querySelector("#color-bands");
  const segmentControls = controlsPanel.querySelector("#segment-controls");
  const segmentDisplay = controlsPanel.querySelector("#segment-display");
  const surfaceSmoothing = controlsPanel.querySelector("#surface-smoothing");
  controlsPanel.querySelector("#surface-smoothing-control").hidden = !hasSurfaceCurrents;
  const segmentPhaseRow = controlsPanel.querySelector("#segment-phase-row");
  const segmentPhaseSlider = controlsPanel.querySelector("#segment-phase");
  const segmentLegend = controlsPanel.querySelector("#segment-legend");
  const currentScaleControls = controlsPanel.querySelector("#current-scale-controls");
  const currentReferenceSelect = controlsPanel.querySelector("#current-reference");
  const currentFixedReference = controlsPanel.querySelector("#current-fixed-reference");
  const currentFloorRow = controlsPanel.querySelector("#current-floor-row");
  const currentFloorSlider = controlsPanel.querySelector("#current-floor");
  const inspectorEnabled = controlsPanel.querySelector("#inspector-enabled");
  const powerBudget = diagnostics?.power_budget;
  for (const option of segmentDisplay.querySelectorAll('option[value^="volume-current"]')) {
    option.hidden = !hasVolumeCurrents;
  }
  segmentControls.hidden = !segmentSamples.size && !hasSurfaceCurrents && !hasVolumeCurrents;
  const budgetElement = controlsPanel.querySelector("#power-budget");
  budgetElement.hidden = !powerBudget;
  if (powerBudget) {
    const watts = value => Number.isFinite(value) ? `${value.toPrecision(5)} W` : "unavailable";
    budgetElement.textContent = `POWER · input ${watts(powerBudget.input_power_w)} · ` +
      `radiated ${watts(powerBudget.radiated_power_w)} · structure loss ${watts(powerBudget.structure_loss_w)} · ` +
      `network loss ${watts(powerBudget.network_loss_w)} · efficiency ` +
      `${Number(powerBudget.efficiency_percent).toFixed(2)}%`;
  }
  let patternMaterial = null;
  let segmentPhaseDegrees = 0;
  let segmentPlaying = true;

  const currentMaximum = Math.max(Number.EPSILON, ...[...segmentSamples.values()]
    .map(sample => sample.current?.magnitude || 0));
  const chargeMaximum = Math.max(Number.EPSILON, ...[...segmentSamples.values()]
    .map(sample => sample.charge_density?.magnitude || 0));
  const surfaceCurrentMaximum = Math.max(Number.EPSILON, ...surfaceCurrentGroups.flatMap(samples =>
    samples.map(sample => complexVectorEnvelope(sample.current_density))));
  const volumeCurrentMaximum = Math.max(Number.EPSILON, ...volumeCurrentSamples
    .map(sample => complexVectorEnvelope(sample.current_density)));
  const wiresById = new Map((data.geometry.wires || []).map(wire => [Number(wire.id), wire]));
  const coaxesByName = new Map((data.geometry.coaxes || []).map(coax => [String(coax.name), coax]));
  const currentMaximumByWire = new Map();
  for (const sample of segmentSamples.values()) {
    const id = Number(sample.wire_id);
    currentMaximumByWire.set(id, Math.max(currentMaximumByWire.get(id) || 0,
      sample.current?.magnitude || 0));
  }
  const currentMaximumByCoax = new Map();
  for (const coax of data.geometry.coaxes || []) {
    currentMaximumByCoax.set(String(coax.name), Math.max(Number.EPSILON,
      ...(coax.shield_wire_ids || []).map(id => currentMaximumByWire.get(Number(id)) || 0)));
  }
  let inspectorHit = null;
  let inspectorPinned = false;

  function selectedWire() {
    return inspectorHit?.object?.userData?.wire || null;
  }

  function currentReferenceMaximum() {
    const mode = currentReferenceSelect.value;
    const wire = selectedWire();
    if (mode === "wire" && wire) return currentMaximumByWire.get(Number(wire.id)) || currentMaximum;
    if (mode === "coax" && wire?.coax && wire.coax !== "null") {
      return currentMaximumByCoax.get(String(wire.coax)) || currentMaximum;
    }
    if (mode === "fixed") {
      const fixed = Number(currentFixedReference.value);
      if (Number.isFinite(fixed) && fixed > 0) return fixed;
    }
    return currentMaximum;
  }

  function signedColor(value, maximum) {
    const amount = Math.min(1, Math.abs(value) / Math.max(maximum, Number.EPSILON));
    const middle = new THREE.Color(0xf7fbff);
    const edge = new THREE.Color(value < 0 ? 0x1743ff : 0xff315f);
    return middle.lerp(edge, Math.sqrt(amount));
  }

  function phaseColor(value) {
    const phase = ((value?.phase_degrees || 0) + 360) % 360;
    return new THREE.Color().setHSL(phase / 360, 0.9, 0.58);
  }

  function magnitudeColor(value, maximum, floor = -30) {
    const db = 20 * Math.log10(Math.max(value?.magnitude || 0, maximum * 1e-8) / maximum);
    const bounded = Math.max(floor, Math.min(0, db));
    return colorAt("viridis", 30 * bounded / Math.abs(floor));
  }

  function instantaneous(value) {
    const radians = segmentPhaseDegrees * Math.PI / 180;
    return (value?.real || 0) * Math.cos(radians) - (value?.imaginary || 0) * Math.sin(radians);
  }

  function inspectorRows(rows) {
    return `<div class="inspector-grid">${rows.map(([label, value]) =>
      `<span>${escapeHtml(label)}</span><span>${value}</span>`).join("")}</div>`;
  }

  function complexText(value, units) {
    if (!value || !Number.isFinite(value.magnitude)) return `unavailable ${units}`;
    return `${formatEngineering(value.magnitude, units)} ∠ ${Number(value.phase_degrees).toFixed(1)}°`;
  }

  function currentRows(sample) {
    if (!sample?.current) return [["current", "unavailable"]];
    const magnitude = Number(sample.current.magnitude);
    const reference = currentReferenceMaximum();
    const inputPower = Number(powerBudget?.input_power_w);
    const rows = [
      ["current", complexText(sample.current, "A")],
      ["global reference", `${dbRelative(magnitude, currentMaximum).toFixed(2)} dB`],
      ["display reference", `${dbRelative(magnitude, reference).toFixed(2)} dB`],
    ];
    if (inputPower > 0) rows.push(["normalized current",
      `${formatEngineering(magnitude / Math.sqrt(inputPower), "A/√W")}`]);
    if (sample.charge_density && Number.isFinite(sample.charge_density.magnitude)) {
      rows.push(["charge density", complexText(sample.charge_density, "C/m")]);
    }
    return rows;
  }

  function renderInspector(hit) {
    if (!inspectorEnabled.checked || !hit) { inspector.hidden = true; return; }
    inspectorHit = hit;
    const userData = hit.object.userData || {};
    let title = "CONDUCTOR";
    let rows = [];
    let note = "";
    let profileCoax = null;
    if (userData.segmentKey) {
      const wire = userData.wire || {};
      const sample = segmentSamples.get(userData.segmentKey);
      title = `${wire.name || `wire ${wire.id}`} · segment ${userData.segmentIndex}/${userData.segmentCount}`;
      rows = [
        ["role", escapeHtml(wire.role || "wire")],
        ["position", `(${(userData.segmentCenter || []).map(value => Number(value).toPrecision(5)).join(", ")}) m`],
        ...currentRows(sample),
        ["frequency", `${Number(diagnostics?.frequency_mhz).toPrecision(7)} MHz`],
      ];
      if (wire.coax && wire.coax !== "null") profileCoax = String(wire.coax);
      if (!sample) note = "No solver diagnostic sample is available for this segment.";
    } else if (userData.inspectorType === "load") {
      const load = userData.load;
      const sample = segmentSamples.get(`${load.tag}:1`);
      const impedance = loadImpedance(load, diagnostics?.frequency_mhz);
      const currentMagnitude = Number(sample?.current?.magnitude);
      const voltageMagnitude = currentMagnitude * impedanceMagnitude(impedance);
      const realPower = 0.5 * currentMagnitude ** 2 * impedance.real;
      const reactivePower = 0.5 * currentMagnitude ** 2 * impedance.imaginary;
      title = `${load.name} · ${load.topology} load`;
      rows = [
        ["position", `(${load.center.map(value => Number(value).toPrecision(5)).join(", ")}) m`],
        ["R / L / C", `${formatEngineering(load.resistance_ohms, "Ω")} · ` +
          `${formatEngineering(load.inductance_h, "H")} · ${formatEngineering(load.capacitance_f, "F")}`],
        ["impedance", `${formatEngineering(impedance.real, "Ω")} ${impedance.imaginary < 0 ? "−" : "+"} ` +
          `j${formatEngineering(Math.abs(impedance.imaginary), "Ω")}`],
        ...currentRows(sample),
        ["voltage drop", formatEngineering(voltageMagnitude, "V")],
        ["real / reactive power", `${formatEngineering(realPower, "W")} · ` +
          `${formatEngineering(reactivePower, "var")}`],
      ];
      const adjacent = [load.negative_wire_id, load.positive_wire_id]
        .map(id => wiresById.get(Number(id))).find(wire => wire?.coax && wire.coax !== "null");
      if (adjacent) profileCoax = String(adjacent.coax);
      note = "Load voltage and complex power are calculated from the NEC segment-current phasor.";
    } else if (userData.inspectorType === "port") {
      const port = userData.port;
      const sample = segmentSamples.get(`${port.wire_id}:1`);
      title = `${port.name} · ${userData.polarity} terminal`;
      rows = [
        ["position", `(${port[userData.polarity].map(value => Number(value).toPrecision(5)).join(", ")}) m`],
        ["port wire", `${port.wire_id}`],
        ["generated", port.generated ? "yes" : "no"],
        ...currentRows(sample),
      ];
    } else if (userData.inspectorType === "feed") {
      const feed = userData.feed;
      title = `${feed.name} · excitation`;
      rows = [["wire", `${userData.wire?.id ?? "unknown"}`],
        ["amplitude", `${Number(feed.amplitude).toPrecision(5)} V`],
        ["phase", `${Number(feed.phase_degrees).toFixed(1)}°`]];
    }
    inspector.innerHTML = `<div class="inspector-title"><span>${escapeHtml(title)}</span>` +
      `<span>${inspectorPinned ? "PINNED" : "HOVER"}</span></div>${inspectorRows(rows)}` +
      (note ? `<div class="inspector-note">${escapeHtml(note)}</div>` : "") +
      (profileCoax ? `<button type="button" data-coax-profile="${escapeHtml(profileCoax)}">` +
        `SHOW COAX CURRENT PROFILE</button>` : "");
    inspector.hidden = false;
    inspector.querySelector("[data-coax-profile]")?.addEventListener("click", event => {
      showCoaxProfile(event.currentTarget.dataset.coaxProfile);
    });
  }

  function showCoaxProfile(name) {
    const coax = coaxesByName.get(String(name));
    if (!coax) return;
    const distances = [], magnitudes = [], phases = [], wireIds = [], segmentNumbers = [];
    const edgeEnds = new Map();
    let distance = 0;
    for (const idValue of coax.shield_wire_ids || []) {
      const id = Number(idValue);
      const wire = wiresById.get(id);
      if (!wire) continue;
      const length = new THREE.Vector3(...wire.start).distanceTo(new THREE.Vector3(...wire.end));
      const count = Math.max(1, Number(wire.segment_count) || 1);
      for (let segment = 1; segment <= count; ++segment) {
        const sample = segmentSamples.get(`${id}:${segment}`);
        if (!sample?.current) continue;
        distances.push(distance + length * (segment - 0.5) / count);
        magnitudes.push(Number(sample.current.magnitude));
        phases.push(Number(sample.current.phase_degrees));
        wireIds.push(id); segmentNumbers.push(segment);
      }
      distance += length;
      edgeEnds.set(id, distance);
    }
    if (!magnitudes.length) return;
    const maximum = Math.max(...magnitudes, Number.EPSILON);
    const relative = magnitudes.map(value => dbRelative(value, maximum));
    const loads = (data.geometry.lumped_loads || []).filter(load =>
      edgeEnds.has(Number(load.negative_wire_id)) || edgeEnds.has(Number(load.positive_wire_id)));
    const loadDistance = load => edgeEnds.get(Number(load.negative_wire_id)) ??
      edgeEnds.get(Number(load.positive_wire_id));
    currentProfile.querySelector("#current-profile-header span").textContent =
      `${name} · shield current from antenna toward input`;
    currentProfile.hidden = false;
    Plotly.react(currentProfile.querySelector("#current-profile-plot"), [{
      type: "scatter", mode: "lines+markers", name: "|I|", x: distances, y: relative,
      line: { color: "#39efff", width: 3 }, marker: { size: 5, color: "#ff3bd4" },
      customdata: magnitudes.map((value, index) =>
        [value, phases[index], wireIds[index], segmentNumbers[index]]),
      hovertemplate: `distance %{x:.5g} m<br>|I| %{customdata[0]:.5g} A<br>` +
        `relative %{y:.2f} dB<br>phase %{customdata[1]:.1f}°<br>` +
        `wire %{customdata[2]} segment %{customdata[3]}<extra></extra>`,
    }, {
      type: "scatter", mode: "lines", name: "phase", x: distances, y: phases, yaxis: "y2",
      line: { color: "#fff45c", width: 1.5, dash: "dot" }, hoverinfo: "skip",
    }], {
      paper_bgcolor: "rgba(3,6,17,0)", plot_bgcolor: "rgba(5,14,29,.78)",
      font: { family: '"DejaVu Sans Mono", monospace', color: "#d8fbff" },
      margin: { l: 65, r: 65, t: 28, b: 54 }, hovermode: "closest",
      xaxis: { title: "distance from antenna feed (m)", gridcolor: "#245069" },
      yaxis: { title: "shield current (dB relative)", gridcolor: "#245069" },
      yaxis2: { title: "phase (degrees)", overlaying: "y", side: "right", range: [-180, 180],
        color: "#fff45c" },
      shapes: loads.map(load => ({ type: "line", x0: loadDistance(load), x1: loadDistance(load),
        yref: "paper", y0: 0, y1: 1, line: { color: "#ff8c1a", width: 2, dash: "dash" } })),
      annotations: loads.map(load => ({ x: loadDistance(load), yref: "paper", y: 1,
        text: load.name, showarrow: false, yanchor: "bottom", font: { color: "#ffb347", size: 10 } })),
      legend: { orientation: "h", x: 0, y: 1.12 },
    }, { responsive: true, displaylogo: false,
      toImageButtonOptions: { format: "svg", filename: `${name}-shield-current` } });
  }

  function updateSegmentDisplay() {
    const mode = segmentDisplay.value;
    const instantaneousMode = mode.endsWith("instantaneous");
    const wireCurrentMode = mode.startsWith("current-");
    const currentReference = currentReferenceMaximum();
    const currentFloor = Number(currentFloorSlider.value);
    segmentPhaseRow.hidden = !instantaneousMode;
    segmentLegend.hidden = mode === "geometry";
    currentScaleControls.hidden = !wireCurrentMode;
    currentFloorRow.hidden = !wireCurrentMode;
    currentFixedReference.hidden = currentReferenceSelect.value !== "fixed";
    const labels = segmentLegend.querySelectorAll("span");
    if (mode === "volume-current-magnitude") {
      labels[0].textContent = "−30 dB"; labels[1].textContent = "volume polarization J";
      labels[2].textContent = `${volumeCurrentMaximum.toPrecision(4)} A/m²`;
      segmentLegend.querySelector(".segment-legend-bar").style.background =
        "linear-gradient(90deg,#440154,#21918c,#fde725)";
    } else if (mode === "volume-current-phase") {
      labels[0].textContent = "−180°"; labels[1].textContent = "volume J phase";
      labels[2].textContent = "+180°";
      segmentLegend.querySelector(".segment-legend-bar").style.background =
        "linear-gradient(90deg,#00f,#0ff,#0f0,#ff0,#f00,#f0f,#00f)";
    } else if (mode === "current-magnitude") {
      labels[0].textContent = `${currentFloor} dB`; labels[1].textContent = "current";
      labels[2].textContent = `${currentReference.toPrecision(4)} A` +
        (hasSurfaceCurrents ? ` · ${surfaceCurrentMaximum.toPrecision(4)} A/m surface` : "");
      segmentLegend.querySelector(".segment-legend-bar").style.background =
        "linear-gradient(90deg,#440154,#21918c,#fde725)";
    } else if (mode === "charge-magnitude") {
      labels[0].textContent = "−30 dB"; labels[1].textContent = "charge density";
      labels[2].textContent = `${chargeMaximum.toPrecision(4)} C/m`;
      segmentLegend.querySelector(".segment-legend-bar").style.background =
        "linear-gradient(90deg,#440154,#21918c,#fde725)";
    } else if (mode === "current-phase") {
      labels[0].textContent = "−180°"; labels[1].textContent = "phase"; labels[2].textContent = "+180°";
      segmentLegend.querySelector(".segment-legend-bar").style.background =
        "linear-gradient(90deg,#00f,#0ff,#0f0,#ff0,#f00,#f0f,#00f)";
    } else if (instantaneousMode) {
      const volumeMode = mode.startsWith("volume-current");
      const maximum = volumeMode ? volumeCurrentMaximum
        : mode.startsWith("current") ? currentReference : chargeMaximum;
      const units = volumeMode ? "A/m²" : mode.startsWith("current") ? "A" : "C/m";
      labels[0].textContent = `−${maximum.toPrecision(3)} ${units}`;
      labels[1].textContent = "instantaneous";
      labels[2].textContent = `+${maximum.toPrecision(3)} ${units}` +
        (mode.startsWith("current") && hasSurfaceCurrents
          ? ` · surface 0…${surfaceCurrentMaximum.toPrecision(3)} A/m` : "");
      segmentLegend.querySelector(".segment-legend-bar").style.background =
        "linear-gradient(90deg,#1743ff,#f7fbff,#ff315f)";
    }
    for (const mesh of geometrySegments) {
      const sample = segmentSamples.get(mesh.userData.segmentKey);
      let color = new THREE.Color(mesh.userData.baseColor);
      if (sample && mode === "current-magnitude")
        color = magnitudeColor(sample.current, currentReference, currentFloor);
      else if (sample && mode === "current-phase") color = phaseColor(sample.current);
      else if (sample && mode === "current-instantaneous")
        color = signedColor(instantaneous(sample.current), currentReference);
      else if (sample && mode === "charge-magnitude")
        color = magnitudeColor(sample.charge_density, chargeMaximum);
      else if (sample && mode === "charge-instantaneous")
        color = signedColor(instantaneous(sample.charge_density), chargeMaximum);
      mesh.material.color.copy(color);
    }
    if (!inspector.hidden && inspectorHit) renderInspector(inspectorHit);
    for (const { mesh, sample } of volumeCurrentMeshes) {
      mesh.visible = mode.startsWith("volume-current");
      let color = new THREE.Color(0x31efff);
      if (mode === "volume-current-magnitude") {
        color = magnitudeColor({ magnitude: complexVectorEnvelope(sample.current_density) },
          volumeCurrentMaximum);
      } else if (mode === "volume-current-phase") {
        color = phaseColor({ phase_degrees: dominantVectorPhase(sample.current_density) });
      } else if (mode.startsWith("volume-current") && mode.endsWith("instantaneous")) {
        const component = mode.includes("-x-") ? 0 : mode.includes("-y-") ? 1 : 2;
        color = signedColor(instantaneous(sample.current_density[component]),
          volumeCurrentMaximum);
      }
      mesh.material.color.copy(color);
    }
    const colorAttribute = geometryDisplay.surfaceMesh?.geometry.getAttribute("color");
    if (colorAttribute) {
      const base = new THREE.Color(geometryDisplay.surfaceMesh.userData.baseColor);
      const patchColors = surfaceCurrentGroups.map(samples => {
        let color = base.clone();
        if (samples.length && mode === "current-magnitude") {
          const value = samples.reduce((sum, sample) =>
            sum + complexVectorEnvelope(sample.current_density), 0) / samples.length;
          color = magnitudeColor({ magnitude: value }, surfaceCurrentMaximum);
        } else if (samples.length && mode === "current-phase") {
          const strongest = samples.reduce((best, sample) =>
            complexVectorEnvelope(sample.current_density) > complexVectorEnvelope(best.current_density)
              ? sample : best, samples[0]);
          color = phaseColor({ phase_degrees: dominantVectorPhase(strongest.current_density) });
        } else if (samples.length && mode === "current-instantaneous") {
          const value = samples.reduce((sum, sample) => sum +
            complexVectorInstantaneousMagnitude(sample.current_density, segmentPhaseDegrees), 0) /
            samples.length;
          color = magnitudeColor({ magnitude: value }, surfaceCurrentMaximum);
        }
        return color;
      });
      for (let patchIndex = 0; patchIndex < surfaceCurrentGroups.length; ++patchIndex) {
        const [start, count] = geometryDisplay.surfaceVertexRanges[patchIndex] || [0, 0];
        for (let vertex = start; vertex < start + count; ++vertex) {
          let color = patchColors[patchIndex];
          if (surfaceSmoothing.checked && mode.startsWith("current")) {
            const neighbors = geometryDisplay.surfaceCornerPatches.get(
              geometryDisplay.surfaceVertexKeys[vertex]) || [patchIndex];
            color = neighbors.reduce((sum, neighbor) => sum.add(patchColors[neighbor]),
              new THREE.Color(0, 0, 0)).multiplyScalar(1 / neighbors.length);
          }
          colorAttribute.setXYZ(vertex, color.r, color.g, color.b);
        }
      }
      colorAttribute.needsUpdate = true;
    }
  }

  function updateLegend() {
    const selected = palettes[paletteSelect.value] || palettes.mmana;
    const gradient = colorBands.checked
      ? Array.from({ length: 10 }, (_, index) => {
        const lower = -30 + index * 3;
        const upper = lower + 3;
        const color = threeColorCss(colorAt(paletteSelect.value, upper));
        return `${color} ${((lower + 30) / 30) * 100}%,${color} ${((upper + 30) / 30) * 100}%`;
      }).join(",")
      : selected.map(([db, rgb]) =>
        `${cssColor(rgb)} ${((db + 30) / 30) * 100}%`).join(",");
    controlsPanel.querySelector(".pattern-legend-bar").style.background =
      `linear-gradient(90deg,${gradient})`;
    const ticks = [-30, -20, -10, 0];
    controlsPanel.querySelector('[data-scale="relative"]').innerHTML = ticks.map(db =>
      `<span>${db === 0 ? "0 dB" : `${db}`}</span>`).join("");
    controlsPanel.querySelector('[data-scale="absolute"]').innerHTML = ticks.map(db =>
      `<span>${(referencePeak + db).toFixed(1)}</span>`).join("");
  }

  function rebuildPattern() {
    for (const child of patternGroup.children) {
      child.geometry?.dispose();
      if (Array.isArray(child.material)) child.material.forEach(material => material.dispose());
      else child.material?.dispose();
    }
    patternGroup.clear();
    const component = componentSelect.value;
    const gains = data.pattern.samples.map(sample => gainOf(sample, component)).filter(Number.isFinite);
    const componentPeak = Math.max(...gains);
    const positions = [], colors = [], relativeGains = [], indices = [];
    for (let ti = 0; ti < data.pattern.theta_values.length; ++ti) {
      const theta = data.pattern.theta_values[ti] * Math.PI / 180;
      for (let pi = 0; pi < data.pattern.phi_values.length; ++pi) {
        const phi = data.pattern.phi_values[pi] * Math.PI / 180;
        const gain = gainOf(sampleAt(data.pattern, table, ti, pi), component) ?? -100 + referencePeak;
        const relative = Math.min(0, gain - referencePeak);
        const radiusFactor = scaleSelect.value === "arrl"
          ? 0.89 ** ((-Math.max(-100, relative)) / 2)
          : scaleSelect.value === "linear"
            ? 10 ** (relative / 10)
            : Math.max(0, 1 + relative / 40);
        const radius = patternRadius * radiusFactor;
        positions.push(radius * Math.sin(theta) * Math.cos(phi),
          radius * Math.sin(theta) * Math.sin(phi), radius * Math.cos(theta));
        relativeGains.push(relative);
        const color = colorAt(paletteSelect.value, relative); colors.push(color.r, color.g, color.b);
      }
    }
    const pc = data.pattern.phi_values.length;
    for (let ti = 0; ti < data.pattern.theta_values.length - 1; ++ti) {
      for (let pi = 0; pi < pc; ++pi) {
        const next = (pi + 1) % pc;
        const a = ti * pc + pi, b = ti * pc + next;
        const c = (ti + 1) * pc + next, d = (ti + 1) * pc + pi;
        indices.push(a, b, c, a, c, d);
      }
    }
    const geometry = new THREE.BufferGeometry();
    if (colorBands.checked) {
      const bandPositions = [], bandColors = [];
      for (let index = 0; index < indices.length; index += 3) {
        const vertices = [indices[index], indices[index + 1], indices[index + 2]];
        const average = vertices.reduce((sum, vertex) => sum + relativeGains[vertex], 0) / 3;
        const color = colorAt(paletteSelect.value, quantizedGain(average));
        for (const vertex of vertices) {
          bandPositions.push(...positions.slice(vertex * 3, vertex * 3 + 3));
          bandColors.push(color.r, color.g, color.b);
        }
      }
      geometry.setAttribute("position", new THREE.Float32BufferAttribute(bandPositions, 3));
      geometry.setAttribute("color", new THREE.Float32BufferAttribute(bandColors, 3));
    } else {
      geometry.setAttribute("position", new THREE.Float32BufferAttribute(positions, 3));
      geometry.setAttribute("color", new THREE.Float32BufferAttribute(colors, 3));
      geometry.setIndex(indices);
    }
    const opacity = Number(opacitySlider.value);
    patternMaterial = new THREE.MeshBasicMaterial({
      vertexColors: true, transparent: opacity < 1, opacity,
      side: THREE.DoubleSide, depthWrite: opacity >= 0.999,
    });
    patternGroup.add(new THREE.Mesh(geometry, patternMaterial));
    controlsPanel.querySelector("#pattern-detail").textContent =
      `${data.pattern.frequency_mhz.toPrecision(7)} MHz · ${component} peak ${componentPeak.toFixed(2)} dBi · ` +
      `total reference ${referencePeak.toFixed(2)} dBi`;
    updateLegend();
  }
  [componentSelect, scaleSelect, paletteSelect, colorBands]
    .forEach(element => element.addEventListener("change", rebuildPattern));
  controlsPanel.querySelector("#model-visible").addEventListener("change", event => {
    geometryGroup.visible = event.target.checked;
  });
  controlsPanel.querySelector("#pattern-visible").addEventListener("change", event => {
    patternGroup.visible = event.target.checked;
  });
  controlsPanel.querySelector("#axes-visible").addEventListener("change", event => {
    axisGroup.visible = event.target.checked;
  });
  controlsPanel.querySelector("#reset-view").addEventListener("click", () => {
    fitCamera(camera, controls, scene);
  });
  opacitySlider.addEventListener("input", () => {
    const opacity = Number(opacitySlider.value);
    controlsPanel.querySelector("#pattern-opacity-value").textContent = `${Math.round(opacity * 100)}%`;
    if (patternMaterial) {
      patternMaterial.opacity = opacity;
      patternMaterial.transparent = opacity < 1;
      patternMaterial.depthWrite = opacity >= 0.999;
      patternMaterial.needsUpdate = true;
    }
  });
  segmentDisplay.addEventListener("change", updateSegmentDisplay);
  surfaceSmoothing.addEventListener("change", updateSegmentDisplay);
  currentReferenceSelect.addEventListener("change", () => {
    currentFixedReference.hidden = currentReferenceSelect.value !== "fixed";
    updateSegmentDisplay();
  });
  currentFixedReference.addEventListener("input", updateSegmentDisplay);
  currentFloorSlider.addEventListener("input", () => {
    controlsPanel.querySelector("#current-floor-value").textContent =
      `${Number(currentFloorSlider.value)} dB`;
    updateSegmentDisplay();
  });
  segmentPhaseSlider.addEventListener("input", () => {
    segmentPhaseDegrees = Number(segmentPhaseSlider.value);
    segmentPlaying = false;
    controlsPanel.querySelector("#segment-play").textContent = "PLAY";
    controlsPanel.querySelector("#segment-phase-value").textContent = `${Math.round(segmentPhaseDegrees)}°`;
    updateSegmentDisplay();
  });
  controlsPanel.querySelector("#segment-play").addEventListener("click", event => {
    segmentPlaying = !segmentPlaying;
    event.currentTarget.textContent = segmentPlaying ? "PAUSE" : "PLAY";
  });
  const raycaster = new THREE.Raycaster();
  const pointer = new THREE.Vector2();
  let pointerDown = null;
  function inspectorIntersection(event) {
    if (!inspectorEnabled.checked || activeView !== "viewer3d") return null;
    const bounds = canvas.getBoundingClientRect();
    pointer.x = 2 * (event.clientX - bounds.left) / bounds.width - 1;
    pointer.y = 1 - 2 * (event.clientY - bounds.top) / bounds.height;
    raycaster.setFromCamera(pointer, camera);
    return raycaster.intersectObjects([...geometryMarkers, ...geometrySegments], false)[0] || null;
  }
  function selectInspectorHit(hit, pinned) {
    inspectorHit = hit;
    inspectorPinned = Boolean(hit) && pinned;
    if (!hit) { inspector.hidden = true; return; }
    if (["wire", "coax"].includes(currentReferenceSelect.value) &&
        segmentDisplay.value.startsWith("current-")) updateSegmentDisplay();
    else renderInspector(hit);
  }
  canvas.addEventListener("pointerdown", event => {
    pointerDown = [event.clientX, event.clientY];
  });
  canvas.addEventListener("pointermove", event => {
    if (inspectorPinned || !inspectorEnabled.checked) return;
    const hit = inspectorIntersection(event);
    canvas.style.cursor = hit ? "pointer" : "default";
    selectInspectorHit(hit, false);
  });
  canvas.addEventListener("pointerleave", () => {
    canvas.style.cursor = "default";
    if (!inspectorPinned) selectInspectorHit(null, false);
  });
  canvas.addEventListener("pointerup", event => {
    const moved = pointerDown ? Math.hypot(event.clientX - pointerDown[0],
      event.clientY - pointerDown[1]) : Infinity;
    pointerDown = null;
    if (moved > 4 || !inspectorEnabled.checked) return;
    const hit = inspectorIntersection(event);
    selectInspectorHit(hit, Boolean(hit));
  });
  inspectorEnabled.addEventListener("change", () => {
    for (const marker of geometryMarkers) marker.visible = inspectorEnabled.checked;
    if (!inspectorEnabled.checked) {
      inspectorHit = null; inspectorPinned = false;
      inspector.hidden = true; currentProfile.hidden = true;
      canvas.style.cursor = "default";
    }
    updateSegmentDisplay();
  });
  updateSegmentDisplay();
  rebuildPattern();

  const polarWorkspace = document.createElement("section");
  polarWorkspace.id = "pattern-2d";
  polarWorkspace.hidden = true;
  const minimumElevation = 90 - data.pattern.theta_values.at(-1);
  const maximumElevation = 90 - data.pattern.theta_values[0];
  polarWorkspace.innerHTML = `<div class="pattern-toolbar panel"><label for="cut-plane">CUT</label>
    <select id="cut-plane"><option value="azimuth">azimuth</option><option value="elevation">elevation</option></select>
    <label id="cut-angle-label" for="cut-angle">ELEVATION</label>
    <input id="cut-angle" type="range" min="${minimumElevation}" max="${maximumElevation}" step="1" value="0">
    <span id="cut-angle-value">0°</span><label for="cut-component">COMPONENT</label>
    <select id="cut-component"><option value="total">total</option><option value="vertical">vertical (Eθ)</option>
    <option value="horizontal">horizontal (Eφ)</option></select><label for="cut-reference">DISPLAY</label>
    <select id="cut-reference"><option value="relative">relative</option><option value="absolute">absolute dBi</option></select>
    <label for="cut-depth">DEPTH</label><select id="cut-depth"><option value="30" selected>30 dB</option>
    <option value="40">40 dB</option><option value="60">60 dB</option><option value="80">80 dB</option></select>
    </div><div id="pattern-polar"></div>`;
  document.body.append(polarWorkspace);
  const planeSelect = polarWorkspace.querySelector("#cut-plane");
  const angleSlider = polarWorkspace.querySelector("#cut-angle");
  if (minimumElevation > 0) angleSlider.value = minimumElevation;

  function configureCutAngle() {
    const elevationCut = planeSelect.value === "elevation";
    const previous = Number(angleSlider.value);
    angleSlider.min = elevationCut ? 0 : minimumElevation;
    angleSlider.max = elevationCut ? 359 : maximumElevation;
    angleSlider.value = elevationCut ? 0 : Math.max(minimumElevation,
      Math.min(maximumElevation, previous));
    polarWorkspace.querySelector("#cut-angle-label").textContent =
      elevationCut ? "BEARING" : "ELEVATION";
  }

  function drawPolar() {
    const elevationCut = planeSelect.value === "elevation";
    const cutAngle = Number(angleSlider.value);
    const component = polarWorkspace.querySelector("#cut-component").value;
    const absolute = polarWorkspace.querySelector("#cut-reference").value === "absolute";
    const depth = Number(polarWorkspace.querySelector("#cut-depth").value);
    const grounded = minimumElevation >= 0;
    const angleStop = elevationCut && grounded ? 180 : 360;
    const angles = Array.from({ length: angleStop + 1 }, (_, index) => index);
    const directions = angles.map(angle => elevationCut
      ? elevationPlaneDirection(angle, cutAngle)
      : { elevation: cutAngle, azimuth: angle });
    const gains = directions.map(direction => interpolatedGain(data.pattern, table,
      direction.elevation, direction.azimuth, component));
    const polarization = directions.map(direction => interpolatedPolarization(data.pattern, table,
      direction.elevation, direction.azimuth));
    const globalRange = componentGainRange(data.pattern, component);
    const shown = absolute ? gains : gains.map(gain => gain - globalRange.referencePeak);
    const radialRange = absolute
      ? [globalRange.referencePeak - depth, globalRange.referencePeak]
      : [-depth, 0];
    const displayScale = polarDisplayScale(shown, radialRange);
    polarWorkspace.querySelector("#cut-angle-value").textContent = `${cutAngle}°`;
    const cutName = elevationCut ? "Elevation" : "Azimuth";
    const fixedName = elevationCut ? "bearing" : "elevation";
    return Plotly.react(polarWorkspace.querySelector("#pattern-polar"), [{
      type: "scatterpolar", mode: "lines", theta: angles, r: displayScale.radius,
      line: { color: "#39efff", width: 3 }, name: component,
      customdata: gains.map((gain, index) => {
        const state = polarization[index];
        return [gain, shown[index], state.eThetaMagnitude, state.eThetaPhaseDegrees,
          state.ePhiMagnitude, state.ePhiPhaseDegrees, state.phaseDifferenceDegrees,
          state.axialRatio, state.tiltDegrees, state.sense || "unclassified",
          directions[index].azimuth, directions[index].elevation];
      }),
      hovertemplate: `${elevationCut ? "plane angle" : "azimuth"} %{theta:.1f}°` +
        (elevationCut ? `<br>direction az %{customdata[10]:.1f}° · el %{customdata[11]:.1f}°` : "") +
        `<br>${absolute ? "gain" : "relative"} %{customdata[1]:.3f} dB` +
        `<br>absolute %{customdata[0]:.3f} dBi` +
        `<br>|Eθ| %{customdata[2]:.4g} ∠ %{customdata[3]:.1f}°` +
        `<br>|Eφ| %{customdata[4]:.4g} ∠ %{customdata[5]:.1f}°` +
        `<br>Δphase %{customdata[6]:.1f}° · axial %{customdata[7]:.4g}` +
        `<br>tilt %{customdata[8]:.1f}° · %{customdata[9]}` +
        `<extra>${cutAngle}° ${fixedName}</extra>`,
    }], {
      title: { text: `${cutName} pattern · ${cutAngle}° ${fixedName} · ${component}`,
        font: { color: "#7df9ff", size: 19 }, x: 0.02 },
      paper_bgcolor: "rgba(3,6,17,0)", plot_bgcolor: "rgba(5,14,29,.78)",
      font: { family: '"DejaVu Sans Mono", monospace', color: "#d8fbff" },
      margin: { l: 50, r: 50, t: 60, b: 40 }, showlegend: false,
      polar: { bgcolor: "rgba(5,14,29,.78)", angularaxis: { direction: "counterclockwise",
        rotation: 0, gridcolor: "#245069", color: "#9ceeff" },
        radialaxis: { gridcolor: "#245069", color: "#9ceeff",
          range: displayScale.range, tickvals: displayScale.tickvals,
          ticktext: displayScale.ticktext } },
    }, { responsive: true, displaylogo: false, scrollZoom: true,
      toImageButtonOptions: { format: "svg", filename: "antenna-pattern-cut" } });
  }
  planeSelect.addEventListener("change", () => { configureCutAngle(); drawPolar(); });
  angleSlider.addEventListener("input", drawPolar);
  polarWorkspace.querySelector("#cut-component").addEventListener("change", drawPolar);
  polarWorkspace.querySelector("#cut-reference").addEventListener("change", drawPolar);
  polarWorkspace.querySelector("#cut-depth").addEventListener("change", drawPolar);

  const nearFieldSections = Array.isArray(data.near_fields) ? data.near_fields : [];
  const nearFieldMasks = nearFieldSections.map(section =>
    nearFieldExclusionMask(section, data.geometry || {}));
  const fieldWorkspace = document.createElement("section");
  fieldWorkspace.id = "near-field-workspace";
  fieldWorkspace.hidden = true;
  fieldWorkspace.innerHTML = `<div class="field-toolbar panel">
    <label for="near-field-plane">PLANE</label><select id="near-field-plane"></select>
    <label for="near-field-quantity">FIELD</label><select id="near-field-quantity">
      <option value="electric">E</option><option value="magnetic">H</option>
      <option value="power">POWER</option></select>
    <label for="near-field-mode">VIEW</label><select id="near-field-mode"></select>
    <label for="near-field-scale">SCALE</label><select id="near-field-scale">
      <option value="log">log</option><option value="linear">linear</option></select>
    <button id="near-field-play" type="button">PAUSE</button>
    <label for="near-field-phase">PHASE <span id="near-field-phase-value">0°</span></label>
    <input id="near-field-phase" type="range" min="0" max="359" step="1" value="0">
    <label for="near-field-floor">FLOOR <span id="near-field-floor-value">−40 dB</span></label>
    <input id="near-field-floor" type="range" min="-80" max="-10" step="1" value="-40">
    </div><div id="near-field-plot"></div>`;
  document.body.append(fieldWorkspace);
  const fieldPlaneSelect = fieldWorkspace.querySelector("#near-field-plane");
  for (const [index, section] of nearFieldSections.entries()) {
    const option = document.createElement("option");
    option.value = String(index);
    option.textContent = `${String(section.normal_axis).toUpperCase()}-normal · ` +
      `${section.normal_axis}=${Number(section.position).toPrecision(5)} m`;
    fieldPlaneSelect.append(option);
  }
  const fieldQuantitySelect = fieldWorkspace.querySelector("#near-field-quantity");
  const fieldModeSelect = fieldWorkspace.querySelector("#near-field-mode");
  const fieldScaleSelect = fieldWorkspace.querySelector("#near-field-scale");
  const fieldPhaseSlider = fieldWorkspace.querySelector("#near-field-phase");
  const fieldFloorSlider = fieldWorkspace.querySelector("#near-field-floor");
  let fieldPhaseDegrees = 0;
  let fieldPlaying = true;
  const electromagneticFieldModes = [
    ["envelope", "total envelope"],
    ["instantaneous", "instantaneous magnitude"],
    ["x", "X component"], ["y", "Y component"], ["z", "Z component"],
  ];
  const powerFieldModes = [
    ["power-average-magnitude", "average power intensity"],
    ["power-average-vectors", "average power vectors"],
    ["power-instantaneous-magnitude", "instantaneous power intensity"],
    ["power-instantaneous-vectors", "instantaneous power vectors"],
  ];
  let previousFieldQuantity = "electric";
  let electromagneticFieldMode = "envelope";
  let powerFieldMode = "power-average-magnitude";
  const fieldReferenceCache = new Map();

  function setFieldModeOptions() {
    const power = fieldQuantitySelect.value === "power";
    if (fieldModeSelect.value) {
      if (previousFieldQuantity === "power") powerFieldMode = fieldModeSelect.value;
      else electromagneticFieldMode = fieldModeSelect.value;
    }
    const modes = power ? powerFieldModes : electromagneticFieldModes;
    fieldModeSelect.replaceChildren(...modes.map(([value, label]) => {
      const option = document.createElement("option");
      option.value = value; option.textContent = label;
      return option;
    }));
    fieldModeSelect.value = power ? powerFieldMode : electromagneticFieldMode;
    previousFieldQuantity = fieldQuantitySelect.value;
  }

  function instantaneousFieldMode(quantity = fieldQuantitySelect.value,
                                  mode = fieldModeSelect.value) {
    return quantity === "power"
      ? mode.startsWith("power-instantaneous-") : mode === "instantaneous";
  }

  function vectorFieldMode(quantity = fieldQuantitySelect.value,
                           mode = fieldModeSelect.value) {
    return quantity === "power" && mode.endsWith("-vectors");
  }

  setFieldModeOptions();

  function fieldAvailability() {
    const section = nearFieldSections[Number(fieldPlaneSelect.value) || 0];
    const fields = new Set(section?.fields || []);
    for (const option of fieldQuantitySelect.options) {
      option.disabled = option.value === "power"
        ? !(fields.has("electric") && fields.has("magnetic"))
        : !fields.has(option.value);
    }
    if (fieldQuantitySelect.selectedOptions[0]?.disabled) {
      fieldQuantitySelect.value = fields.has("electric") ? "electric" : "magnetic";
    }
    const phaseRelevant = instantaneousFieldMode();
    fieldPhaseSlider.disabled = !phaseRelevant;
    fieldWorkspace.querySelector("#near-field-play").disabled = !phaseRelevant;
  }

  function fieldValue(sample, quantity, mode, phaseDegrees) {
    if (quantity === "power") {
      const vector = instantaneousFieldMode(quantity, mode)
        ? instantaneousPoyntingSample(sample, phaseDegrees)
        : averagePoyntingSample(sample);
      return Math.hypot(...(vector || [0, 0, 0]));
    }
    const vector = fieldVector(sample, quantity);
    if (!vector) return 0;
    if (mode === "instantaneous") return Math.hypot(...instantaneousVector(vector, phaseDegrees));
    const component = { x: 0, y: 1, z: 2 }[mode];
    return component === undefined ? vectorEnvelope(vector) : complexMagnitude(vector[component]);
  }

  function fieldReferenceMaximum(quantity, mode) {
    const cacheKey = `${quantity}:${mode}`;
    if (fieldReferenceCache.has(cacheKey)) return fieldReferenceCache.get(cacheKey);
    const phases = quantity === "power" && instantaneousFieldMode(quantity, mode)
      ? Array.from({ length: 18 }, (_, index) => index * 10) : [0];
    const referenceMode = quantity !== "power" && mode === "instantaneous" ? "envelope" : mode;
    let maximum = Number.EPSILON;
    for (const [sectionIndex, section] of nearFieldSections.entries()) {
      for (const [sampleIndex, sample] of section.samples.entries()) {
        if (nearFieldMasks[sectionIndex]?.[sampleIndex]) continue;
        for (const phase of phases)
          maximum = Math.max(maximum, fieldValue(sample, quantity, referenceMode, phase));
      }
    }
    fieldReferenceCache.set(cacheKey, maximum);
    return maximum;
  }

  function fieldHover(sample, quantity, mode, phaseDegrees, value, relativeDb) {
    const units = quantity === "electric" ? "V/m" : quantity === "magnetic" ? "A/m" : "W/m²";
    const vector = quantity === "power"
      ? (instantaneousFieldMode(quantity, mode)
        ? instantaneousPoyntingSample(sample, phaseDegrees) : averagePoyntingSample(sample))
      : fieldVector(sample, quantity);
    const detail = quantity === "power"
      ? `${instantaneousFieldMode(quantity, mode) ? "S(t)" : "⟨S⟩"}=(` +
        `${(vector || [0, 0, 0]).map(component => component.toPrecision(4)).join(", ")}) ${units}`
      : ["X", "Y", "Z"].map((axis, index) => {
        const component = vector?.[index] || [0, 0];
        const magnitude = complexMagnitude(component);
        const phase = Math.atan2(component[1], component[0]) * 180 / Math.PI;
        return `${axis} ${magnitude.toPrecision(4)} ∠ ${phase.toFixed(1)}°`;
      }).join("<br>");
    return `${value.toPrecision(5)} ${units}<br>${relativeDb.toFixed(2)} dB relative<br>${detail}`;
  }

  function powerVector(sample, mode, phaseDegrees) {
    return instantaneousFieldMode("power", mode)
      ? instantaneousPoyntingSample(sample, phaseDegrees)
      : averagePoyntingSample(sample);
  }

  function powerVectorTrace(section, exclusionMask, mode, phaseDegrees, maximum, floor) {
    const width = section.u_values.length, height = section.v_values.length;
    const uComponent = { x: 0, y: 1, z: 2 }[section.u_axis];
    const vComponent = { x: 0, y: 1, z: 2 }[section.v_axis];
    const stride = Math.max(1, Math.ceil(Math.max(width, height) / 18));
    const uSpan = Math.abs(section.u_values.at(-1) - section.u_values[0]);
    const vSpan = Math.abs(section.v_values.at(-1) - section.v_values[0]);
    const arrowLength = 0.72 * Math.min(
      uSpan / Math.max(1, Math.ceil(width / stride)),
      vSpan / Math.max(1, Math.ceil(height / stride)));
    const x = [], y = [];
    for (let v = Math.floor(stride / 2); v < height; v += stride) {
      for (let u = Math.floor(stride / 2); u < width; u += stride) {
        const index = u + v * width;
        if (exclusionMask[index]) continue;
        const vector = powerVector(section.samples[index], mode, phaseDegrees) || [0, 0, 0];
        const projectedMagnitude = Math.hypot(vector[uComponent], vector[vComponent]);
        const relativeMagnitude = projectedMagnitude / Math.max(maximum, Number.EPSILON);
        if (!(relativeMagnitude >= 10 ** (floor / 10))) continue;
        // Direction is the primary information in this overlay; the heat map
        // already carries magnitude.  Keep even weak visible vectors at about
        // half of their sampling cell instead of shrinking them to ticks.
        const length = arrowLength * (0.7 + 0.3 * Math.sqrt(Math.min(1, relativeMagnitude)));
        const du = length * vector[uComponent] / projectedMagnitude;
        const dv = length * vector[vComponent] / projectedMagnitude;
        const centerU = Number(section.u_values[u]), centerV = Number(section.v_values[v]);
        const startU = centerU - du * 0.5, startV = centerV - dv * 0.5;
        const endU = centerU + du * 0.5, endV = centerV + dv * 0.5;
        const wing = 0.27;
        const wingU = -du * wing, wingV = -dv * wing;
        const sideU = -wingV * 0.58, sideV = wingU * 0.58;
        x.push(startU, endU, null,
          endU, endU + wingU + sideU, null,
          endU, endU + wingU - sideU, null);
        y.push(startV, endV, null,
          endV, endV + wingV + sideV, null,
          endV, endV + wingV - sideV, null);
      }
    }
    return {
      type: "scatter", mode: "lines", x, y, hoverinfo: "skip", showlegend: false,
      line: { color: instantaneousFieldMode("power", mode) ? "#ffca48" : "#7dff9a", width: 2 },
    };
  }

  function drawNearField() {
    if (!nearFieldSections.length) return Promise.resolve();
    fieldAvailability();
    const section = nearFieldSections[Number(fieldPlaneSelect.value) || 0];
    const quantity = fieldQuantitySelect.value;
    const mode = fieldModeSelect.value;
    const logarithmic = fieldScaleSelect.value === "log";
    const floor = Number(fieldFloorSlider.value);
    const maximum = fieldReferenceMaximum(quantity, mode);
    const dbFactor = quantity === "power" ? 10 : 20;
    const width = section.u_values.length;
    const exclusionMask = nearFieldMasks[Number(fieldPlaneSelect.value) || 0] || [];
    const rows = [], hover = [];
    for (let v = 0; v < section.v_values.length; ++v) {
      const row = [], hoverRow = [];
      for (let u = 0; u < width; ++u) {
        const sample = section.samples[u + v * width];
        const excluded = exclusionMask[u + v * width];
        if (excluded) {
          row.push(null);
          hoverRow.push("PEC/source exclusion zone");
          continue;
        }
        const value = fieldValue(sample, quantity, mode, fieldPhaseDegrees);
        const relativeDb = dbFactor * Math.log10(Math.max(value, maximum * 1e-12) / maximum);
        row.push(logarithmic ? Math.max(floor, relativeDb) : value);
        hoverRow.push(fieldHover(sample, quantity, mode, fieldPhaseDegrees, value, relativeDb));
      }
      rows.push(row); hover.push(hoverRow);
    }
    const units = quantity === "electric" ? "V/m" : quantity === "magnetic" ? "A/m" : "W/m²";
    const colorscale = [[0, "#030611"], [.2, "#35116e"], [.45, "#007fb0"],
      [.7, "#20dfb3"], [.88, "#fff04b"], [1, "#ff3b52"]];
    const traces = [{
      type: "heatmap", x: section.u_values, y: section.v_values, z: rows,
      customdata: hover, hovertemplate: `%{customdata}<extra></extra>`,
      colorscale, zmin: logarithmic ? floor : 0, zmax: logarithmic ? 0 : maximum,
      colorbar: { title: logarithmic ? "relative dB" : units, tickfont: { color: "#9ceeff" } },
      zsmooth: "best", connectgaps: false,
    }];
    if (vectorFieldMode(quantity, mode))
      traces.push(powerVectorTrace(
        section, exclusionMask, mode, fieldPhaseDegrees, maximum, floor));
    const powerTitle = instantaneousFieldMode(quantity, mode)
      ? "Instantaneous power flow" : "Average power flow";
    return Plotly.react(fieldWorkspace.querySelector("#near-field-plot"), traces, {
      title: { text: `${quantity === "power" ? powerTitle : quantity.toUpperCase() + " field"} · ` +
        `${String(section.normal_axis).toUpperCase()}-normal at ${Number(section.position).toPrecision(5)} m`,
        font: { color: "#7df9ff", size: 18 }, x: .02 },
      paper_bgcolor: "rgba(3,6,17,0)", plot_bgcolor: "#030611",
      font: { family: '"DejaVu Sans Mono", monospace', color: "#d8fbff" },
      margin: { l: 75, r: 80, t: 62, b: 62 },
      xaxis: { title: `${String(section.u_axis).toUpperCase()} (m)`, gridcolor: "#245069",
        scaleanchor: "y", scaleratio: 1 },
      yaxis: { title: `${String(section.v_axis).toUpperCase()} (m)`, gridcolor: "#245069" },
    }, { responsive: true, displaylogo: false, scrollZoom: true,
      toImageButtonOptions: { format: "png", filename: "nec2c-near-field" } });
  }
  fieldQuantitySelect.addEventListener("change", () => {
    setFieldModeOptions(); drawNearField();
  });
  [fieldPlaneSelect, fieldModeSelect, fieldScaleSelect]
    .forEach(element => element.addEventListener("change", drawNearField));
  fieldFloorSlider.addEventListener("input", () => {
    fieldWorkspace.querySelector("#near-field-floor-value").textContent = `−${Math.abs(Number(fieldFloorSlider.value))} dB`;
    drawNearField();
  });
  fieldPhaseSlider.addEventListener("input", () => {
    fieldPhaseDegrees = Number(fieldPhaseSlider.value); fieldPlaying = false;
    fieldWorkspace.querySelector("#near-field-play").textContent = "PLAY";
    fieldWorkspace.querySelector("#near-field-phase-value").textContent = `${Math.round(fieldPhaseDegrees)}°`;
    drawNearField();
  });
  fieldWorkspace.querySelector("#near-field-play").addEventListener("click", event => {
    fieldPlaying = !fieldPlaying; event.currentTarget.textContent = fieldPlaying ? "PAUSE" : "PLAY";
  });

  const plotWorkspace = createPlotWorkspace(data, { managedNavigation: false });
  const tabs = document.createElement("nav");
  tabs.id = "nec-tabs";
  tabs.innerHTML = `<button data-view="viewer3d" class="active">3D VIEW</button>
    <button data-view="plots">PLOTS</button><button data-view="pattern2d">2D PATTERN</button>` +
    (nearFieldSections.length ? `<button data-view="nearfield">NEAR FIELD</button>` : "");
  document.body.append(tabs);
  let activeView = "viewer3d";
  function show(view) {
    activeView = view;
    const canvasView = view === "viewer3d";
    canvas.hidden = !canvasView;
    controlsPanel.hidden = !canvasView;
    polarWorkspace.hidden = view !== "pattern2d";
    fieldWorkspace.hidden = view !== "nearfield";
    if (plotWorkspace) view === "plots" ? plotWorkspace.show() : plotWorkspace.hide();
    document.getElementById("metadata-panel").hidden = !canvasView;
    if (!canvasView) {
      inspector.hidden = true;
      currentProfile.hidden = true;
    } else if (inspectorEnabled.checked && inspectorHit) {
      renderInspector(inspectorHit);
    }
    tabs.querySelectorAll("button").forEach(button => button.classList.toggle("active", button.dataset.view === view));
    if (canvasView) fitCamera(camera, controls, scene);
    if (view === "pattern2d") drawPolar().then(() => Plotly.Plots.resize(polarWorkspace.querySelector("#pattern-polar")));
    if (view === "nearfield") drawNearField().then(() => Plotly.Plots.resize(fieldWorkspace.querySelector("#near-field-plot")));
    history.replaceState(null, "", `#${view}`);
  }
  tabs.addEventListener("click", event => {
    const button = event.target.closest("button[data-view]");
    if (button) show(button.dataset.view);
  });

  const requestedHash = location.hash.slice(1);
  const requested = ["geometry", "pattern3d"].includes(requestedHash) ? "viewer3d" : requestedHash;
  show(["viewer3d", "plots", "pattern2d", "nearfield"].includes(requested) ? requested : "viewer3d");

  let previousFrame = performance.now();
  let lastFieldAnimationDraw = 0;
  let fieldAnimationPending = false;
  function animate(now = performance.now()) {
    requestAnimationFrame(animate);
    const elapsed = Math.min(0.1, Math.max(0, (now - previousFrame) / 1000));
    previousFrame = now;
    if (activeView === "nearfield" && fieldPlaying && instantaneousFieldMode()) {
      fieldPhaseDegrees = (fieldPhaseDegrees + elapsed * 90) % 360;
      fieldPhaseSlider.value = String(Math.round(fieldPhaseDegrees));
      fieldWorkspace.querySelector("#near-field-phase-value").textContent = `${Math.round(fieldPhaseDegrees)}°`;
      if (!fieldAnimationPending && now - lastFieldAnimationDraw >= 80) {
        lastFieldAnimationDraw = now;
        fieldAnimationPending = true;
        drawNearField().finally(() => { fieldAnimationPending = false; });
      }
    }
    if (activeView !== "viewer3d") return;
    if (segmentPlaying && segmentDisplay.value.endsWith("instantaneous")) {
      segmentPhaseDegrees = (segmentPhaseDegrees + elapsed * 90) % 360;
      segmentPhaseSlider.value = String(Math.round(segmentPhaseDegrees));
      controlsPanel.querySelector("#segment-phase-value").textContent = `${Math.round(segmentPhaseDegrees)}°`;
      updateSegmentDisplay();
    }
    const width = canvas.clientWidth, height = canvas.clientHeight;
    if (canvas.width !== width * renderer.getPixelRatio() || canvas.height !== height * renderer.getPixelRatio()) {
      renderer.setSize(width, height, false); camera.aspect = width / height; camera.updateProjectionMatrix();
    }
    controls.update(); renderer.render(scene, camera);
  }
  document.documentElement.dataset.reportReady = "true";
  requestAnimationFrame(animate);
}
