import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { createPlotWorkspace, Plotly } from "./plot-workspace.js";
import { makeCollapsibleSettingsPanel } from "./panel-collapse.js";
import {
  componentGainRange,
  gainOf,
  globalGainRange,
  interpolatedGain,
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
  for (const wire of data.geometry.wires) {
    authoredBounds.expandByPoint(new THREE.Vector3(...wire.start));
    authoredBounds.expandByPoint(new THREE.Vector3(...wire.end));
  }
  const presentationRadius = Math.max(
    authoredBounds.getSize(new THREE.Vector3()).length() * 0.0012, 1e-7);
  const material = new THREE.MeshStandardMaterial({
    color: 0x8eeaff, metalness: 0.72, roughness: 0.25,
    emissive: 0x073b4d, emissiveIntensity: 0.45,
    depthTest: false,
  });
  const feedMaterial = new THREE.MeshStandardMaterial({
    color: 0xff42d0, emissive: 0xff1498, emissiveIntensity: 1.2,
    depthTest: false,
  });
  for (const wire of data.geometry.wires) {
    const radius = Math.max(wire.diameter / 2, presentationRadius);
    const conductor = cylinderBetween(wire.start, wire.end, radius, material);
    conductor.renderOrder = 3;
    group.add(conductor);
    if (wire.feed) {
      const point = new THREE.Vector3(...wire.start).lerp(new THREE.Vector3(...wire.end), wire.feed.fraction);
      const marker = new THREE.Mesh(
        new THREE.SphereGeometry(radius * 2.8, 18, 10), feedMaterial);
      marker.position.copy(point);
      marker.renderOrder = 4;
      group.add(marker);
    }
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
    #pattern-legend{margin-top:10px}.pattern-legend-bar{height:12px;border:1px solid #78edff;
      border-radius:2px;box-shadow:0 0 8px #00d9ff25}
    .pattern-legend-scale{display:grid;grid-template-columns:46px 1fr;margin-top:4px;
      color:#d8fbff;font-size:10px}.pattern-legend-scale>span:first-child{color:#8beeff}
    .pattern-legend-ticks{display:flex;justify-content:space-between}
    #nec-controls[hidden],#pattern-2d[hidden],#viewport[hidden]{display:none}
    #pattern-2d{position:fixed;z-index:3;inset:78px 20px 18px}
    #pattern-2d .pattern-toolbar{position:absolute;z-index:2;left:10px;right:10px;top:0;
      display:flex;align-items:center;gap:10px;padding:9px 12px}
    #pattern-2d .pattern-toolbar input[type=range]{flex:1}
    #pattern-polar{position:absolute;inset:58px 0 0;border:1px solid #31efff44}
    #plots-workspace{position:fixed;z-index:3;inset:78px 20px 18px}
    #plots-workspace[hidden]{display:none}.plot-toolbar{position:absolute;z-index:2;left:10px;right:10px;
      top:0;display:flex;align-items:center;gap:10px;padding:9px 12px}
    .plot-toolbar #plot-frequency-note{margin-left:auto;color:#fff45c;font-size:10px}
    #plot-hover-readout{position:absolute;z-index:2;left:10px;right:10px;top:58px;height:38px;
      display:flex;align-items:center;padding:0 12px;border:1px solid #31efff44;
      background:#07101ddd;color:#d8fbff;font-size:10px;white-space:nowrap;overflow:auto}
    #network-plot{position:absolute;inset:102px 0 0;border:1px solid #31efff44}
    #network-plot .hoverlayer .hovertext,#network-plot .hoverlayer .axistext{display:none!important}
    @media(max-width:820px){#nec-tabs{top:8px;right:8px;max-width:calc(100vw - 16px);flex-wrap:wrap}
      #nec-tabs button{min-width:auto}#pattern-2d,#plots-workspace{inset:92px 8px 8px}}
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
  addGeometry(data, geometryGroup);
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
    <div class="row"><label for="pattern-opacity">PATTERN OPACITY
    <span id="pattern-opacity-value" class="opacity-value">100%</span></label>
    <input id="pattern-opacity" type="range" min="0.1" max="1" step="0.05" value="1"></div>
    <div class="row"><label><input id="model-visible" type="checkbox" checked> MODEL</label>
    <label><input id="pattern-visible" type="checkbox" checked> PATTERN</label>
    <label><input id="axes-visible" type="checkbox" checked> AXES</label>
    <button id="reset-view" type="button">RESET VIEW</button></div>
    <div class="row"><label><input id="color-bands" type="checkbox"> 3 dB COLOR BANDS</label></div>
    <div id="pattern-legend"><div class="pattern-legend-bar"></div>
    <div class="pattern-legend-scale"><span>REL</span><div class="pattern-legend-ticks" data-scale="relative"></div></div>
    <div class="pattern-legend-scale"><span>dBi</span><div class="pattern-legend-ticks" data-scale="absolute"></div></div></div>
    <div id="pattern-detail"></div><div style="font-size:10px;color:#9ceeff;margin-top:4px">
    XYZ: <span style="color:#ff5555">X boom</span> · <span style="color:#55ff55">Y elements</span> ·
    <span style="color:#6688ff">Z vertical</span></div>`;
  document.body.append(controlsPanel);
  makeCollapsibleSettingsPanel(controlsPanel);
  const componentSelect = controlsPanel.querySelector("#pattern-component");
  const scaleSelect = controlsPanel.querySelector("#pattern-scale");
  const paletteSelect = controlsPanel.querySelector("#pattern-palette");
  const opacitySlider = controlsPanel.querySelector("#pattern-opacity");
  const colorBands = controlsPanel.querySelector("#color-bands");
  let patternMaterial = null;

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
  rebuildPattern();

  const polarWorkspace = document.createElement("section");
  polarWorkspace.id = "pattern-2d";
  polarWorkspace.hidden = true;
  const minimumElevation = 90 - data.pattern.theta_values.at(-1);
  const maximumElevation = 90 - data.pattern.theta_values[0];
  polarWorkspace.innerHTML = `<div class="pattern-toolbar panel"><label for="cut-elevation">ELEVATION</label>
    <input id="cut-elevation" type="range" min="${minimumElevation}" max="${maximumElevation}" step="1" value="0">
    <span id="cut-elevation-value">0°</span><label for="cut-component">COMPONENT</label>
    <select id="cut-component"><option value="total">total</option><option value="vertical">vertical (Eθ)</option>
    <option value="horizontal">horizontal (Eφ)</option></select><label for="cut-reference">DISPLAY</label>
    <select id="cut-reference"><option value="relative">relative</option><option value="absolute">absolute dBi</option></select>
    </div><div id="pattern-polar"></div>`;
  document.body.append(polarWorkspace);
  const elevationSlider = polarWorkspace.querySelector("#cut-elevation");
  if (minimumElevation > 0) elevationSlider.value = minimumElevation;

  function drawPolar() {
    const elevation = Number(elevationSlider.value);
    const component = polarWorkspace.querySelector("#cut-component").value;
    const absolute = polarWorkspace.querySelector("#cut-reference").value === "absolute";
    const angles = Array.from({ length: 361 }, (_, index) => index);
    const gains = angles.map(angle => interpolatedGain(data.pattern, table, elevation, angle, component));
    const globalRange = componentGainRange(data.pattern, component);
    const shown = absolute ? gains : gains.map(gain => gain - globalRange.referencePeak);
    const radialRange = absolute
      ? [Math.floor(globalRange.minimum / 10) * 10, Math.ceil(globalRange.referencePeak / 10) * 10]
      : [Math.floor(globalRange.relativeMinimum / 10) * 10, 0];
    const displayScale = polarDisplayScale(shown, radialRange);
    polarWorkspace.querySelector("#cut-elevation-value").textContent = `${elevation}°`;
    return Plotly.react(polarWorkspace.querySelector("#pattern-polar"), [{
      type: "scatterpolar", mode: "lines", theta: angles, r: displayScale.radius,
      line: { color: "#39efff", width: 3 }, name: component,
      customdata: gains.map((gain, index) => [gain, shown[index]]),
      hovertemplate: `azimuth %{theta:.1f}°<br>${absolute ? "gain" : "relative"} %{customdata[1]:.3f} dB` +
        `<br>absolute %{customdata[0]:.3f} dBi<extra>${elevation}° elevation</extra>`,
    }], {
      title: { text: `Azimuth pattern · ${elevation}° elevation · ${component}`,
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
  elevationSlider.addEventListener("input", drawPolar);
  polarWorkspace.querySelector("#cut-component").addEventListener("change", drawPolar);
  polarWorkspace.querySelector("#cut-reference").addEventListener("change", drawPolar);

  const plotWorkspace = createPlotWorkspace(data, { managedNavigation: false });
  const tabs = document.createElement("nav");
  tabs.id = "nec-tabs";
  tabs.innerHTML = `<button data-view="viewer3d" class="active">3D VIEW</button>
    <button data-view="plots">PLOTS</button><button data-view="pattern2d">2D PATTERN</button>`;
  document.body.append(tabs);
  let activeView = "viewer3d";
  function show(view) {
    activeView = view;
    const canvasView = view === "viewer3d";
    canvas.hidden = !canvasView;
    controlsPanel.hidden = !canvasView;
    polarWorkspace.hidden = view !== "pattern2d";
    if (plotWorkspace) view === "plots" ? plotWorkspace.show() : plotWorkspace.hide();
    document.getElementById("metadata-panel").hidden = !canvasView;
    tabs.querySelectorAll("button").forEach(button => button.classList.toggle("active", button.dataset.view === view));
    if (canvasView) fitCamera(camera, controls, scene);
    if (view === "pattern2d") drawPolar().then(() => Plotly.Plots.resize(polarWorkspace.querySelector("#pattern-polar")));
    history.replaceState(null, "", `#${view}`);
  }
  tabs.addEventListener("click", event => {
    const button = event.target.closest("button[data-view]");
    if (button) show(button.dataset.view);
  });

  const requestedHash = location.hash.slice(1);
  const requested = ["geometry", "pattern3d"].includes(requestedHash) ? "viewer3d" : requestedHash;
  show(["viewer3d", "plots", "pattern2d"].includes(requested) ? requested : "viewer3d");

  function animate() {
    requestAnimationFrame(animate);
    if (activeView !== "viewer3d") return;
    const width = canvas.clientWidth, height = canvas.clientHeight;
    if (canvas.width !== width * renderer.getPixelRatio() || canvas.height !== height * renderer.getPixelRatio()) {
      renderer.setSize(width, height, false); camera.aspect = width / height; camera.updateProjectionMatrix();
    }
    controls.update(); renderer.render(scene, camera);
  }
  document.documentElement.dataset.reportReady = "true";
  requestAnimationFrame(animate);
}
