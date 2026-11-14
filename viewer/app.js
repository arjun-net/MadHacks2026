/* ── Campus Pulse — Heatmap Viewer ────────────────────────────────
 * Loads campus_simulation_history.csv via PapaParse, renders it as a
 * Mapbox GL heatmap, and scrubs through the day with a timeline.
 *
 * Expected CSV columns:
 *   agent_id, timestamp (ISO 8601 or "HH:MM"), state, building_id, lat, lng
 * ───────────────────────────────────────────────────────────────── */

const MAPBOX_TOKEN = "pk.eyJ1Ijoiam9zaGNvbGNvcmQiLCJhIjoiY213Z3k4ajMyMDJ1cTJ4cGw5OHR5eW5vayJ9.dO1J5qNiwkkYCwTC3UBEwg";

const MAP_CENTER = [-89.4005, 43.0765]; // UW-Madison [lng, lat]
const PING_INTERVAL_MIN = 2;            // must match generator ping_interval
const STEPS_PER_DAY = (24 * 60) / PING_INTERVAL_MIN; // 288

const map = new mapboxgl.Map({
  container: "map",
  style: "mapbox://styles/mapbox/dark-v11",
  center: MAP_CENTER,
  zoom: 14.2,
  pitch: 0,
  accessToken: MAPBOX_TOKEN,
});

map.on("load", () => {
  map.addSource("pings", {
    type: "geojson",
    data: emptyFC(),
  });

  map.addLayer({
    id: "density",
    type: "heatmap",
    source: "pings",
    paint: {
      // Weight: every ping counts 1 — density comes from point clustering.
      "heatmap-weight": [
        "interpolate", ["linear"], ["get", "weight"],
        0, 0, 1, 1,
      ],
      "heatmap-intensity": 0.9,
      "heatmap-radius": [
        "interpolate", ["linear"], ["zoom"],
        12, 22, 16, 40,
      ],
      "heatmap-opacity": 0.85,
      // Green → yellow → red ramp
      "heatmap-color": [
        "interpolate", ["linear"],
        ["heatmap-density"],
        0,   "rgba(0,0,0,0)",
        0.2, "rgba(34,197,94,0.45)",
        0.4, "rgba(74,222,128,0.7)",
        0.6, "rgba(250,204,21,0.85)",
        0.8, "rgba(249,115,22,0.9)",
        1.0, "rgba(239,68,68,0.95)",
      ],
    },
  });

  // Faint trails for every agent (toggleable, data filled by setStep)
  map.addSource("all-paths", { type: "geojson", data: emptyFC() });
  map.addLayer({
    id: "all-paths-line",
    type: "line",
    source: "all-paths",
    layout: { "line-cap": "round", "line-join": "round" },
    paint: {
      "line-color": "rgba(226, 232, 240, 0.22)",
      "line-width": 1.4,
    },
  });

  // Selected agent's traced path — heat gradient from start (green) to
  // current head (red)
  map.addSource("selected-path", {
    type: "geojson",
    data: emptyFC(),
    lineMetrics: true,
  });
  map.addLayer({
    id: "selected-path-line",
    type: "line",
    source: "selected-path",
    layout: { "line-cap": "round", "line-join": "round" },
    paint: {
      "line-width": ["interpolate", ["linear"], ["zoom"], 12, 3.5, 16, 6],
      "line-gradient": [
        "interpolate", ["linear"], ["line-progress"],
        0,   "rgba(74, 222, 128, 0.9)",
        0.5, "rgba(250, 204, 21, 0.9)",
        1,   "rgba(248, 113, 113, 0.95)",
      ],
    },
  });

  // One dot per agent at the current time step — clickable
  map.addSource("agents", { type: "geojson", data: emptyFC() });
  map.addLayer({
    id: "agent-dots",
    type: "circle",
    source: "agents",
    paint: {
      "circle-radius": ["interpolate", ["linear"], ["zoom"], 12, 3.5, 16, 7],
      "circle-color": ["get", "color"],
      "circle-opacity": 0.95,
      "circle-stroke-color": "rgba(11, 14, 19, 0.9)",
      "circle-stroke-width": 1,
    },
  });

  map.on("click", "agent-dots", (e) => {
    const f = e.features && e.features[0];
    if (!f) return;
    e.preventDefault();
    selectAgent(f.properties.agent_id, f.properties, f.geometry.coordinates);
  });
  map.on("mouseenter", "agent-dots", () => (map.getCanvas().style.cursor = "pointer"));
  map.on("mouseleave", "agent-dots", () => (map.getCanvas().style.cursor = ""));
  map.on("click", (e) => {
    // Click on empty map clears the selection
    const hits = map.queryRenderedFeatures(e.point, { layers: ["agent-dots"] });
    if (!hits.length) clearSelection();
  });

  applyLayerVisibility();
});

/* ── State ── */
let allFeatures = [];       // parsed rows → geojson features
let byStep = new Map();     // stepIndex → [features]
let byAgent = new Map();    // agent_id → [{step, lng, lat}] deduped waypoints
let currentStep = 0;
let playing = false;
let playTimer = null;
let speedMs = 100;
let selectedAgent = null;
let agentPopup = null;
let heatOn = true;
let pathsOn = false;

const STATE_COLORS = {
  SLEEP: "#60a5fa",
  CLASS: "#f87171",
  STUDY: "#4ade80",
  TRANSIT: "#a78bfa",
  EAT: "#facc15",
  SOCIAL: "#f472b6",
  GYM: "#fb923c",
  CLUB: "#e879f9",
  BREAK: "#94a3b8",
};

/* ── CSV loading ── */
const fileInput = document.getElementById("csv-input");
const statusEl = document.getElementById("status");
const statsEl = document.getElementById("stats");
const slider = document.getElementById("time-slider");
const playBtn = document.getElementById("play-btn");
const timeLabel = document.getElementById("time-label");
const speedSelect = document.getElementById("speed-select");

fileInput.addEventListener("change", (e) => {
  if (e.target.files.length) loadCSVFile(e.target.files[0]);
});

/* Drag-and-drop anywhere on the page */
document.addEventListener("dragover", (e) => {
  e.preventDefault();
  document.body.classList.add("dragging");
});
document.addEventListener("dragleave", () => document.body.classList.remove("dragging"));
document.addEventListener("drop", (e) => {
  e.preventDefault();
  document.body.classList.remove("dragging");
  const file = e.dataTransfer.files[0];
  if (file && file.name.endsWith(".csv")) loadCSVFile(file);
});

function loadCSVFile(file) {
  statusEl.textContent = "Parsing…";
  Papa.parse(file, {
    header: true,
    skipEmptyLines: true,
    dynamicTyping: true,
    complete: (results) => {
      try {
        ingestRows(results.data);
      } catch (err) {
        statusEl.textContent = "Error: " + err.message;
        console.error(err);
      }
    },
    error: (err) => {
      statusEl.textContent = "Parse error: " + err.message;
    },
  });
}

/* ── Ingest: rows → per-step buckets + per-agent trails ── */
function ingestRows(rows) {
  if (!rows.length) throw new Error("CSV is empty");

  const first = rows[0];
  const hasTs = "timestamp" in first;

  allFeatures = [];
  byStep = new Map();
  byAgent = new Map();

  for (const r of rows) {
    const lat = Number(r.lat);
    const lng = Number(r.lng);
    if (!Number.isFinite(lat) || !Number.isFinite(lng)) continue;

    const step = hasTs ? timestampToStep(r.timestamp) : Number(r.step) || 0;
    if (step < 0 || step >= STEPS_PER_DAY) continue;

    const f = {
      type: "Feature",
      properties: { agent_id: r.agent_id, state: r.state, step },
      geometry: { type: "Point", coordinates: [lng, lat] },
    };
    allFeatures.push(f);
    if (!byStep.has(step)) byStep.set(step, []);
    byStep.get(step).push(f);

    let trail = byAgent.get(r.agent_id);
    if (!trail) {
      trail = [];
      byAgent.set(r.agent_id, trail);
    }
    // Downsample trails: position jitter inside a building would
    // otherwise produce a 720-point fuzz-blob per agent. Inside a
    // building (state != TRANSIT) keep only state/building changes;
    // while TRANSITing keep every ping so the walked route survives.
    const last = trail[trail.length - 1];
    if (!last || last.state !== r.state || last.building !== r.building_id ||
        r.state === "TRANSIT") {
      trail.push({ step, lng, lat, state: r.state, building: r.building_id });
    }
  }

  if (!allFeatures.length) throw new Error("No valid rows (need lat/lng columns)");

  if (selectedAgent !== null && !byAgent.has(selectedAgent)) clearSelection();

  const nAgents = new Set(allFeatures.map((f) => f.properties.agent_id)).size;
  document.getElementById("stat-pings").textContent = "—";
  document.getElementById("stat-agents").textContent = nAgents;
  document.getElementById("stat-frames").textContent = STEPS_PER_DAY;
  statsEl.hidden = false;
  statusEl.textContent = `Loaded ${allFeatures.length.toLocaleString()} pings · ${nAgents} agents`;

  slider.disabled = false;
  playBtn.disabled = false;
  slider.max = STEPS_PER_DAY - 1;
  setStep(0);
}

/* ── Agent selection: click a dot → trace its full path ── */
function selectAgent(agentId, props, coords) {
  selectedAgent = agentId;
  const trail = byAgent.get(agentId) || [];
  updateAgentPanel();

  // Deduped full-day line for the gradient trace
  const coordsLine = trail.map((p) => [p.lng, p.lat]);
  map.getSource("selected-path").setData(
    trail.length >= 2
      ? { type: "Feature", properties: {}, geometry: { type: "LineString", coordinates: coordsLine } }
      : emptyFC()
  );

  // Popup follows the clicked dot
  const stateLabel = props.state ? props.state.toLowerCase() : "—";
  if (agentPopup) agentPopup.remove();
  agentPopup = new mapboxgl.Popup({ closeButton: false, offset: 14, className: "agent-popup" })
    .setLngLat(coords)
    .setHTML(
      `<div class="popup-title">Agent ${agentId}</div>` +
      `<div class="popup-row"><span>now</span><b>${stateLabel}</b></div>` +
      `<div class="popup-row"><span>waypoints</span><b>${trail.length}</b></div>` +
      `<div class="popup-hint">traced path shown · click empty map to clear</div>`
    )
    .addTo(map);

  statusEl.textContent = `Agent ${agentId} selected · ${trail.length} waypoints`;
}

function clearSelection() {
  selectedAgent = null;
  if (map.getSource("selected-path")) map.getSource("selected-path").setData(emptyFC());
  if (agentPopup) {
    agentPopup.remove();
    agentPopup = null;
  }
  const panel = document.getElementById("agent-panel");
  if (panel) panel.hidden = true;
}

/* ── Agent detail panel ── */
function updateAgentPanel() {
  const panel = document.getElementById("agent-panel");
  if (selectedAgent === null) {
    panel.hidden = true;
    return;
  }
  const trail = byAgent.get(selectedAgent) || [];
  // Segments the agent has completed or is in, up to current step
  const segs = [];
  for (const p of trail) {
    if (p.step > currentStep) break;
    if (!segs.length || segs[segs.length - 1].state !== p.state) {
      segs.push({ state: p.state, from: p.step });
    }
  }
  const cur = trail.length && trail[trail.length - 1].step <= currentStep
    ? trail[trail.length - 1].state : "—";
  const titleEl = document.getElementById("agent-panel-title");
  const bodyEl = document.getElementById("agent-panel-body");
  titleEl.textContent = `Agent ${selectedAgent}`;
  bodyEl.innerHTML =
    `<div class="panel-row"><span>state now</span><b style="color:${STATE_COLORS[cur] || "var(--text)"}">${cur.toLowerCase()}</b></div>` +
    `<div class="panel-row"><span>waypoints</span><b>${trail.length}</b></div>` +
    `<div class="panel-seg-title">Timeline so far</div>` +
    segs.slice(-8).map((s) =>
      `<div class="panel-seg"><span class="seg-dot" style="background:${STATE_COLORS[s.state] || "#94a3b8"}"></span>` +
      `${s.state.toLowerCase()} <em>· from ${stepToClock(s.from)}</em></div>`
    ).join("");
  panel.hidden = false;
}

/* ── Layer toggles ── */
function applyLayerVisibility() {
  if (!map.getSource("pings")) return; // map not loaded yet
  for (const [layer, visible] of [
    ["density", heatOn],
    ["all-paths-line", pathsOn],
    ["selected-path-line", selectedAgent !== null],
    ["agent-dots", true],
  ]) {
    if (map.getLayer(layer)) map.setLayoutProperty(layer, "visibility", visible ? "visible" : "none");
  }
}

function toggleHeatmap() {
  heatOn = !heatOn;
  document.getElementById("toggle-heat").classList.toggle("active", heatOn);
  applyLayerVisibility();
}

function togglePaths() {
  pathsOn = !pathsOn;
  document.getElementById("toggle-paths").classList.toggle("active", pathsOn);
  if (pathsOn) rebuildAllPaths();
  applyLayerVisibility();
}

/* Accepts a Date (PapaParse dynamicTyping converts ISO 8601 stamps to
 * Date objects), an ISO 8601 string, or "HH:MM(:SS)". */
function timestampToStep(ts) {
  let h, m;
  if (ts instanceof Date && !isNaN(ts)) {
    h = ts.getUTCHours();
    m = ts.getUTCMinutes();
  } else if (typeof ts === "string") {
    let match = ts.match(/T(\d{2}):(\d{2})/); // ISO 8601
    if (!match) match = ts.match(/^(\d{1,2}):(\d{2})/); // HH:MM
    if (!match) return 0;
    h = Number(match[1]);
    m = Number(match[2]);
  } else {
    return 0;
  }
  const mins = h * 60 + m;
  return Math.min(STEPS_PER_DAY - 1, Math.floor(mins / PING_INTERVAL_MIN));
}

function emptyFC() {
  return { type: "FeatureCollection", features: [] };
}

/* ── Timeline ── */
function setStep(step) {
  currentStep = step;
  const feats = byStep.get(step) || [];
  slider.value = step;
  timeLabel.textContent = stepToClock(step);
  document.getElementById("stat-pings").textContent = feats.length.toLocaleString();

  if (map.getSource("pings")) {
    map.getSource("pings").setData({ type: "FeatureCollection", features: feats });
  }

  // Agent dots: one per agent at this step
  if (map.getSource("agents")) {
    map.getSource("agents").setData({ type: "FeatureCollection", features: feats.map(cloneDotFeature) });
  }

  // Selected agent's traced path up to the current step (head follows time)
  if (selectedAgent !== null && map.getSource("selected-path")) {
    map.getSource("selected-path").setData(selectedPathToStep(selectedAgent, step));
  }

  // All-agent trails (only rebuilt while the toggle is on)
  if (pathsOn && map.getSource("all-paths")) {
    map.getSource("all-paths").setData(allPathsToStep(step));
  }

  updateAgentPanel();
}

function rebuildAllPaths() {
  if (map.getSource("all-paths")) {
    map.getSource("all-paths").setData(pathsOn ? allPathsToStep(currentStep) : emptyFC());
  }
}

function cloneDotFeature(f) {
  return {
    type: "Feature",
    properties: { ...f.properties, color: STATE_COLORS[f.properties.state] || "#94a3b8" },
    geometry: f.geometry,
  };
}

/* Truncated trail: waypoints with step <= current, in original order */
function selectedPathToStep(agentId, step) {
  const trail = byAgent.get(agentId) || [];
  const coords = [];
  for (const p of trail) {
    if (p.step > step) break;
    coords.push([p.lng, p.lat]);
  }
  // Snap the head to the exact ping position at `step` so the trace stays
  // glued to the dot while the timeline scrubs.
  const at = byStep.get(step);
  const here = at && at.find((f) => f.properties.agent_id === agentId);
  if (here) coords.push(here.geometry.coordinates);
  if (coords.length < 2) return emptyFC();
  return { type: "Feature", properties: {}, geometry: { type: "LineString", coordinates: coords } };
}

/* All agents' full-day trails, trimmed to steps <= current */
function allPathsToStep(step) {
  const features = [];
  for (const [, trail] of byAgent) {
    const coords = [];
    for (const p of trail) {
      if (p.step > step) break;
      coords.push([p.lng, p.lat]);
    }
    if (coords.length >= 2) {
      features.push({ type: "Feature", properties: {}, geometry: { type: "LineString", coordinates: coords } });
    }
  }
  return { type: "FeatureCollection", features };
}

function stepToClock(step) {
  const mins = step * PING_INTERVAL_MIN;
  const h = String(Math.floor(mins / 60)).padStart(2, "0");
  const m = String(mins % 60).padStart(2, "0");
  return `${h}:${m}`;
}

slider.addEventListener("input", () => {
  pause();
  setStep(Number(slider.value));
});

playBtn.addEventListener("click", () => (playing ? pause() : play()));

function play() {
  if (slider.disabled) return;
  playing = true;
  playBtn.textContent = "⏸";
  if (currentStep >= STEPS_PER_DAY - 1) setStep(0);
  playTimer = setInterval(() => {
    const next = currentStep + 1;
    if (next >= STEPS_PER_DAY) {
      pause();
      setStep(STEPS_PER_DAY - 1);
      return;
    }
    setStep(next);
  }, speedMs);
}

function pause() {
  playing = false;
  playBtn.textContent = "▶";
  if (playTimer) clearInterval(playTimer);
  playTimer = null;
}

document.getElementById("toggle-heat").addEventListener("click", toggleHeatmap);
document.getElementById("toggle-paths").addEventListener("click", togglePaths);
document.getElementById("agent-close").addEventListener("click", clearSelection);

speedSelect.addEventListener("change", () => {
  speedMs = Number(speedSelect.value);
  if (playing) {
    pause();
    play();
  }
});
