/*! Plotly.js 4.1.1 | MIT License
 * Copyright (c) 2016-2024 Plotly Technologies Inc.
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */
import Plotly from "plotly.js/lib/core";
import scatter from "plotly.js/lib/scatter";
import scatterSmith from "plotly.js/lib/scattersmith";
import {
  availablePlots,
  interpolatePortSamples,
  nearestSample,
  normalizedImpedance,
  portNames,
  returnLoss,
  samplesForPort,
  sParameterGroups,
  vswr,
  vswrAxisRange,
} from "./plot-data.js";

Plotly.register([scatter, scatterSmith]);

const colors = ["#39efff", "#ff3bd4", "#fff45c", "#6aff9b", "#ff765d", "#9c78ff"];
const smithTicks = [0.1, 0.2, 0.3, 0.5, 0.7, 1, 1.5, 2, 3, 5, 10];

function cartesianLayout(title, yTitle, extra = {}) {
  const axis = {
    color: "#9ceeff",
    gridcolor: "#17445c",
    zerolinecolor: "#2b7890",
    linecolor: "#31efff",
    tickfont: { color: "#9ceeff" },
    titlefont: { color: "#9ceeff" },
  };
  return {
    title: { text: title, font: { color: "#7df9ff", size: 19 }, x: 0.02 },
    paper_bgcolor: "rgba(3,6,17,0)",
    plot_bgcolor: "rgba(5,14,29,.78)",
    font: { family: '"DejaVu Sans Mono", monospace', color: "#d8fbff" },
    margin: { l: 76, r: 35, t: 62, b: 68 },
    hovermode: "x unified",
    legend: { bgcolor: "rgba(3,6,17,.72)", bordercolor: "#238aa0", borderwidth: 1 },
    xaxis: { ...axis, title: { text: "frequency (MHz)", font: axis.titlefont } },
    yaxis: { ...axis, title: { text: yTitle, font: axis.titlefont } },
    ...extra,
  };
}

function withFrequencyCursor(layout, frequencyMHz) {
  if (!Number.isFinite(frequencyMHz)) return layout;
  return {
    ...layout,
    shapes: [{
      type: "line", xref: "x", yref: "paper",
      x0: frequencyMHz, x1: frequencyMHz, y0: 0, y1: 1,
      line: { color: "#ff3bd4", width: 1.5, dash: "dot" },
    }],
  };
}

function lineTrace(name, samples, value, color, suffix = "") {
  return {
    type: "scatter",
    mode: "lines",
    name,
    x: samples.map(sample => sample.frequency_mhz),
    y: samples.map(value),
    customdata: samples.map(sample => sample.interpolated ? "≈ interpolated" : "solver sample"),
    line: { color, width: 2.5 },
    hovertemplate: `%{x:.6g} MHz<br>%{y:.5g}${suffix}<br>%{customdata}<extra>${name}</extra>`,
  };
}

function finiteVswr(sample) {
  const value = vswr(sample);
  return Number.isFinite(value) ? value : null;
}

function tracesAndLayout(kind, measurements, portName, selectedFrequency) {
  const solverSamples = samplesForPort(measurements, portName);
  const reference = measurements.ports?.find(port => String(port.name) === portName)
    ?.reference_impedance_ohms;
  const samples = interpolatePortSamples(solverSamples, reference);
  if (kind === "smith") {
    const normalized = samples.map(sample => normalizedImpedance(sample, reference));
    const trace = {
      type: "scattersmith",
      mode: "lines",
      name: portName,
      real: normalized.map(impedance => impedance.real),
      imag: normalized.map(impedance => impedance.imaginary),
      text: samples.map(sample => `${sample.frequency_mhz.toPrecision(6)} MHz`),
      customdata: samples.map(sample => [
        sample.frequency_mhz,
        sample.impedance_ohms.real,
        sample.impedance_ohms.imaginary,
        sample.reflection_coefficient.real,
        sample.reflection_coefficient.imaginary,
        sample.interpolated ? "≈ interpolated" : "solver sample",
      ]),
      line: { color: colors[0], width: 3 },
      hovertemplate: "%{text}<br>Z=%{customdata[1]:.5g}%{customdata[2]:+.5g}j Ω" +
        "<br>z=%{real:.5g}%{imag:+.5g}j<br>Γ=%{customdata[3]:.5g}%{customdata[4]:+.5g}j" +
        "<br>%{customdata[5]}<extra></extra>",
    };
    const selected = nearestSample(samples, selectedFrequency);
    const solverNormalized = solverSamples.map(sample => normalizedImpedance(sample, reference));
    const traces = [trace, {
      type: "scattersmith", mode: "markers", name: "solver samples",
      real: solverNormalized.map(impedance => impedance.real),
      imag: solverNormalized.map(impedance => impedance.imaginary),
      customdata: solverSamples.map(sample => [sample.frequency_mhz]),
      marker: { color: colors[1], size: 5 },
      hovertemplate: "%{customdata[0]:.6g} MHz<br>solver sample<extra></extra>",
      showlegend: false,
    }];
    if (selected) {
      const selectedNormalized = normalizedImpedance(selected, reference);
      traces.push({
      type: "scattersmith", mode: "markers", name: "selected frequency",
      real: [selectedNormalized.real],
      imag: [selectedNormalized.imaginary],
      customdata: [[selected.frequency_mhz]],
      marker: { color: colors[2], size: 11, symbol: "diamond", line: { color: "#fff", width: 1 } },
      hovertemplate: `${selected.frequency_mhz.toPrecision(6)} MHz` +
        `<br>${selected.interpolated ? "≈ interpolated" : "solver sample"}<extra>selected</extra>`,
      showlegend: false,
      });
    }
    return [traces, {
      title: { text: `Smith chart · ${portName}${reference ? ` · Z₀=${reference} Ω` : ""}`,
        font: { color: "#7df9ff", size: 19 }, x: 0.02 },
      paper_bgcolor: "rgba(3,6,17,0)",
      plot_bgcolor: "rgba(5,14,29,.78)",
      font: { family: '"DejaVu Sans Mono", monospace', color: "#d8fbff" },
      margin: { l: 35, r: 35, t: 62, b: 35 },
      smith: {
        bgcolor: "rgba(5,14,29,.78)",
        realaxis: {
          color: "#9ceeff", gridcolor: "#245069", gridwidth: 0.7,
          tickvals: smithTicks,
        },
        imaginaryaxis: {
          color: "#9ceeff", gridcolor: "#245069", gridwidth: 0.7,
          tickvals: [
            ...smithTicks.slice().reverse().map(value => -value),
            0,
            ...smithTicks,
          ],
        },
      },
      showlegend: false,
    }];
  }
  if (kind === "s11")
    return [[lineTrace("S11", samples, sample => sample.s11_db, colors[1], " dB")],
      withFrequencyCursor(cartesianLayout(`S₁₁ magnitude · ${portName}`,
        "S₁₁ magnitude (dB)", { yaxis: {
          ...cartesianLayout("", "").yaxis, rangemode: "tozero",
          zeroline: true, zerolinewidth: 2,
        } }), selectedFrequency)];
  if (kind === "return-loss")
    return [[lineTrace("return loss", samples, returnLoss, colors[0], " dB")],
      withFrequencyCursor(cartesianLayout(`Return loss · ${portName}`, "return loss (dB)"),
        selectedFrequency)];
  if (kind === "vswr")
    return [[lineTrace("VSWR", samples, finiteVswr, colors[2], ":1")],
      withFrequencyCursor(cartesianLayout(`VSWR · ${portName}`, "VSWR", { yaxis: {
        ...cartesianLayout("", "").yaxis, range: vswrAxisRange(samples) } }), selectedFrequency)];
  if (kind === "impedance")
    return [[
      lineTrace("resistance", samples, sample => sample.impedance_ohms.real, colors[2], " Ω"),
      lineTrace("reactance", samples, sample => sample.impedance_ohms.imaginary, colors[1], " Ω"),
    ], withFrequencyCursor(cartesianLayout(`Feedpoint impedance · ${portName}`, "impedance (Ω)", {
      yaxis: { ...cartesianLayout("", "").yaxis, zeroline: true, zerolinewidth: 2 },
    }), selectedFrequency)];
  const groups = sParameterGroups(measurements);
  return [[...groups.entries()].map(([name, group], index) =>
    lineTrace(`S ${name}`, group, sample => sample.db, colors[index % colors.length], " dB")),
  withFrequencyCursor(cartesianLayout("Multiport S-parameters", "magnitude (dB)"),
    selectedFrequency)];
}

export function createPlotWorkspace(data) {
  const measurements = data.metadata?.measurements || {};
  const ports = portNames(measurements);
  if (!ports.length || !(measurements.port_samples || []).length) return null;

  const switcher = document.createElement("nav");
  switcher.id = "workspace-switch";
  switcher.innerHTML = `<button type="button" data-workspace="viewer" class="active">3D VIEW</button>
    <button type="button" data-workspace="plots">PLOTS</button>`;
  document.body.append(switcher);

  const workspace = document.createElement("section");
  workspace.id = "plots-workspace";
  workspace.hidden = true;
  workspace.innerHTML = `<div class="plot-toolbar panel">
      <label for="plot-kind">PLOT</label><select id="plot-kind"></select>
      <label for="plot-port">PORT</label><select id="plot-port"></select>
      <span id="plot-frequency-note"></span>
    </div><div id="network-plot"></div>`;
  document.body.append(workspace);

  const kindSelect = workspace.querySelector("#plot-kind");
  for (const [value, label] of availablePlots(measurements))
    kindSelect.add(new Option(label, value));
  const portSelect = workspace.querySelector("#plot-port");
  for (const port of ports) portSelect.add(new Option(port, port));
  const note = workspace.querySelector("#plot-frequency-note");
  const fieldFrequency = data.metadata?.field_capture?.frequency_mhz;
  let selectedFrequency = Number.isFinite(fieldFrequency) ? fieldFrequency : null;
  const plot = workspace.querySelector("#network-plot");
  const controlsPanel = document.getElementById("controls");
  const metadataPanel = document.getElementById("metadata-panel");
  const canvas = document.getElementById("viewport");
  let activeWorkspace = "viewer";
  let plotClickBound = false;

  function selectFrequency(event) {
    const point = event.points?.[0];
    const frequency = kindSelect.value === "smith" ? point?.customdata?.[0] : point?.x;
    if (Number.isFinite(Number(frequency))) {
      selectedFrequency = Number(frequency);
      draw();
    }
  }

  function draw() {
    const [traces, layout] = tracesAndLayout(
      kindSelect.value, measurements, portSelect.value, selectedFrequency);
    note.textContent = [
      Number.isFinite(selectedFrequency) ? `selected: ${selectedFrequency.toPrecision(6)} MHz` : null,
      Number.isFinite(fieldFrequency) ? `3D field: ${fieldFrequency.toPrecision(6)} MHz` : null,
    ].filter(Boolean).join(" · ");
    const rendered = Plotly.react(plot, traces, layout, {
      responsive: true,
      displaylogo: false,
      scrollZoom: true,
      modeBarButtonsToRemove: ["lasso2d", "select2d"],
      toImageButtonOptions: { format: "svg", filename: "antenna-turtle-plot" },
    });
    portSelect.hidden = kindSelect.value === "s-parameters";
    workspace.querySelector('label[for="plot-port"]').hidden = portSelect.hidden;
    rendered.then(() => {
      if (!plotClickBound) {
        plot.on("plotly_click", selectFrequency);
        plotClickBound = true;
      }
    });
    return rendered;
  }

  function show(which) {
    activeWorkspace = which;
    const plotting = which === "plots";
    workspace.hidden = !plotting;
    canvas.hidden = plotting;
    controlsPanel.hidden = plotting;
    metadataPanel.hidden = plotting;
    switcher.querySelectorAll("button").forEach(button =>
      button.classList.toggle("active", button.dataset.workspace === which));
    if (plotting) draw().then(() => requestAnimationFrame(() => Plotly.Plots.resize(plot)));
  }

  switcher.addEventListener("click", event => {
    const button = event.target.closest("button[data-workspace]");
    if (button) {
      show(button.dataset.workspace);
      history.replaceState(null, "", button.dataset.workspace === "plots" ? "#plots" : "#viewer");
    }
  });
  kindSelect.addEventListener("change", () => {
    draw();
    if (activeWorkspace === "plots")
      history.replaceState(null, "", `#plots/${kindSelect.value}`);
  });
  portSelect.addEventListener("change", draw);
  const requestedPlot = location.hash.match(/^#plots\/(.+)$/)?.[1];
  if (requestedPlot && [...kindSelect.options].some(option => option.value === requestedPlot))
    kindSelect.value = requestedPlot;
  if (location.hash.startsWith("#plots")) show("plots");
  return { isViewerActive: () => activeWorkspace === "viewer" };
}
