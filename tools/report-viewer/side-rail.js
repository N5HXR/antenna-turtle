export function installReportSideRail({ controls, navigation, extraOverlays = [] }) {
  document.body.classList.add("report-side-rail");
  document.body.classList.toggle("report-side-rail-no-nav", !navigation);

  const metadata = document.getElementById("metadata-panel");
  if (controls && metadata && metadata.parentElement !== controls)
    controls.append(metadata);

  const plotToolbar = document.querySelector("#plots-workspace .plot-toolbar");
  const plotReadout = document.getElementById("plot-hover-readout");
  if (plotToolbar && plotReadout && plotReadout.parentElement !== plotToolbar)
    plotToolbar.append(plotReadout);

  const toggle = document.createElement("button");
  toggle.id = "report-controls-toggle";
  toggle.type = "button";
  toggle.setAttribute("aria-label", "Hide report controls");
  document.body.append(toggle);

  function render() {
    const hidden = document.body.classList.contains("report-controls-hidden");
    toggle.textContent = hidden ? "SHOW CONTROLS" : "HIDE CONTROLS";
    toggle.setAttribute("aria-expanded", String(!hidden));
    toggle.setAttribute("aria-label", hidden ? "Show report controls" : "Hide report controls");
    requestAnimationFrame(() => window.dispatchEvent(new Event("resize")));
  }

  toggle.addEventListener("click", () => {
    document.body.classList.toggle("report-controls-hidden");
    render();
  });
  navigation?.addEventListener("click", () => setTimeout(render, 0));

  for (const overlay of extraOverlays)
    overlay?.classList.add("report-side-rail-overlay");
  render();
  return { toggle, render };
}
