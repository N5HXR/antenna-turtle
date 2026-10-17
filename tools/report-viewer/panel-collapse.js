let stylesInstalled = false;

function installStyles() {
  if (stylesInstalled) return;
  stylesInstalled = true;
  const style = document.createElement("style");
  style.textContent = `
    .settings-panel-heading{display:flex;align-items:center;justify-content:space-between;
      gap:12px;margin:-3px 0 9px;color:#89eeff;font-size:10px;letter-spacing:.06em}
    .settings-panel-heading button{min-width:54px;padding:3px 7px;font-size:9px;box-shadow:none}
    .settings-panel-collapsed{display:none!important}
    .settings-panel-restore{position:fixed;z-index:12;left:18px;bottom:18px;
      min-width:112px;padding:7px 10px;background:#06101de8;color:#dff;
      border:1px solid #29e9ff;box-shadow:0 0 14px #ff2fd655}
    .settings-panel-restore[hidden]{display:none}
    @media(max-width:800px){.settings-panel-restore{left:8px;bottom:8px}}
  `;
  document.head.append(style);
}

export function makeCollapsibleSettingsPanel(panel) {
  if (!panel) return null;
  installStyles();

  const heading = document.createElement("div");
  heading.className = "settings-panel-heading";
  heading.innerHTML = `<span>DISPLAY SETTINGS</span>
    <button type="button" title="Hide the settings panel" aria-label="Hide the settings panel">HIDE</button>`;
  panel.prepend(heading);

  const hideButton = heading.querySelector("button");
  const restoreButton = document.createElement("button");
  restoreButton.type = "button";
  restoreButton.className = "settings-panel-restore";
  restoreButton.textContent = "SHOW SETTINGS";
  restoreButton.hidden = true;
  restoreButton.setAttribute("aria-controls", panel.id);
  document.body.append(restoreButton);

  let collapsed = false;
  function render() {
    panel.classList.toggle("settings-panel-collapsed", collapsed);
    hideButton.setAttribute("aria-expanded", String(!collapsed));
    restoreButton.hidden = !collapsed || panel.hidden;
  }
  hideButton.addEventListener("click", () => {
    collapsed = true;
    render();
  });
  restoreButton.addEventListener("click", () => {
    collapsed = false;
    render();
  });
  new MutationObserver(render).observe(panel, { attributes: true, attributeFilter: ["hidden"] });
  render();
  return { collapse: () => { collapsed = true; render(); },
    expand: () => { collapsed = false; render(); },
    isCollapsed: () => collapsed };
}
