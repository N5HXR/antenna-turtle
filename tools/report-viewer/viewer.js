import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import {
  averagePoynting,
  instantaneousPoynting,
} from "./field-math.js";
import {
  complexVectorMagnitude,
  instantaneousVector,
  surfaceCharge,
  surfaceCurrent,
} from "./surface-math.js";

async function main() {
const data = JSON.parse(document.getElementById("antenna-turtle-report-data").textContent);
const canvas = document.getElementById("viewport");
const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: false });
renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
renderer.setClearColor(0x030611, 1);
renderer.outputColorSpace = THREE.SRGBColorSpace;

const scene = new THREE.Scene();
scene.fog = new THREE.FogExp2(0x030611, 0.018);
const camera = new THREE.PerspectiveCamera(45, 1, 1e-5, 1e6);
camera.position.set(1.6, -2.1, 1.25);
const controls = new OrbitControls(camera, canvas);
controls.enableDamping = true;
controls.dampingFactor = 0.08;
controls.screenSpacePanning = true;

scene.add(new THREE.HemisphereLight(0x79e9ff, 0x16052e, 2.5));
const key = new THREE.DirectionalLight(0xff35dc, 2.7);
key.position.set(2, -3, 4);
scene.add(key);

const modelGroup = new THREE.Group();
const fieldGroup = new THREE.Group();
scene.add(modelGroup, fieldGroup);

function base64Bytes(encoded) {
  const raw = atob(encoded);
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; ++i) bytes[i] = raw.charCodeAt(i);
  return bytes;
}

async function gunzip(encoded) {
  const stream = new Blob([base64Bytes(encoded)]).stream()
    .pipeThrough(new DecompressionStream("gzip"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

async function floats(encoded, precision = 32) {
  const bytes = await gunzip(encoded);
  return precision === 64
    ? new Float64Array(bytes.buffer, bytes.byteOffset, bytes.byteLength / 8)
    : new Float32Array(bytes.buffer, bytes.byteOffset, bytes.byteLength / 4);
}

function transformPoint(matrix, x, y, z) {
  return [
    matrix[0][0] * x + matrix[0][1] * y + matrix[0][2] * z + matrix[0][3],
    matrix[1][0] * x + matrix[1][1] * y + matrix[1][2] * z + matrix[1][3],
    matrix[2][0] * x + matrix[2][1] * y + matrix[2][2] * z + matrix[2][3],
  ];
}

function transformVector(matrix, x, y, z) {
  return [
    matrix[0][0] * x + matrix[0][1] * y + matrix[0][2] * z,
    matrix[1][0] * x + matrix[1][1] * y + matrix[1][2] * z,
    matrix[2][0] * x + matrix[2][1] * y + matrix[2][2] * z,
  ];
}

let worldBounds = new THREE.Box3();
const reportGeometry = new Map();
for (const item of data.geometry) {
  const positions = await floats(item.positions);
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute("position", new THREE.BufferAttribute(positions, 3));
  geometry.computeVertexNormals();
  const material = new THREE.MeshStandardMaterial({
    color: new THREE.Color(item.color || "#5bf6ff"),
    metalness: item.metal ? 0.78 : 0.05,
    roughness: item.metal ? 0.28 : 0.72,
    transparent: true,
    opacity: item.opacity ?? 0.78,
    side: THREE.DoubleSide,
  });
  const mesh = new THREE.Mesh(geometry, material);
  mesh.name = item.name;
  modelGroup.add(mesh);
  reportGeometry.set(item.index, { item, mesh });
  geometry.computeBoundingBox();
  worldBounds.union(geometry.boundingBox);
}

if (worldBounds.isEmpty()) worldBounds.setFromCenterAndSize(new THREE.Vector3(), new THREE.Vector3(1, 1, 1));
const center = worldBounds.getCenter(new THREE.Vector3());
const size = worldBounds.getSize(new THREE.Vector3());
const diagonal = Math.max(size.length(), 1e-6);
controls.target.copy(center);
camera.near = diagonal / 10000;
camera.far = diagonal * 1000;
camera.position.copy(center).add(new THREE.Vector3(1.2, -1.7, 1.05).normalize().multiplyScalar(diagonal * 1.35));
camera.updateProjectionMatrix();

const captureSelect = document.getElementById("capture");
const currentCaptures = data.captures.filter(capture => capture.quantity === "current");
const chargeCaptures = data.captures.filter(capture => capture.quantity === "charge-flux");
const surfaceMagneticCaptures = data.captures.filter(
  capture => capture.quantity === "surface-magnetic");
const surfaceChargeCaptures = data.captures.filter(
  capture => capture.quantity === "surface-charge-flux");
const fieldGroups = new Map();
for (const capture of data.captures) {
  if (capture.quantity !== "electric" && capture.quantity !== "magnetic") continue;
  const volume = capture.shape.slice(0, 3).every(length => length > 1);
  if (!fieldGroups.has(capture.source))
    fieldGroups.set(capture.source, {
      kind: volume ? "field-volume" : "field-slice",
      label: capture.source,
      fields: {},
    });
  fieldGroups.get(capture.source).fields[capture.quantity] = capture;
}
const displayLayers = [
  ...(currentCaptures.length || surfaceMagneticCaptures.length ? [{
    kind: "current-group",
    label: "current — all conductors",
    captures: currentCaptures,
    chargeCaptures,
    surfaceMagneticCaptures,
    surfaceChargeCaptures,
  }] : []),
  ...fieldGroups.values(),
];
for (const [index, layer] of displayLayers.entries()) {
  const option = document.createElement("option");
  option.value = String(index);
  option.textContent = layer.kind === "current-group"
    ? `${layer.label} (${layer.surfaceMagneticCaptures.length ? "A/m" : layer.captures[0].units})`
    : layer.label;
  captureSelect.append(option);
}

let active = null;
let displayObject = null;
let currentOverlay = null;
let currentMode = "magnitude";
let currentScale = "log";
let currentLogFloor = -40;
let fieldQuantity = "electric";
let fieldMode = "tangent-instantaneous";
let fieldRange = "slice";
let fieldScale = "log";
let logFloor = -40;
let fieldOpacity = 0.8;
let sliceAxis = "x";
let slicePosition = 0.5;
let phaseDegrees = 0;
let playing = true;
let speed = 1;
let priorTime = performance.now();

const fieldQuantitySelect = document.getElementById("field-quantity");
const powerOption = document.createElement("option");
powerOption.value = "power";
powerOption.textContent = "POWER";
fieldQuantitySelect.append(powerOption);

const reportStyle = document.createElement("style");
reportStyle.textContent = `
  .color-legend { margin-top:9px; display:grid; grid-template-columns:1fr auto;
    gap:4px 10px; align-items:center; font-size:10px; color:#b9efff }
  .color-legend[hidden] { display:none }
  .legend-bar { height:10px; border:1px solid #29e9ff88; border-radius:2px }
  .legend-labels { display:flex; justify-content:space-between; grid-column:1 }
  .legend-units { color:#fff45c; grid-column:2; grid-row:1 / span 2 }
`;
document.head.append(reportStyle);
const fieldLegend = document.createElement("div");
fieldLegend.id = "field-legend";
fieldLegend.className = "color-legend";
fieldLegend.innerHTML = `<div class="legend-bar"></div><span class="legend-units"></span>
  <div class="legend-labels"><span class="legend-low"></span><span class="legend-mid"></span><span class="legend-high"></span></div>`;
document.getElementById("field-controls").append(fieldLegend);
const currentLegend = document.createElement("div");
currentLegend.id = "current-legend";
currentLegend.className = "color-legend";
currentLegend.hidden = true;
currentLegend.innerHTML = `<div class="legend-bar"></div><span class="legend-units"></span>
  <div class="legend-labels"><span class="legend-low"></span><span class="legend-mid"></span><span class="legend-high"></span></div>`;
const currentScaleRow = document.createElement("div");
currentScaleRow.id = "current-scale-row";
currentScaleRow.className = "row";
currentScaleRow.innerHTML = `<label for="current-scale">SCALE</label>
  <select id="current-scale"><option value="linear">linear</option><option value="log" selected>log</option></select>
  <label for="current-log-floor">FLOOR <span id="current-log-floor-value">−40 dB</span></label>
  <input id="current-log-floor" type="range" min="-80" max="-10" step="1" value="-40">`;
document.getElementById("current-mode-row").after(currentScaleRow);
currentScaleRow.after(currentLegend);
const currentOverlayLabel = document.createElement("label");
currentOverlayLabel.hidden = true;
currentOverlayLabel.innerHTML = `<input id="current-overlay" type="checkbox"> CURRENT`;
document.querySelector(".checks").prepend(currentOverlayLabel);

const electromagneticModes = [
  ["tangent-instantaneous", "instantaneous tangent intensity"],
  ["streamlines", "instantaneous field lines"],
  ["tangent-vectors", "tangent vectors"],
  ["tangent-magnitude", "tangent envelope (static)"],
  ["magnitude", "total envelope (static)"],
  ["normal", "normal component"],
  ["x", "x component"], ["y", "y component"], ["z", "z component"],
  ["vectors", "3D vectors"],
];
const powerModes = [
  ["power-average-magnitude", "average power intensity"],
  ["power-average-normal", "average through-plane power"],
  ["power-average-vectors", "average power vectors"],
  ["power-average-streamlines", "average power-flow lines"],
  ["power-instantaneous-magnitude", "instantaneous power intensity"],
  ["power-instantaneous-normal", "instantaneous through-plane power"],
  ["power-instantaneous-vectors", "instantaneous power vectors"],
  ["power-instantaneous-streamlines", "instantaneous power-flow lines"],
];

function setModeOptions() {
  const select = document.getElementById("field-mode");
  const choices = fieldQuantity === "power" ? powerModes : electromagneticModes;
  select.replaceChildren(...choices.map(([value, label]) => {
    const option = document.createElement("option");
    option.value = value;
    option.textContent = label;
    return option;
  }));
  if (!choices.some(([value]) => value === fieldMode))
    fieldMode = choices[0][0];
  select.value = fieldMode;
}

async function loadCaptureData(capture) {
  const [real, imaginary] = await Promise.all([floats(capture.real), floats(capture.imaginary)]);
  const [nx, ny, nz] = capture.shape;
  const sampleCount = nx * ny * nz;
  let maximum = 0;
  const userReal = new Float32Array(real.length);
  const userImaginary = new Float32Array(imaginary.length);
  const componentMaximum = [0, 0, 0];
  const tangentMaximum = [0, 0, 0];
  for (let sample = 0; sample < sampleCount; ++sample) {
    let magnitude2 = 0;
    for (let component = 0; component < 3; ++component) {
      const offset = sample + sampleCount * component;
      magnitude2 += real[offset] ** 2 + imaginary[offset] ** 2;
    }
    const magnitude = Math.sqrt(magnitude2);
    maximum = Math.max(maximum, magnitude);
    const realVector = transformVector(data.solver_to_user_transform,
      real[sample], real[sample + sampleCount], real[sample + 2 * sampleCount]);
    const imaginaryVector = transformVector(data.solver_to_user_transform,
      imaginary[sample], imaginary[sample + sampleCount], imaginary[sample + 2 * sampleCount]);
    for (let component = 0; component < 3; ++component) {
      const offset = sample + sampleCount * component;
      userReal[offset] = realVector[component];
      userImaginary[offset] = imaginaryVector[component];
      componentMaximum[component] = Math.max(componentMaximum[component],
        Math.hypot(realVector[component], imaginaryVector[component]));
    }
    for (let normal = 0; normal < 3; ++normal) {
      let tangentMagnitude2 = 0;
      for (let component = 0; component < 3; ++component)
        if (component !== normal)
          tangentMagnitude2 += realVector[component] ** 2
            + imaginaryVector[component] ** 2;
      tangentMaximum[normal] = Math.max(
        tangentMaximum[normal], Math.sqrt(tangentMagnitude2));
    }
  }
  return {
    capture, real, imaginary, userReal, userImaginary,
    nx, ny, nz, sampleCount, maximum, componentMaximum, tangentMaximum,
  };
}

const captureCache = new Map();
function cachedCaptureData(capture) {
  if (!captureCache.has(capture.name))
    captureCache.set(capture.name, loadCaptureData(capture));
  return captureCache.get(capture.name);
}

function disposeDisplay(object) {
  object.traverse(child => {
    if (child.geometry) child.geometry.dispose();
    if (child.material) child.material.dispose();
  });
}

async function createCurrentGroup(layer) {
  const [loaded, loadedCharge, loadedSurfaceH, loadedSurfaceD] = await Promise.all([
    Promise.all(layer.captures.map(cachedCaptureData)),
    Promise.all(layer.chargeCaptures.map(cachedCaptureData)),
    Promise.all(layer.surfaceMagneticCaptures.map(cachedCaptureData)),
    Promise.all(layer.surfaceChargeCaptures.map(cachedCaptureData)),
  ]);
  const componentEnergy = [0, 0, 0];
  for (const item of loaded)
    for (let component = 0; component < 3; ++component)
      for (let sample = 0; sample < item.sampleCount; ++sample) {
        const offset = sample + item.sampleCount * component;
        componentEnergy[component] += item.real[offset] ** 2 + item.imaginary[offset] ** 2;
      }
  const dominantComponent = componentEnergy.indexOf(Math.max(...componentEnergy));
  const planarItems = loaded.map(item => {
    const singletonAxis = [item.nx, item.ny, item.nz]
      .findIndex(length => length === 1);
    if (singletonAxis < 0)
      throw new Error("Planar current heatmaps require one singleton capture axis");
    return buildCurrentHeatmap(item, singletonAxis, dominantComponent);
  });
  if (loadedCharge.length !== planarItems.length)
    throw new Error("Conductor charge-flux captures do not match current captures");
  for (let index = 0; index < planarItems.length; ++index)
    attachChargeNodes(planarItems[index], loadedCharge[index]);
  const surfaceDByGeometry = new Map(loadedSurfaceD.map(item => [
    item.capture.surface_reconstruction.geometry_index, item,
  ]));
  const surfaceItems = loadedSurfaceH.map(magnetic => {
    const reconstruction = magnetic.capture.surface_reconstruction;
    const geometry = reportGeometry.get(reconstruction.geometry_index);
    const electricFlux = surfaceDByGeometry.get(reconstruction.geometry_index);
    if (!geometry || !electricFlux)
      throw new Error("Surface-current shell is missing geometry or electric-flux data");
    return buildSurfaceHeatmap(geometry, magnetic, electricFlux, reconstruction);
  });
  const items = [...planarItems, ...surfaceItems];
  let displayMaximum = 0, chargeMaximum = 0;
  for (const item of items) {
    if (item.kind === "surface-current-heatmap") {
      for (const node of item.nodes) {
        displayMaximum = Math.max(displayMaximum, complexVectorMagnitude(node.current));
        chargeMaximum = Math.max(chargeMaximum,
          Math.hypot(node.charge.real, node.charge.imaginary));
      }
    } else {
      for (const node of item.nodes.values())
        displayMaximum = Math.max(displayMaximum,
          Math.hypot(node.real, node.imaginary));
      for (const node of item.chargeNodes.values())
        chargeMaximum = Math.max(chargeMaximum,
          Math.hypot(node.real, node.imaginary));
    }
  }
  for (const item of items) {
    item.currentMaximum = displayMaximum;
    item.chargeMaximum = chargeMaximum;
    item.mixedSurfaceGroup = surfaceItems.length > 0;
  }
  const object = new THREE.Group();
  for (const item of items) object.add(item.object);
  return {
    kind: "current-group", object, items,
    frequencyMHz: (loaded[0] || loadedSurfaceH[0]).capture.frequency_mhz,
    conductorCount: items.length,
    cellCount: items.reduce((sum, item) => sum + item.cells.length, 0),
    currentUnits: "A/m",
    hasSurfaceItems: surfaceItems.length > 0,
  };
}

async function loadCapture(index) {
  const layer = displayLayers[index];
  if (displayObject) {
    fieldGroup.remove(displayObject);
    disposeDisplay(displayObject);
  }
  if (currentOverlay) {
    fieldGroup.remove(currentOverlay.object);
    disposeDisplay(currentOverlay.object);
    currentOverlay = null;
  }
  if (layer.kind === "current-group") {
    active = await createCurrentGroup(layer);
  } else {
    const available = Object.keys(layer.fields);
    const hasPower = Boolean(layer.fields.electric && layer.fields.magnetic);
    if (fieldQuantity === "power" && !hasPower) fieldQuantity = available[0];
    if (fieldQuantity !== "power" && !layer.fields[fieldQuantity])
      fieldQuantity = available[0];
    setModeOptions();
    document.getElementById("field-quantity").value = fieldQuantity;
    for (const option of document.getElementById("field-quantity").options)
      option.disabled = option.value === "power"
        ? !hasPower : !layer.fields[option.value];
    const fields = {};
    if (fieldQuantity === "power") {
      [fields.electric, fields.magnetic] = await Promise.all([
        cachedCaptureData(layer.fields.electric),
        cachedCaptureData(layer.fields.magnetic),
      ]);
      validatePowerFields(fields.electric, fields.magnetic);
    } else {
      fields[fieldQuantity] = await cachedCaptureData(layer.fields[fieldQuantity]);
    }
    const loaded = fieldQuantity === "power" ? fields.electric : fields[fieldQuantity];
    active = buildFieldDisplay(loaded, layer.kind === "field-volume", fields);
  }
  displayObject = active.object;
  fieldGroup.add(displayObject);
  const modeRow = document.getElementById("current-mode-row");
  modeRow.hidden = active.kind !== "current-group";
  currentScaleRow.hidden = active.kind !== "current-group";
  const directionOption = document.querySelector("#current-mode option[value=direction]");
  directionOption.textContent = active.kind === "current-group" && active.hasSurfaceItems
    ? "instantaneous |current|" : "dir(current)";
  document.getElementById("field-controls").hidden = active.kind !== "field-slice";
  fieldLegend.hidden = active.kind !== "field-slice";
  document.getElementById("volume-controls").hidden = !active.volume;
  currentOverlayLabel.hidden = active.kind === "current-group"
    || (currentCaptures.length === 0 && surfaceMagneticCaptures.length === 0);
  if (active.kind === "field-slice") fitToObject(active.plane);
  if (active.kind === "field-slice"
      && document.getElementById("current-overlay").checked)
    await showCurrentOverlay();
  updateCapture();
}

async function showCurrentOverlay() {
  if (currentOverlay
      || (currentCaptures.length === 0 && surfaceMagneticCaptures.length === 0)) return;
  const layer = displayLayers.find(candidate => candidate.kind === "current-group");
  currentOverlay = await createCurrentGroup(layer);
  for (const item of currentOverlay.items) updateCurrentHeatmap(item);
  fieldGroup.add(currentOverlay.object);
}

function validatePowerFields(electric, magnetic) {
  if (electric.nx !== magnetic.nx || electric.ny !== magnetic.ny
      || electric.nz !== magnetic.nz)
    throw new Error("Poynting visualization requires co-registered E and H grids");
  for (const axis of ["x", "y", "z"]) {
    const left = electric.capture[axis], right = magnetic.capture[axis];
    if (left.length !== right.length
        || left.some((value, index) => Math.abs(value - right[index]) > 1e-12))
      throw new Error("Poynting visualization requires matching E and H coordinates");
  }
}

function fitToObject(object) {
  const bounds = new THREE.Box3().setFromObject(object);
  if (bounds.isEmpty()) return;
  const target = bounds.getCenter(new THREE.Vector3());
  const extent = Math.max(bounds.getSize(new THREE.Vector3()).length(), 1e-6);
  const direction = camera.position.clone().sub(controls.target).normalize();
  controls.target.copy(target);
  camera.position.copy(target).add(direction.multiplyScalar(extent * 1.15));
  camera.near = extent / 10000;
  camera.far = extent * 1000;
  camera.updateProjectionMatrix();
}

function solverAxisForUserAxis(userAxis) {
  const row = data.solver_to_user_transform["xyz".indexOf(userAxis)].slice(0, 3);
  return row.map(Math.abs).indexOf(Math.max(...row.map(Math.abs)));
}

function sampleIndex(loaded, indices) {
  return indices[0] + loaded.nx * (indices[1] + loaded.ny * indices[2]);
}

function sampleReference(loaded, indices, normalAxis, lower, upper, mix) {
  const low = [...indices], high = [...indices];
  low[normalAxis] = lower;
  high[normalAxis] = upper;
  return { lower: sampleIndex(loaded, low), upper: sampleIndex(loaded, high), mix };
}

function buildFieldDisplay(loaded, volume = false, fields = {}) {
  const { capture, nx, ny, nz } = loaded;
  const dimensions = [nx, ny, nz];
  let normalAxis, lower, upper, mix, normalVector, normalUserAxis;
  if (volume) {
    normalUserAxis = "xyz".indexOf(sliceAxis);
    normalAxis = solverAxisForUserAxis(sliceAxis);
    const fractionalIndex = slicePosition * (dimensions[normalAxis] - 1);
    lower = Math.floor(fractionalIndex);
    upper = Math.ceil(fractionalIndex);
    mix = fractionalIndex - lower;
    normalVector = new THREE.Vector3(0, 0, 0);
    normalVector.setComponent(normalUserAxis, 1);
  } else {
    normalAxis = dimensions.findIndex(length => length === 1);
    if (normalAxis < 0)
      throw new Error("Field-slice heatmaps require exactly one singleton axis");
    lower = upper = 0;
    mix = 0;
    const solverNormal = [0, 0, 0];
    solverNormal[normalAxis] = 1;
    normalVector = new THREE.Vector3(
      ...transformVector(data.solver_to_user_transform, ...solverNormal)).normalize();
    normalUserAxis = [normalVector.x, normalVector.y, normalVector.z]
      .map(Math.abs).indexOf(Math.max(Math.abs(normalVector.x), Math.abs(normalVector.y), Math.abs(normalVector.z)));
  }
  const varyingAxes = [0, 1, 2].filter(axis => axis !== normalAxis);
  const [axisA, axisB] = varyingAxes;
  const coordinates = [capture.x, capture.y, capture.z];
  const normalCoordinate = coordinates[normalAxis][lower] * (1 - mix)
    + coordinates[normalAxis][upper] * mix;
  const fixedCoordinates = [coordinates[0][0], coordinates[1][0], coordinates[2][0]];
  fixedCoordinates[normalAxis] = normalCoordinate;
  const userPosition = transformPoint(data.solver_to_user_transform, ...fixedCoordinates)[normalUserAxis];
  const rawCells = (dimensions[axisA] - 1) * (dimensions[axisB] - 1);
  const stride = Math.max(1, Math.ceil(Math.sqrt(rawCells / 18000)));
  const positions = [];
  const samples = [];
  const vertex = (a, b) => {
    const indices = [0, 0, 0];
    indices[axisA] = a;
    indices[axisB] = b;
    const pointCoordinates = [...fixedCoordinates];
    pointCoordinates[axisA] = coordinates[axisA][a];
    pointCoordinates[axisB] = coordinates[axisB][b];
    return {
      sample: sampleReference(loaded, indices, normalAxis, lower, upper, mix),
      point: transformPoint(data.solver_to_user_transform, ...pointCoordinates),
    };
  };
  for (let a = 0; a < dimensions[axisA] - 1; a += stride) {
    const nextA = Math.min(a + stride, dimensions[axisA] - 1);
    for (let b = 0; b < dimensions[axisB] - 1; b += stride) {
      const nextB = Math.min(b + stride, dimensions[axisB] - 1);
      const corners = [vertex(a, b), vertex(nextA, b), vertex(nextA, nextB), vertex(a, nextB)];
      for (const index of [0, 1, 2, 0, 2, 3]) {
        positions.push(...corners[index].point);
        samples.push(corners[index].sample);
      }
    }
  }
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute("position", new THREE.Float32BufferAttribute(positions, 3));
  const colors = new Float32Array(positions.length);
  geometry.setAttribute("color", new THREE.BufferAttribute(colors, 3));
  const material = new THREE.MeshBasicMaterial({
    vertexColors: true, side: THREE.DoubleSide, transparent: true,
    opacity: fieldOpacity, depthWrite: false,
  });
  const plane = new THREE.Mesh(geometry, material);
  const arrows = buildFieldArrows(
    loaded, varyingAxes, normalAxis, lower, upper, mix, fixedCoordinates);
  const streamlines = buildStreamlineDisplay(loaded);
  const pml = buildPmlOutline(normalAxis, fixedCoordinates);
  const object = new THREE.Group();
  object.add(plane, arrows, streamlines, pml);
  return {
    kind: "field-slice", volume, object, plane, arrows, streamlines, pml,
    loaded, fields, samples, colors,
    rangeCache: new Map(),
    normalAxis, normalVector, normalUserAxis, varyingAxes, userPosition,
    lower, upper, mix, coordinates, fixedCoordinates, dimensions,
  };
}

function buildFieldArrows(loaded, varyingAxes, normalAxis, lower, upper, mix,
                          fixedCoordinates) {
  const dimensions = [loaded.nx, loaded.ny, loaded.nz];
  const coordinates = [loaded.capture.x, loaded.capture.y, loaded.capture.z];
  const longest = Math.max(...varyingAxes.map(axis => dimensions[axis]));
  const stride = Math.max(1, Math.ceil(longest / 28));
  const group = new THREE.Group();
  group.userData.entries = [];
  for (let a = 0; a < dimensions[varyingAxes[0]]; a += stride) {
    for (let b = 0; b < dimensions[varyingAxes[1]]; b += stride) {
      const indices = [0, 0, 0];
      indices[varyingAxes[0]] = a;
      indices[varyingAxes[1]] = b;
      const pointCoordinates = [...fixedCoordinates];
      pointCoordinates[varyingAxes[0]] = coordinates[varyingAxes[0]][a];
      pointCoordinates[varyingAxes[1]] = coordinates[varyingAxes[1]][b];
      const origin = transformPoint(data.solver_to_user_transform,
        ...pointCoordinates);
      const arrow = new THREE.ArrowHelper(new THREE.Vector3(1, 0, 0),
        new THREE.Vector3(...origin), diagonal * 0.01, 0xffffff,
        diagonal * 0.003, diagonal * 0.0018);
      group.add(arrow);
      group.userData.entries.push({
        arrow,
        sample: sampleReference(loaded, indices, normalAxis, lower, upper, mix),
      });
    }
  }
  group.visible = false;
  return group;
}

function buildStreamlineDisplay(loaded) {
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute("position", new THREE.Float32BufferAttribute([], 3));
  geometry.setAttribute("color", new THREE.Float32BufferAttribute([], 3));
  const material = new THREE.LineBasicMaterial({
    vertexColors: true,
    transparent: true,
    opacity: 0.82,
    depthWrite: false,
  });
  const lines = new THREE.LineSegments(geometry, material);
  lines.visible = false;
  return lines;
}

function buildPmlOutline(normalAxis, fixedCoordinates) {
  const group = new THREE.Group();
  if (!data.pml?.enabled) return group;
  const varying = [0, 1, 2].filter(axis => axis !== normalAxis);
  const fixed = [...fixedCoordinates];
  const corners = [[0, 0], [1, 0], [1, 1], [0, 1]];
  const points = corners.map(([a, b]) => {
    const point = [...fixed];
    point[varying[0]] = a ? data.pml.inner_max[varying[0]] : data.pml.inner_min[varying[0]];
    point[varying[1]] = b ? data.pml.inner_max[varying[1]] : data.pml.inner_min[varying[1]];
    return new THREE.Vector3(...transformPoint(data.solver_to_user_transform, ...point));
  });
  const geometry = new THREE.BufferGeometry().setFromPoints([...points, points[0]]);
  const material = new THREE.LineDashedMaterial({ color: 0xff38d1, dashSize: diagonal * 0.012, gapSize: diagonal * 0.007, transparent: true, opacity: 0.75 });
  const line = new THREE.Line(geometry, material);
  line.computeLineDistances();
  group.add(line);
  return group;
}

function buildCurrentHeatmap(loaded, singletonAxis, dominantComponent) {
  const { capture, real, imaginary, maximum, sampleCount, nx, ny, nz } = loaded;
  const dimensions = [nx, ny, nz];
  const varyingAxes = [0, 1, 2].filter(axis => dimensions[axis] > 1);
  if (varyingAxes.length !== 2)
    throw new Error("Planar current heatmaps require two varying capture axes");
  const [axisA, axisB] = varyingAxes;
  const coordinates = [capture.x, capture.y, capture.z];
  const spans = varyingAxes.map(axis =>
    Math.abs(coordinates[axis].at(-1) - coordinates[axis][0]));
  const lengthAxis = spans[0] >= spans[1] ? varyingAxes[0] : varyingAxes[1];
  const widthAxis = lengthAxis === varyingAxes[0] ? varyingAxes[1] : varyingAxes[0];
  const rawCellCount = (dimensions[axisA] - 1) * (dimensions[axisB] - 1);
  const stride = Math.max(1, Math.ceil(Math.sqrt(rawCellCount / 10000)));
  const cells = [];
  const stationEnds = new Map();
  const positionValues = [];
  const matrix = data.solver_to_user_transform;
  const normal = [0, 0, 0];
  normal[singletonAxis] = 1;
  const convertedNormal = transformVector(matrix, normal[0], normal[1], normal[2]);
  const normalLength = Math.hypot(...convertedNormal) || 1;
  const visualOffset = convertedNormal.map(value => value * diagonal * 0.0015 / normalLength);
  const sampleAt = indices => indices[0] + nx * (indices[1] + ny * indices[2]);
  const corner = (a, b) => {
    const indices = [0, 0, 0];
    indices[axisA] = a;
    indices[axisB] = b;
    const point = transformPoint(matrix,
      coordinates[0][indices[0]], coordinates[1][indices[1]], coordinates[2][indices[2]]);
    for (let axis = 0; axis < 3; ++axis) point[axis] += visualOffset[axis];
    return { point, sample: sampleAt(indices) };
  };
  for (let a = 0; a < dimensions[axisA] - 1; a += stride) {
    const nextA = Math.min(a + stride, dimensions[axisA] - 1);
    for (let b = 0; b < dimensions[axisB] - 1; b += stride) {
      const nextB = Math.min(b + stride, dimensions[axisB] - 1);
      const corners = [corner(a, b), corner(nextA, b), corner(nextA, nextB), corner(a, nextB)];
      const vertexOrder = [0, 1, 2, 0, 2, 3];
      for (const vertex of vertexOrder) positionValues.push(...corners[vertex].point);
      const widthStart = widthAxis === axisA ? a : b;
      const widthStop = widthAxis === axisA ? nextA : nextB;
      const startStation = lengthAxis === axisA ? a : b;
      const endStation = lengthAxis === axisA ? nextA : nextB;
      const cornerStations = lengthAxis === axisA
        ? [startStation, endStation, endStation, startStation]
        : [startStation, startStation, endStation, endStation];
      cells.push({
        samples: corners.map(value => value.sample),
        station: startStation,
        endStation,
        vertexStations: vertexOrder.map(vertex => cornerStations[vertex]),
        width: Math.abs(coordinates[widthAxis][widthStop] - coordinates[widthAxis][widthStart]),
      });
      stationEnds.set(startStation, endStation);
    }
  }
  const stations = new Map();
  for (const cell of cells) {
    let real = 0, imaginary = 0;
    for (const sample of cell.samples) {
      const offset = sample + sampleCount * dominantComponent;
      real += loaded.real[offset];
      imaginary += loaded.imaginary[offset];
    }
    const station = stations.get(cell.station) || { real: 0, imaginary: 0 };
    station.real += real / cell.samples.length * cell.width;
    station.imaginary += imaginary / cell.samples.length * cell.width;
    stations.set(cell.station, station);
  }
  const stationKeys = [...stations.keys()].sort((left, right) => left - right);
  const nodes = new Map();
  const averagePhasor = (left, right) => ({
    real: (left.real + right.real) / 2,
    imaginary: (left.imaginary + right.imaginary) / 2,
  });
  for (let index = 0; index < stationKeys.length; ++index) {
    const key = stationKeys[index];
    const station = stations.get(key);
    const prior = index > 0 ? stations.get(stationKeys[index - 1]) : null;
    const next = index + 1 < stationKeys.length ? stations.get(stationKeys[index + 1]) : null;
    nodes.set(key, prior ? averagePhasor(prior, station) : station);
    nodes.set(stationEnds.get(key), next ? averagePhasor(station, next) : station);
  }
  const positions = new Float32Array(positionValues);
  const colors = new Float32Array(positions.length);
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute("position", new THREE.BufferAttribute(positions, 3));
  geometry.setAttribute("color", new THREE.BufferAttribute(colors, 3));
  const material = new THREE.MeshBasicMaterial({
    vertexColors: true,
    side: THREE.DoubleSide,
    transparent: true,
    opacity: 0.96,
    depthWrite: true,
  });
  const object = new THREE.Mesh(geometry, material);
  return {
    kind: "current-heatmap", object, capture, real, imaginary,
    cells, stations, nodes, chargeNodes: new Map(), colors,
    maximum, currentMaximum: 0, chargeMaximum: 0,
    dominantComponent, lengthAxis, singletonAxis, coordinates,
    sampleCount, nx, ny, nz,
  };
}

function attachChargeNodes(item, loaded) {
  const dimensions = [loaded.nx, loaded.ny, loaded.nz];
  const coordinates = [loaded.capture.x, loaded.capture.y, loaded.capture.z];
  const singletonAxis = dimensions.findIndex(length => length === 1);
  if (singletonAxis < 0)
    throw new Error("Surface-charge capture requires one singleton axis");
  if (singletonAxis !== item.singletonAxis)
    throw new Error("Surface-charge and current planes do not have the same normal");
  const widthAxis = [0, 1, 2].find(axis =>
    axis !== singletonAxis && axis !== item.lengthAxis);
  const lengthCoordinates = coordinates[item.lengthAxis];
  const widthCoordinates = coordinates[widthAxis];
  const values = [];
  const sampleAt = indices =>
    indices[0] + loaded.nx * (indices[1] + loaded.ny * indices[2]);
  for (let lengthIndex = 0; lengthIndex < dimensions[item.lengthAxis]; ++lengthIndex) {
    let realIntegral = 0;
    let imaginaryIntegral = 0;
    let totalWidth = 0;
    for (let widthIndex = 0; widthIndex < dimensions[widthAxis] - 1; ++widthIndex) {
      const width = Math.abs(widthCoordinates[widthIndex + 1] - widthCoordinates[widthIndex]);
      const first = [0, 0, 0];
      const second = [0, 0, 0];
      first[item.lengthAxis] = lengthIndex;
      second[item.lengthAxis] = lengthIndex;
      first[widthAxis] = widthIndex;
      second[widthAxis] = widthIndex + 1;
      const firstOffset = sampleAt(first) + loaded.sampleCount * singletonAxis;
      const secondOffset = sampleAt(second) + loaded.sampleCount * singletonAxis;
      realIntegral += width * (loaded.real[firstOffset] + loaded.real[secondOffset]) / 2;
      imaginaryIntegral += width * (loaded.imaginary[firstOffset] + loaded.imaginary[secondOffset]) / 2;
      totalWidth += width;
    }
    values.push({
      coordinate: lengthCoordinates[lengthIndex],
      real: realIntegral / Math.max(totalWidth, Number.EPSILON),
      imaginary: imaginaryIntegral / Math.max(totalWidth, Number.EPSILON),
    });
  }
  const interpolate = coordinate => {
    if (coordinate <= values[0].coordinate) return values[0];
    if (coordinate >= values.at(-1).coordinate) return values.at(-1);
    let upper = 1;
    while (values[upper].coordinate < coordinate) ++upper;
    const lower = upper - 1;
    const span = values[upper].coordinate - values[lower].coordinate;
    const amount = span === 0 ? 0 : (coordinate - values[lower].coordinate) / span;
    return {
      real: values[lower].real + amount * (values[upper].real - values[lower].real),
      imaginary: values[lower].imaginary
        + amount * (values[upper].imaginary - values[lower].imaginary),
    };
  };
  for (const key of item.nodes.keys())
    item.chargeNodes.set(key, interpolate(item.coordinates[item.lengthAxis][key]));
}

function fieldPhasorAtPoint(loaded, point) {
  const coordinates = [loaded.capture.x, loaded.capture.y, loaded.capture.z];
  const brackets = coordinates.map((axis, index) => coordinateBracket(axis, point[index]));
  const real = [0, 0, 0], imaginary = [0, 0, 0];
  for (let bx = 0; bx < 2; ++bx)
    for (let by = 0; by < 2; ++by)
      for (let bz = 0; bz < 2; ++bz) {
        const choices = [bx, by, bz];
        const indices = [0, 0, 0];
        let weight = 1;
        for (let axis = 0; axis < 3; ++axis) {
          const [lower, upper, mix] = brackets[axis];
          indices[axis] = choices[axis] ? upper : lower;
          weight *= choices[axis] ? mix : 1 - mix;
        }
        if (weight === 0) continue;
        const sample = sampleIndex(loaded, indices);
        for (let component = 0; component < 3; ++component) {
          const offset = sample + loaded.sampleCount * component;
          real[component] += weight * loaded.real[offset];
          imaginary[component] += weight * loaded.imaginary[offset];
        }
      }
  return { real, imaginary };
}

function buildSurfaceHeatmap(geometryItem, magnetic, electricFlux, reconstruction) {
  const source = geometryItem.mesh.geometry.attributes.position.array;
  const tolerance = Math.max(diagonal * 1e-8, 1e-12);
  const keyFor = (x, y, z) => [x, y, z]
    .map(value => Math.round(value / tolerance)).join(":");
  const normalSums = new Map();
  for (let offset = 0; offset < source.length; offset += 9) {
    const a = new THREE.Vector3(source[offset], source[offset + 1], source[offset + 2]);
    const b = new THREE.Vector3(source[offset + 3], source[offset + 4], source[offset + 5]);
    const c = new THREE.Vector3(source[offset + 6], source[offset + 7], source[offset + 8]);
    const face = b.clone().sub(a).cross(c.clone().sub(a));
    if (face.lengthSq() === 0) continue;
    for (const point of [a, b, c]) {
      const key = keyFor(point.x, point.y, point.z);
      if (!normalSums.has(key)) normalSums.set(key, new THREE.Vector3());
      normalSums.get(key).add(face);
    }
  }
  for (const normal of normalSums.values()) normal.normalize();
  const nodeCache = new Map();
  const nodes = [];
  const positions = new Float32Array(source.length);
  const colors = new Float32Array(source.length);
  const offsetDistance = reconstruction.sample_offset_m;
  for (let vertex = 0; vertex < source.length / 3; ++vertex) {
    const base = vertex * 3;
    const point = [source[base], source[base + 1], source[base + 2]];
    const key = keyFor(...point);
    const userNormal = normalSums.get(key) || new THREE.Vector3(0, 0, 1);
    let node = nodeCache.get(key);
    if (!node) {
      const solverPoint = transformPoint(data.user_to_solver_transform, ...point);
      let solverNormal = new THREE.Vector3(...transformVector(
        data.user_to_solver_transform, userNormal.x, userNormal.y, userNormal.z)).normalize();
      const plusPoint = solverPoint.map((value, index) =>
        value + offsetDistance * solverNormal.getComponent(index));
      const minusPoint = solverPoint.map((value, index) =>
        value - offsetDistance * solverNormal.getComponent(index));
      let hPlus = fieldPhasorAtPoint(magnetic, plusPoint);
      let hMinus = fieldPhasorAtPoint(magnetic, minusPoint);
      let dPlus = fieldPhasorAtPoint(electricFlux, plusPoint);
      let dMinus = fieldPhasorAtPoint(electricFlux, minusPoint);
      if (!reconstruction.two_sided
          && complexVectorMagnitude(hMinus) + complexVectorMagnitude(dMinus)
            > complexVectorMagnitude(hPlus) + complexVectorMagnitude(dPlus)) {
        [hPlus, hMinus] = [hMinus, hPlus];
        [dPlus, dMinus] = [dMinus, dPlus];
        solverNormal.multiplyScalar(-1);
      }
      const insideH = reconstruction.two_sided ? hMinus
        : { real: [0, 0, 0], imaginary: [0, 0, 0] };
      const insideD = reconstruction.two_sided ? dMinus
        : { real: [0, 0, 0], imaginary: [0, 0, 0] };
      const currentSolver = surfaceCurrent(solverNormal.toArray(), hPlus, insideH);
      const current = {
        real: transformVector(data.solver_to_user_transform, ...currentSolver.real),
        imaginary: transformVector(data.solver_to_user_transform, ...currentSolver.imaginary),
      };
      node = {
        current,
        charge: surfaceCharge(solverNormal.toArray(), dPlus, insideD),
      };
      nodeCache.set(key, node);
    }
    nodes.push(node);
    // Keep the scalar surface on the source triangulation.  Moving vertices
    // along their averaged normals visibly inflated narrow solids and opened
    // seams at sharp edges.  The material's polygon offset below resolves the
    // coplanar depth conflict without changing the displayed geometry.
    positions[base] = point[0];
    positions[base + 1] = point[1];
    positions[base + 2] = point[2];
  }
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute("position", new THREE.BufferAttribute(positions, 3));
  geometry.setAttribute("color", new THREE.BufferAttribute(colors, 3));
  geometry.computeVertexNormals();
  const material = new THREE.MeshBasicMaterial({
    vertexColors: true, side: THREE.DoubleSide, transparent: true,
    opacity: 1, depthWrite: true,
    polygonOffset: true, polygonOffsetFactor: -2, polygonOffsetUnits: -2,
  });
  const object = new THREE.Mesh(geometry, material);
  // All model materials are transparent.  Force the scalar surface to render
  // after them instead of allowing camera-depth sorting to reverse the order
  // independently for separate conductors.
  object.renderOrder = 100;
  return {
    kind: "surface-current-heatmap",
    object,
    cells: Array.from({ length: source.length / 9 }),
    nodes, colors, currentMaximum: 0, chargeMaximum: 0,
    reconstruction,
  };
}

const cyan = new THREE.Color("#3dfcff");
const magenta = new THREE.Color("#ff38d1");
const yellow = new THREE.Color("#fff45c");
function ramp(t) {
  return t < 0.5 ? cyan.clone().lerp(magenta, t * 2) : magenta.clone().lerp(yellow, (t - 0.5) * 2);
}

// Magnitudes retain the nonlinear MMANA-style antenna-pattern palette.
const signedCurrentStops = [
  [-30, new THREE.Color("#0c14b4")],
  [-20, new THREE.Color("#0064ff")],
  [-10, new THREE.Color("#00e6ff")],
  [-6, new THREE.Color("#00ee5f")],
  [-3, new THREE.Color("#ebff12")],
  [-1.5, new THREE.Color("#ffc012")],
  [-0.5, new THREE.Color("#ff3a12")],
  [0, new THREE.Color("#ff14cd")],
];

// Signed quantities need equal perceptual range on both sides of zero.  A
// single split MMANA ramp gave the negative half only several similar blues.
// These two MMANA-derived branches share a dark zero and use the same stops.
// The 1.5 power curve expands contrast among the moderate-to-strong values
// without pretending that the underlying field itself is logarithmic.
const signedNegativeStops = [
  [0, new THREE.Color("#11162c")],
  [0.32, new THREE.Color("#16436f")],
  [0.68, new THREE.Color("#0064ff")],
  [1, new THREE.Color("#00e6ff")],
];
const signedPositiveStops = [
  [0, new THREE.Color("#11162c")],
  [0.32, new THREE.Color("#6d351c")],
  [0.68, new THREE.Color("#ff9b2f")],
  [1, new THREE.Color("#fff45c")],
];

function interpolateStops(stops, value) {
  for (let index = 1; index < stops.length; ++index) {
    const [upperValue, upperColor] = stops[index];
    if (value <= upperValue) {
      const [lowerValue, lowerColor] = stops[index - 1];
      return lowerColor.clone().lerp(
        upperColor, (value - lowerValue) / (upperValue - lowerValue));
    }
  }
  return stops.at(-1)[1].clone();
}

function signedCurrentRamp(value) {
  const clipped = Math.max(-1, Math.min(1, value));
  const magnitude = Math.pow(Math.abs(clipped), 1.5);
  return interpolateStops(
    clipped < 0 ? signedNegativeStops : signedPositiveStops, magnitude);
}

function magnitudeCurrentRamp(value) {
  const paletteValue = -30 + 30 * Math.max(0, Math.min(1, value));
  for (let index = 1; index < signedCurrentStops.length; ++index) {
    const [upperValue, upperColor] = signedCurrentStops[index];
    if (paletteValue <= upperValue) {
      const [lowerValue, lowerColor] = signedCurrentStops[index - 1];
      return lowerColor.clone().lerp(
        upperColor, (paletteValue - lowerValue) / (upperValue - lowerValue));
    }
  }
  return signedCurrentStops.at(-1)[1].clone();
}

const electricMagnitudeStops = [
  [0, new THREE.Color("#100827")],
  [0.25, new THREE.Color("#6d167d")],
  [0.52, new THREE.Color("#ff27ad")],
  [0.76, new THREE.Color("#ff6b1a")],
  [1, new THREE.Color("#fff45c")],
];
const magneticMagnitudeStops = [
  [0, new THREE.Color("#06172f")],
  [0.25, new THREE.Color("#0757be")],
  [0.52, new THREE.Color("#00d9ff")],
  [0.76, new THREE.Color("#18ed9b")],
  [1, new THREE.Color("#eaff8a")],
];
const powerMagnitudeStops = [
  [0, new THREE.Color("#07111e")],
  [0.22, new THREE.Color("#2850a8")],
  [0.48, new THREE.Color("#00d9ff")],
  [0.72, new THREE.Color("#66ef73")],
  [0.88, new THREE.Color("#fff45c")],
  [1, new THREE.Color("#ff5538")],
];
const electricNegativeStops = [
  [0, new THREE.Color("#111225")],
  [0.45, new THREE.Color("#5f167e")],
  [1, new THREE.Color("#ff38d1")],
];
const electricPositiveStops = [
  [0, new THREE.Color("#111225")],
  [0.45, new THREE.Color("#a43b24")],
  [1, new THREE.Color("#fff45c")],
];
const magneticNegativeStops = [
  [0, new THREE.Color("#0b1725")],
  [0.45, new THREE.Color("#0757be")],
  [1, new THREE.Color("#00d9ff")],
];
const magneticPositiveStops = [
  [0, new THREE.Color("#0b1725")],
  [0.45, new THREE.Color("#078b70")],
  [1, new THREE.Color("#eaff8a")],
];

function fieldMagnitudeRamp(quantity, value) {
  return interpolateStops(
    quantity === "power" ? powerMagnitudeStops
      : quantity === "electric" ? electricMagnitudeStops : magneticMagnitudeStops,
    Math.max(0, Math.min(1, value)));
}

function fieldSignedRamp(quantity, value) {
  const clipped = Math.max(-1, Math.min(1, value));
  const magnitude = Math.pow(Math.abs(clipped), 1.25);
  const stops = quantity === "electric" || quantity === "power"
    ? (clipped < 0 ? electricNegativeStops : electricPositiveStops)
    : (clipped < 0 ? magneticNegativeStops : magneticPositiveStops);
  return interpolateStops(stops, magnitude);
}

function scaledMagnitude(magnitude, maximum) {
  const normalized = magnitude / Math.max(maximum, Number.EPSILON);
  if (fieldScale === "linear") return Math.max(0, Math.min(1, normalized));
  const decibels = 20 * Math.log10(Math.max(normalized, Number.EPSILON));
  return Math.max(0, Math.min(1, (decibels - logFloor) / -logFloor));
}

function scaledSigned(value, maximum) {
  const normalized = value / Math.max(maximum, Number.EPSILON);
  if (fieldScale === "linear") return Math.max(-1, Math.min(1, normalized));
  const sign = Math.sign(normalized);
  const decibels = 20 * Math.log10(Math.max(Math.abs(normalized), Number.EPSILON));
  return sign * Math.max(0, Math.min(1, (decibels - logFloor) / -logFloor));
}

function engineering(value) {
  if (!Number.isFinite(value)) return "—";
  const magnitude = Math.abs(value);
  const prefixes = [[1e9, "G"], [1e6, "M"], [1e3, "k"], [1, ""],
    [1e-3, "m"], [1e-6, "µ"], [1e-9, "n"], [1e-12, "p"]];
  const [scale, prefix] = prefixes.find(([candidate]) => magnitude >= candidate)
    ?? [1e-12, "p"];
  return `${(value / scale).toPrecision(3)} ${prefix}`;
}

function updateFieldLegend(maximum, signed) {
  fieldLegend.hidden = false;
  const quantity = fieldQuantity === "power" ? "power" : active.loaded.capture.quantity;
  const bar = fieldLegend.querySelector(".legend-bar");
  if (signed) {
    const negative = quantity === "magnetic" ? "#00d9ff" : "#ff38d1";
    const positive = quantity === "magnetic" ? "#eaff8a" : "#fff45c";
    bar.style.background = `linear-gradient(90deg,${negative},#11162c 50%,${positive})`;
    fieldLegend.querySelector(".legend-low").textContent = `−${engineering(maximum)}`;
    fieldLegend.querySelector(".legend-mid").textContent = "0";
  } else {
    bar.style.background = quantity === "electric"
      ? "linear-gradient(90deg,#100827,#6d167d,#ff27ad,#ff6b1a,#fff45c)"
      : quantity === "magnetic"
        ? "linear-gradient(90deg,#06172f,#0757be,#00d9ff,#18ed9b,#eaff8a)"
        : "linear-gradient(90deg,#07111e,#2850a8,#00d9ff,#66ef73,#fff45c,#ff5538)";
    fieldLegend.querySelector(".legend-low").textContent = fieldScale === "log"
      ? `${logFloor} dB` : "0";
    fieldLegend.querySelector(".legend-mid").textContent = "";
  }
  fieldLegend.querySelector(".legend-high").textContent = engineering(maximum);
  fieldLegend.querySelector(".legend-units").textContent = fieldQuantity === "power"
    ? "W/m²" : active.loaded.capture.units;
}

function updateCurrentLegend() {
  currentLegend.hidden = active.kind !== "current-group";
  if (currentLegend.hidden) return;
  const bar = currentLegend.querySelector(".legend-bar");
  const low = currentLegend.querySelector(".legend-low");
  const middle = currentLegend.querySelector(".legend-mid");
  const high = currentLegend.querySelector(".legend-high");
  const units = currentLegend.querySelector(".legend-units");
  if (currentMode === "magnitude"
      || (currentMode === "direction" && active.hasSurfaceItems)) {
    bar.style.background = "linear-gradient(90deg,#0c14b4,#0064ff,#00e6ff,#00ee5f,#ebff12,#ffc012,#ff3a12,#ff14cd)";
    low.textContent = currentScale === "log" ? `${currentLogFloor} dB` : "0";
    middle.textContent = "";
    high.textContent = engineering(active.items[0].currentMaximum);
    units.textContent = active.currentUnits;
  } else {
    bar.style.background = "linear-gradient(90deg,#00e6ff,#11162c 50%,#fff45c)";
    const maximum = currentMode === "charge"
      ? active.items[0].chargeMaximum : active.items[0].currentMaximum;
    low.textContent = currentScale === "log"
      ? `−${engineering(maximum)} (${currentLogFloor} dB)`
      : `−${engineering(maximum)}`;
    middle.textContent = "0";
    high.textContent = engineering(maximum);
    units.textContent = currentMode === "charge" ? "C/m²" : active.currentUnits;
  }
}

function currentDetail() {
  const base = `${active.frequencyMHz.toFixed(4)} MHz · ${active.conductorCount} conductors · ${active.cellCount.toLocaleString()} cells`;
  if (currentMode === "magnitude")
    return `${base} · |surface current phasor| · phase-independent · ${currentScale}`
      + `${currentScale === "log" ? ` (${currentLogFloor} dB floor)` : ""} · ${active.currentUnits}`;
  if (currentMode === "direction") {
    if (active.hasSurfaceItems)
      return `${base} · instantaneous |surface current| on triangulated conductors; signed longitudinal current on sheets · ${currentScale} · ${active.currentUnits}`;
    const axes = [...new Set(active.items.map(item => "xyz"[item.dominantComponent]))];
    return `${base} · signed current direction (${axes.map(axis => `J${axis}`).join("/")}) · bipolar γ1.5 · animated · ${active.currentUnits}`;
  }
  return `${base} · free surface charge (normal D jump) · bipolar ${currentScale}`
    + `${currentScale === "log" ? ` (${currentLogFloor} dB floor)` : ""} · animated · C/m²`;
}

function updateCapture() {
  if (!active) return;
  if (active.kind === "current-group")
    for (const item of active.items) updateCurrentHeatmap(item);
  else updateFieldDisplay();
  updateCurrentLegend();
  if (currentOverlay)
    for (const item of currentOverlay.items) updateCurrentHeatmap(item);
  document.getElementById("capture-detail").textContent =
    active.kind === "current-group" ? currentDetail() : fieldDetail();
  document.getElementById("phase-value").textContent = `${phaseDegrees.toFixed(0)}°`;
  document.getElementById("phase").value = String(phaseDegrees);
  const phaseRelevant = active.kind === "current-group"
    ? currentMode !== "magnitude" : !staticFieldMode();
  document.getElementById("play").disabled = !phaseRelevant;
  document.getElementById("phase").disabled = !phaseRelevant;
}

function fieldDetail() {
  const { capture } = active.loaded;
  const quantity = fieldQuantity === "power" ? "S"
    : capture.quantity === "electric" ? "E" : "H";
  const powerLabels = {
    "power-average-magnitude": "time-average |S|",
    "power-average-normal": "time-average signed through-plane S",
    "power-average-vectors": "time-average power vectors",
    "power-average-streamlines": "time-average power-flow lines",
    "power-instantaneous-magnitude": "instantaneous |E(t) × H(t)|",
    "power-instantaneous-normal": "instantaneous signed through-plane power",
    "power-instantaneous-vectors": "instantaneous power vectors",
    "power-instantaneous-streamlines": "instantaneous power-flow lines",
  };
  const mode = fieldQuantity === "power" ? powerLabels[fieldMode]
    : fieldMode === "tangent-instantaneous"
    ? `instantaneous |tangent(${quantity})|`
    : fieldMode === "streamlines" ? `instantaneous tangent(${quantity}) field lines`
    : fieldMode === "tangent-magnitude" ? `|tangent(${quantity})| envelope (static)`
    : fieldMode === "tangent-vectors" ? `instantaneous tangent(${quantity}) vectors`
      : fieldMode === "magnitude" ? `|${quantity}| envelope (static)`
        : fieldMode === "vectors" ? `instantaneous 3D ${quantity} vectors`
          : `instantaneous ${fieldMode === "normal" ? "normal" : fieldMode} component`;
  const signed = !magnitudeFieldMode();
  const transfer = fieldScale === "log"
    ? (signed ? "symlog" : "log") : "linear";
  const scale = ` · ${signed ? "bipolar " : ""}${transfer}`
    + `${fieldScale === "log" ? ` (${logFloor} dB floor)` : ""}`;
  const range = fieldRange === "slice" ? " · slice-auto p98 range" : " · volume range";
  const location = active.volume
    ? ` · ${sliceAxis.toUpperCase()}=${(active.userPosition * 1000).toFixed(3)} mm`
      + ` · ${active.loaded.nx}×${active.loaded.ny}×${active.loaded.nz} voxels`
    : "";
  document.getElementById("slice-position-value").textContent = active.volume
    ? `${(active.userPosition * 1000).toFixed(3)} mm` : "";
  const units = fieldQuantity === "power" ? "W/m²" : capture.units;
  const integral = fieldQuantity === "power"
    ? ` · sampled ∬<S>·+${sliceAxis.toUpperCase()} dA ≈ ${formatPower(integratedAveragePower())}`
    : "";
  return `${capture.frequency_mhz.toFixed(4)} MHz · ${capture.source}${location} · ${mode}${scale}${range}${integral} · ${units}`;
}

function formatPower(watts) {
  const magnitude = Math.abs(watts);
  if (magnitude >= 1) return `${watts.toPrecision(4)} W`;
  if (magnitude >= 1e-3) return `${(watts * 1e3).toPrecision(4)} mW`;
  if (magnitude >= 1e-6) return `${(watts * 1e6).toPrecision(4)} µW`;
  return `${watts.toExponential(3)} W`;
}

function integratedAveragePower() {
  if (active.integratedAveragePower !== undefined)
    return active.integratedAveragePower;
  const [axisA, axisB] = active.varyingAxes;
  const dimensions = active.dimensions;
  const coordinates = active.coordinates;
  let watts = 0;
  for (let a = 0; a < dimensions[axisA] - 1; ++a) {
    const middleA = (coordinates[axisA][a] + coordinates[axisA][a + 1]) / 2;
    if (data.pml?.enabled
        && (middleA < data.pml.inner_min[axisA]
          || middleA > data.pml.inner_max[axisA])) continue;
    for (let b = 0; b < dimensions[axisB] - 1; ++b) {
      const middleB = (coordinates[axisB][b] + coordinates[axisB][b + 1]) / 2;
      if (data.pml?.enabled
          && (middleB < data.pml.inner_min[axisB]
            || middleB > data.pml.inner_max[axisB])) continue;
      let normalPower = 0;
      for (const [da, db] of [[0, 0], [1, 0], [1, 1], [0, 1]]) {
        const indices = [0, 0, 0];
        indices[axisA] = a + da;
        indices[axisB] = b + db;
        const sample = sampleReference(active.loaded, indices, active.normalAxis,
          active.lower, active.upper, active.mix);
        normalPower += poyntingVector(sample, false).dot(active.normalVector) / 4;
      }
      const area = Math.abs(coordinates[axisA][a + 1] - coordinates[axisA][a])
        * Math.abs(coordinates[axisB][b + 1] - coordinates[axisB][b]);
      watts += normalPower * area;
    }
  }
  active.integratedAveragePower = watts;
  return watts;
}

function currentScaledMagnitude(value, maximum) {
  const normalized = value / Math.max(maximum, Number.EPSILON);
  if (currentScale === "linear") return Math.max(0, Math.min(1, normalized));
  const decibels = 20 * Math.log10(Math.max(normalized, Number.EPSILON));
  return Math.max(0, Math.min(1,
    (decibels - currentLogFloor) / -currentLogFloor));
}

function currentScaledSigned(value, maximum) {
  const normalized = value / Math.max(maximum, Number.EPSILON);
  if (currentScale === "linear") return Math.max(-1, Math.min(1, normalized));
  const sign = Math.sign(normalized);
  const decibels = 20 * Math.log10(Math.max(Math.abs(normalized), Number.EPSILON));
  return sign * Math.max(0, Math.min(1,
    (decibels - currentLogFloor) / -currentLogFloor));
}

function updateSurfaceHeatmap(item, cosine, sine) {
  for (let vertex = 0; vertex < item.nodes.length; ++vertex) {
    const node = item.nodes[vertex];
    let color;
    if (currentMode === "magnitude") {
      color = magnitudeCurrentRamp(currentScaledMagnitude(
        complexVectorMagnitude(node.current), item.currentMaximum));
    } else if (currentMode === "direction") {
      const instantaneous = instantaneousVector(node.current, Math.atan2(sine, cosine));
      color = magnitudeCurrentRamp(currentScaledMagnitude(
        Math.hypot(...instantaneous), item.currentMaximum));
    } else {
      const charge = node.charge.real * cosine - node.charge.imaginary * sine;
      color = signedCurrentRamp(currentScaledSigned(charge, item.chargeMaximum));
    }
    item.colors.set([color.r, color.g, color.b], vertex * 3);
  }
  item.object.geometry.attributes.color.needsUpdate = true;
}

function updateCurrentHeatmap(item) {
  const phase = THREE.MathUtils.degToRad(phaseDegrees);
  const cosine = Math.cos(phase), sine = Math.sin(phase);
  if (item.kind === "surface-current-heatmap") {
    updateSurfaceHeatmap(item, cosine, sine);
    return;
  }
  for (let cell = 0; cell < item.cells.length; ++cell) {
    const colorOffset = cell * 18;
    for (let vertex = 0; vertex < 6; ++vertex) {
      const node = item.nodes.get(item.cells[cell].vertexStations[vertex]);
      let color;
      if (currentMode === "magnitude") {
        color = magnitudeCurrentRamp(
          currentScaledMagnitude(Math.hypot(node.real, node.imaginary),
            item.currentMaximum));
      } else if (currentMode === "direction") {
        const signedCurrent = node.real * cosine - node.imaginary * sine;
        color = item.mixedSurfaceGroup
          ? magnitudeCurrentRamp(currentScaledMagnitude(
            Math.abs(signedCurrent), item.currentMaximum))
          : signedCurrentRamp(
            currentScaledSigned(signedCurrent, item.currentMaximum));
      } else {
        const charge = item.chargeNodes.get(item.cells[cell].vertexStations[vertex]);
        const signedCharge = charge.real * cosine - charge.imaginary * sine;
        color = signedCurrentRamp(
          currentScaledSigned(signedCharge, item.chargeMaximum));
      }
      item.colors.set([color.r, color.g, color.b], colorOffset + vertex * 3);
    }
  }
  item.object.geometry.attributes.color.needsUpdate = true;
}

function interpolatedValue(array, offset, sample) {
  return array[offset + sample.lower] * (1 - sample.mix)
    + array[offset + sample.upper] * sample.mix;
}

function userFieldPhasor(loaded, sample) {
  const real = [], imaginary = [];
  for (let component = 0; component < 3; ++component) {
    const offset = loaded.sampleCount * component;
    real.push(interpolatedValue(loaded.userReal, offset, sample));
    imaginary.push(interpolatedValue(loaded.userImaginary, offset, sample));
  }
  return { real, imaginary };
}

function poyntingVector(sample, instantaneous, cosine = 1, sine = 0) {
  const electric = userFieldPhasor(active.fields.electric, sample);
  const magnetic = userFieldPhasor(active.fields.magnetic, sample);
  const phase = Math.atan2(sine, cosine);
  return new THREE.Vector3(...(instantaneous
    ? instantaneousPoynting(electric, magnetic, phase)
    : averagePoynting(electric, magnetic)));
}

function powerModeInstantaneous() {
  return fieldQuantity === "power" && fieldMode.startsWith("power-instantaneous-");
}

function powerModeNormal() {
  return fieldQuantity === "power" && fieldMode.endsWith("-normal");
}

function powerModeVectors() {
  return fieldQuantity === "power" && fieldMode.endsWith("-vectors");
}

function powerModeStreamlines() {
  return fieldQuantity === "power" && fieldMode.endsWith("-streamlines");
}

function selectedComponentPhasor(sample) {
  const loaded = active.loaded;
  if (fieldMode === "normal") {
    const phasor = userFieldPhasor(loaded, sample);
    return {
      real: active.normalVector.dot(new THREE.Vector3(...phasor.real)),
      imaginary: active.normalVector.dot(new THREE.Vector3(...phasor.imaginary)),
    };
  }
  const phasor = userFieldPhasor(loaded, sample);
  const component = "xyz".indexOf(fieldMode);
  return { real: phasor.real[component], imaginary: phasor.imaginary[component] };
}

function selectedComponentMaximum() {
  const loaded = active.loaded;
  const volumeMaximum = fieldMode === "normal"
    ? loaded.componentMaximum[active.normalUserAxis]
    : loaded.componentMaximum["xyz".indexOf(fieldMode)];
  if (fieldRange === "volume") return volumeMaximum;
  const cacheKey = `component-${fieldMode}`;
  if (!active.rangeCache.has(cacheKey)) {
    const magnitudes = active.samples.map(sample => {
      const component = selectedComponentPhasor(sample);
      return Math.hypot(component.real, component.imaginary);
    });
    active.rangeCache.set(cacheKey, robustMaximum(magnitudes));
  }
  return active.rangeCache.get(cacheKey);
}

function robustMaximum(values) {
  const finite = values.filter(Number.isFinite).sort((left, right) => left - right);
  if (!finite.length) return Number.EPSILON;
  // Ignore the hottest two percent of display vertices.  PEC/feed-adjacent
  // outliers otherwise consume nearly the entire palette on radiating-field
  // planes.  This exposure is fixed for the complex phasor, not recomputed
  // from instantaneous animation frames, so it cannot flicker with phase.
  return Math.max(finite[Math.floor((finite.length - 1) * 0.98)], Number.EPSILON);
}

function magnitudeFieldMode() {
  if (fieldQuantity === "power") return !powerModeNormal();
  return ["magnitude", "vectors", "tangent-magnitude", "tangent-vectors",
    "tangent-instantaneous", "streamlines"]
    .includes(fieldMode);
}

function tangentFieldMode() {
  if (fieldQuantity === "power") return false;
  return ["tangent-magnitude", "tangent-vectors", "tangent-instantaneous",
    "streamlines"].includes(fieldMode);
}

function staticFieldMode() {
  if (fieldQuantity === "power") return !powerModeInstantaneous();
  return fieldMode === "magnitude" || fieldMode === "tangent-magnitude";
}

function phasorMagnitude(phasor, tangent = false) {
  let magnitude2 = phasor.real.reduce((sum, value, index) =>
    sum + value ** 2 + phasor.imaginary[index] ** 2, 0);
  if (tangent) {
    const normalReal = active.normalVector.dot(new THREE.Vector3(...phasor.real));
    const normalImaginary = active.normalVector.dot(
      new THREE.Vector3(...phasor.imaginary));
    magnitude2 = Math.max(0,
      magnitude2 - normalReal ** 2 - normalImaginary ** 2);
  }
  return Math.sqrt(magnitude2);
}

function magnitudeDisplayMaximum() {
  if (fieldQuantity === "power") return powerDisplayMaximum();
  const tangent = tangentFieldMode();
  if (fieldRange === "volume")
    return tangent
      ? active.loaded.tangentMaximum[active.normalUserAxis]
      : active.loaded.maximum;
  const cacheKey = tangent ? "tangent-magnitude" : "magnitude";
  if (!active.rangeCache.has(cacheKey)) {
    const magnitudes = active.samples.map(sample => {
      const phasor = userFieldPhasor(active.loaded, sample);
      return phasorMagnitude(phasor, tangent);
    });
    active.rangeCache.set(cacheKey, robustMaximum(magnitudes));
  }
  return active.rangeCache.get(cacheKey);
}

function powerDisplayMaximum() {
  const instantaneous = powerModeInstantaneous();
  const cacheKey = instantaneous ? "power-instantaneous-envelope" : "power-average";
  if (!active.rangeCache.has(cacheKey)) {
    const sampleValues = fieldRange === "slice"
      ? active.samples
      : Array.from({ length: active.loaded.sampleCount }, (_, index) =>
        ({ lower: index, upper: index, mix: 0 }));
    const magnitudes = sampleValues.map(sample => {
      if (!instantaneous) return poyntingVector(sample, false).length();
      const electric = userFieldPhasor(active.fields.electric, sample);
      const magnetic = userFieldPhasor(active.fields.magnetic, sample);
      const eEnvelope = Math.sqrt(electric.real.reduce((sum, value, index) =>
        sum + value ** 2 + electric.imaginary[index] ** 2, 0));
      const hEnvelope = Math.sqrt(magnetic.real.reduce((sum, value, index) =>
        sum + value ** 2 + magnetic.imaginary[index] ** 2, 0));
      return eEnvelope * hEnvelope;
    });
    active.rangeCache.set(cacheKey, robustMaximum(magnitudes));
  }
  return active.rangeCache.get(cacheKey);
}

function updateFieldDisplay() {
  const { loaded } = active;
  const phase = THREE.MathUtils.degToRad(phaseDegrees);
  const cosine = Math.cos(phase), sine = Math.sin(phase);
  const magnitudeMaximum = magnitudeDisplayMaximum();
  const signedMaximum = fieldQuantity === "power"
    ? magnitudeMaximum
    : magnitudeFieldMode() ? magnitudeMaximum : selectedComponentMaximum();
  updateFieldLegend(signedMaximum, !magnitudeFieldMode());
  for (let vertex = 0; vertex < active.samples.length; ++vertex) {
    const sample = active.samples[vertex];
    let magnitude;
    let color;
    if (fieldQuantity === "power") {
      const power = poyntingVector(sample, powerModeInstantaneous(), cosine, sine);
      if (powerModeNormal()) {
        color = fieldSignedRamp("power",
          scaledSigned(power.dot(active.normalVector), signedMaximum));
      } else {
        color = fieldMagnitudeRamp("power",
          scaledMagnitude(power.length(), magnitudeMaximum));
      }
    } else {
      const phasor = userFieldPhasor(loaded, sample);
      magnitude = phasorMagnitude(phasor, tangentFieldMode());
      if (fieldMode === "tangent-instantaneous") {
      const instantaneous = new THREE.Vector3(
        phasor.real[0] * cosine - phasor.imaginary[0] * sine,
        phasor.real[1] * cosine - phasor.imaginary[1] * sine,
        phasor.real[2] * cosine - phasor.imaginary[2] * sine);
      instantaneous.addScaledVector(
        active.normalVector, -instantaneous.dot(active.normalVector));
      magnitude = instantaneous.length();
      }
      if (magnitudeFieldMode()) {
        color = fieldMagnitudeRamp(loaded.capture.quantity,
          scaledMagnitude(magnitude, magnitudeMaximum));
      } else {
        const component = selectedComponentPhasor(sample);
        const instantaneous = component.real * cosine - component.imaginary * sine;
        color = fieldSignedRamp(loaded.capture.quantity,
          scaledSigned(instantaneous, signedMaximum));
      }
    }
    active.colors.set([color.r, color.g, color.b], vertex * 3);
  }
  active.plane.geometry.attributes.color.needsUpdate = true;
  const vectors = fieldMode === "vectors" || fieldMode === "tangent-vectors"
    || powerModeVectors();
  const lines = fieldMode === "streamlines" || powerModeStreamlines();
  active.plane.material.opacity = vectors || lines
    ? Math.min(fieldOpacity, 0.28) : fieldOpacity;
  active.arrows.visible = vectors;
  active.streamlines.visible = lines;
  active.pml.visible = document.getElementById("pml-visible").checked;
  if (vectors) updateFieldArrows(cosine, sine);
  if (lines) updateStreamlines(cosine, sine);
  document.getElementById("field-scale").disabled = false;
  document.getElementById("log-floor").disabled = fieldScale !== "log";
}

function updateFieldArrows(cosine, sine) {
  const { loaded } = active;
  const magnitudeMaximum = magnitudeDisplayMaximum();
  const threshold = fieldScale === "log" ? 10 ** (logFloor / 20) : 0.01;
  const color = fieldQuantity === "power" ? 0x66ef73
    : loaded.capture.quantity === "electric" ? 0xffb129 : 0x48f6ff;
  for (const { arrow, sample } of active.arrows.userData.entries) {
    let vector;
    if (fieldQuantity === "power") {
      vector = poyntingVector(sample, powerModeInstantaneous(), cosine, sine);
    } else {
      const phasor = userFieldPhasor(loaded, sample);
      vector = new THREE.Vector3(
        phasor.real[0] * cosine - phasor.imaginary[0] * sine,
        phasor.real[1] * cosine - phasor.imaginary[1] * sine,
        phasor.real[2] * cosine - phasor.imaginary[2] * sine);
    }
    if (fieldMode === "tangent-vectors")
      vector.addScaledVector(active.normalVector, -vector.dot(active.normalVector));
    const normalized = vector.length() / Math.max(magnitudeMaximum, Number.EPSILON);
    arrow.visible = normalized >= threshold;
    if (!arrow.visible) continue;
    arrow.setDirection(vector.normalize());
    const emphasis = scaledMagnitude(vector.length(), magnitudeMaximum);
    const length = diagonal * 0.018 * (0.25 + 0.75 * Math.sqrt(emphasis));
    arrow.setLength(length, length * 0.28, length * 0.16);
    arrow.setColor(color);
  }
}

function coordinateBracket(coordinates, value) {
  if (value <= coordinates[0]) return [0, 0, 0];
  if (value >= coordinates.at(-1)) {
    const last = coordinates.length - 1;
    return [last, last, 0];
  }
  let low = 0, high = coordinates.length - 1;
  while (high - low > 1) {
    const middle = Math.floor((low + high) / 2);
    if (coordinates[middle] <= value) low = middle;
    else high = middle;
  }
  return [low, high,
    (value - coordinates[low]) / (coordinates[high] - coordinates[low])];
}

function solverFieldPhasor(loaded, point) {
  const brackets = active.coordinates.map((coordinates, axis) =>
    axis === active.normalAxis
      ? [active.lower, active.upper, active.mix]
      : coordinateBracket(coordinates, point[axis]));
  const real = [0, 0, 0], imaginary = [0, 0, 0];
  for (let bx = 0; bx < 2; ++bx)
    for (let by = 0; by < 2; ++by)
      for (let bz = 0; bz < 2; ++bz) {
        const choices = [bx, by, bz];
        const indices = [0, 0, 0];
        let weight = 1;
        for (let axis = 0; axis < 3; ++axis) {
          const [lower, upper, mix] = brackets[axis];
          indices[axis] = choices[axis] ? upper : lower;
          weight *= choices[axis] ? mix : 1 - mix;
        }
        if (weight === 0) continue;
        const sample = sampleIndex(loaded, indices);
        for (let component = 0; component < 3; ++component) {
          const offset = sample + loaded.sampleCount * component;
          real[component] += weight * loaded.real[offset];
          imaginary[component] += weight * loaded.imaginary[offset];
        }
      }
  return { real, imaginary };
}

function streamlineSolverField(point, cosine, sine) {
  let result;
  if (fieldQuantity === "power") {
    const electric = solverFieldPhasor(active.fields.electric, point);
    const magnetic = solverFieldPhasor(active.fields.magnetic, point);
    if (powerModeInstantaneous()) {
      result = instantaneousPoynting(electric, magnetic, Math.atan2(sine, cosine));
    } else {
      result = averagePoynting(electric, magnetic);
    }
  } else {
    const phasor = solverFieldPhasor(active.loaded, point);
    result = phasor.real.map((value, index) =>
      value * cosine - phasor.imaginary[index] * sine);
  }
  result[active.normalAxis] = 0;
  return result;
}

function updateStreamlines(cosine, sine) {
  const [axisA, axisB] = active.varyingAxes;
  const coordinateBounds = [0, 1, 2].map(axis => {
    const coordinates = active.coordinates[axis];
    return [coordinates[0], coordinates.at(-1)];
  });
  if (data.pml?.enabled) {
    coordinateBounds[axisA] = [data.pml.inner_min[axisA], data.pml.inner_max[axisA]];
    coordinateBounds[axisB] = [data.pml.inner_min[axisB], data.pml.inner_max[axisB]];
  }
  const spanA = coordinateBounds[axisA][1] - coordinateBounds[axisA][0];
  const spanB = coordinateBounds[axisB][1] - coordinateBounds[axisB][0];
  const step = Math.min(spanA, spanB) / 75;
  const seeds = 15;
  const maximum = magnitudeDisplayMaximum();
  const threshold = maximum * (fieldScale === "log"
    ? 10 ** (logFloor / 20) : 0.02);
  const positions = [];
  const colors = [];
  const inside = point => point[axisA] >= coordinateBounds[axisA][0]
    && point[axisA] <= coordinateBounds[axisA][1]
    && point[axisB] >= coordinateBounds[axisB][0]
    && point[axisB] <= coordinateBounds[axisB][1];
  for (let seedA = 0; seedA < seeds; ++seedA)
    for (let seedB = 0; seedB < seeds; ++seedB) {
      const seed = [...active.fixedCoordinates];
      seed[axisA] = coordinateBounds[axisA][0] + spanA * (seedA + 0.5) / seeds;
      seed[axisB] = coordinateBounds[axisB][0] + spanB * (seedB + 0.5) / seeds;
      for (const direction of [-1, 1]) {
        let point = [...seed];
        for (let iteration = 0; iteration < 28; ++iteration) {
          const field = streamlineSolverField(point, cosine, sine);
          const magnitude = Math.hypot(field[axisA], field[axisB]);
          if (magnitude < threshold) break;
          const next = [...point];
          next[axisA] += direction * step * field[axisA] / magnitude;
          next[axisB] += direction * step * field[axisB] / magnitude;
          if (!inside(next)) break;
          positions.push(
            ...transformPoint(data.solver_to_user_transform, ...point),
            ...transformPoint(data.solver_to_user_transform, ...next));
          const color = fieldMagnitudeRamp(fieldQuantity === "power"
            ? "power" : active.loaded.capture.quantity,
            scaledMagnitude(magnitude, maximum));
          colors.push(color.r, color.g, color.b, color.r, color.g, color.b);
          point = next;
        }
      }
    }
  active.streamlines.geometry.setAttribute(
    "position", new THREE.Float32BufferAttribute(positions, 3));
  active.streamlines.geometry.setAttribute(
    "color", new THREE.Float32BufferAttribute(colors, 3));
  if (positions.length) active.streamlines.geometry.computeBoundingSphere();
}

function rebuildVolumeSlice() {
  if (!active?.volume) return;
  const loaded = active.loaded;
  const fields = active.fields;
  fieldGroup.remove(displayObject);
  disposeDisplay(displayObject);
  active = buildFieldDisplay(loaded, true, fields);
  displayObject = active.object;
  fieldGroup.add(displayObject);
  updateCapture();
}

captureSelect.addEventListener("change", () => loadCapture(Number(captureSelect.value)));
document.getElementById("current-mode").addEventListener("change", event => {
  currentMode = event.target.value;
  updateCapture();
});
document.getElementById("current-scale").addEventListener("change", event => {
  currentScale = event.target.value;
  document.getElementById("current-log-floor").disabled = currentScale !== "log";
  updateCapture();
});
document.getElementById("current-log-floor").addEventListener("input", event => {
  currentLogFloor = Number(event.target.value);
  document.getElementById("current-log-floor-value").textContent =
    `−${Math.abs(currentLogFloor)} dB`;
  updateCapture();
});
document.getElementById("field-quantity").addEventListener("change", event => {
  fieldQuantity = event.target.value;
  setModeOptions();
  loadCapture(Number(captureSelect.value));
});
document.getElementById("slice-axis").addEventListener("change", event => {
  sliceAxis = event.target.value;
  slicePosition = 0.5;
  document.getElementById("slice-position").value = "500";
  rebuildVolumeSlice();
});
document.getElementById("slice-position").addEventListener("input", event => {
  slicePosition = Number(event.target.value) / 1000;
  rebuildVolumeSlice();
});
document.getElementById("field-mode").addEventListener("change", event => {
  fieldMode = event.target.value;
  updateCapture();
});
document.getElementById("field-range").addEventListener("change", event => {
  fieldRange = event.target.value;
  updateCapture();
});
document.getElementById("field-scale").addEventListener("change", event => {
  fieldScale = event.target.value;
  updateCapture();
});
document.getElementById("log-floor").addEventListener("input", event => {
  logFloor = Number(event.target.value);
  document.getElementById("log-floor-value").textContent = `−${Math.abs(logFloor)} dB`;
  updateCapture();
});
document.getElementById("field-opacity").addEventListener("input", event => {
  fieldOpacity = Number(event.target.value);
  updateCapture();
});
document.getElementById("pml-visible").addEventListener("change", () => updateCapture());
document.getElementById("current-overlay").addEventListener("change", async event => {
  if (event.target.checked) {
    await showCurrentOverlay();
    updateCapture();
  } else if (currentOverlay) {
    fieldGroup.remove(currentOverlay.object);
    disposeDisplay(currentOverlay.object);
    currentOverlay = null;
  }
});
document.getElementById("play").addEventListener("click", event => {
  playing = !playing;
  event.currentTarget.textContent = playing ? "PAUSE" : "PLAY";
});
document.getElementById("phase").addEventListener("input", event => {
  phaseDegrees = Number(event.target.value);
  playing = false;
  document.getElementById("play").textContent = "PLAY";
  updateCapture();
});
document.getElementById("speed").addEventListener("input", event => {
  speed = Number(event.target.value);
  document.getElementById("speed-value").textContent = `${speed.toFixed(2)}×`;
});
document.getElementById("model-visible").addEventListener("change", event => modelGroup.visible = event.target.checked);
document.getElementById("field-visible").addEventListener("change", event => fieldGroup.visible = event.target.checked);

function resize() {
  const width = canvas.clientWidth, height = canvas.clientHeight;
  if (canvas.width !== width * renderer.getPixelRatio() || canvas.height !== height * renderer.getPixelRatio()) {
    renderer.setSize(width, height, false);
    camera.aspect = width / height;
    camera.updateProjectionMatrix();
  }
}

function animate(now) {
  requestAnimationFrame(animate);
  const elapsed = Math.min(0.1, (now - priorTime) / 1000);
  priorTime = now;
  const phaseRelevant = active?.kind === "current-group"
    ? currentMode !== "magnitude" : active && !staticFieldMode();
  if (playing && phaseRelevant) {
    phaseDegrees = (phaseDegrees + elapsed * 90 * speed) % 360;
    updateCapture();
  }
  resize();
  controls.update();
  renderer.render(scene, camera);
}

document.getElementById("title").textContent = data.metadata.title;
document.getElementById("subtitle").textContent = data.metadata.subtitle;
document.getElementById("metadata").textContent = JSON.stringify(data.metadata, null, 2);
if (data.captures.length) await loadCapture(0);
document.documentElement.dataset.reportReady = "true";
requestAnimationFrame(animate);
}

main().catch(error => {
  document.documentElement.dataset.reportReady = "error";
  document.getElementById("capture-detail").textContent = `REPORT ERROR: ${error.message}`;
  console.error(error);
});
