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
const DEFAULT_STEPS = 288;              // 24h at 2-min pings (fallback)

/* Actual time extent of the loaded CSV; set by ingestRows. */
let timeMin = 0;             // first step index in the data
let timeMax = DEFAULT_STEPS - 1; // last step index in the data

const map = new mapboxgl.Map({
  container: "map",
  style: "mapbox://styles/mapbox/dark-v11",
  center: MAP_CENTER,
  zoom: 14.2,
  pitch: 0,
  accessToken: MAPBOX_TOKEN,
});

map.on("load", () => {
  document.body.classList.add("heat-on");

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
      "heatmap-intensity": 0.7,
      "heatmap-radius": [
        "interpolate", ["linear"], ["zoom"],
        12, 18, 16, 34,
      ],
      "heatmap-opacity": 0.6,
      // Softer green → yellow → red ramp (lower alpha, gentler low end)
      "heatmap-color": [
        "interpolate", ["linear"],
        ["heatmap-density"],
        0,    "rgba(0,0,0,0)",
        0.25, "rgba(34,197,94,0.2)",
        0.45, "rgba(74,222,128,0.42)",
        0.65, "rgba(250,204,21,0.58)",
        0.85, "rgba(249,115,22,0.7)",
        1.0,  "rgba(239,68,68,0.8)",
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
const slider = document.getElementById("time-slider");

/* Toast: transient status message (auto-hides) */
let toastTimer = null;
function toast(msg, sticky = false, isError = false) {
  statusEl.textContent = msg;
  statusEl.classList.toggle("error", isError);
  statusEl.hidden = false;
  statusEl.style.opacity = "1";
  if (toastTimer) clearTimeout(toastTimer);
  if (!sticky) toastTimer = setTimeout(() => { statusEl.hidden = true; }, 3500);
}
const playBtn = document.getElementById("play-btn");
const timeLabel = document.getElementById("time-label");
const speedSelect = document.getElementById("speed-select");

fileInput.addEventListener("change", (e) => {
  if (e.target.files.length) loadCSVFile(e.target.files[0]);
});

/* Mock analysis tools — placeholders for the Databricks-backed analytics */
const MOCK_TOOLS = [
  ["tool-congestion", "Congestion analysis", "coming soon — Databricks-backed"],
  ["tool-peaks", "Peak times by place", "coming soon — Databricks-backed"],
  ["tool-hotspots", "Busiest places", "coming soon — Databricks-backed"],
];
for (const [id, label, note] of MOCK_TOOLS) {
  document.getElementById(id).addEventListener("click", () => {
    toast(`${label} · ${note}`);
  });
}

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
  toast("Parsing…", true);
  Papa.parse(file, {
    header: true,
    skipEmptyLines: true,
    dynamicTyping: true,
    complete: (results) => {
      try {
        ingestRows(results.data);
      } catch (err) {
        toast("Error: " + err.message, false, true);
        console.error(err);
      }
    },
    error: (err) => {
      toast("Parse error: " + err.message, false, true);
    },
  });
}

/* ── Ingest: rows → per-step buckets + per-agent trails ── */
function ingestRows(rows) {
  if (!rows.length) throw new Error("CSV is empty");

  const first = rows[0];
  const hasTs = "timestamp" in first;

  // Anchor the step scale at the data's earliest timestamp so the
  // scrub range starts at step 0 no matter when the sim begins.
  if (hasTs) {
    let minMs = Infinity;
    for (const r of rows) {
      const ms = parseTimestamp(r.timestamp);
      if (ms !== null && ms < minMs) minMs = ms;
    }
    if (minMs === Infinity) throw new Error("No readable timestamps in CSV");
    epoch0 = minMs;
  }

  allFeatures = [];
  byStep = new Map();
  byAgent = new Map();

  for (const r of rows) {
    const lat = Number(r.lat);
    const lng = Number(r.lng);
    if (!Number.isFinite(lat) || !Number.isFinite(lng)) continue;

    const step = hasTs ? timestampToStep(r.timestamp) : Number(r.step) || 0;
    if (step < 0) continue;

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

  // Derive the scrub range from the data's actual time extent
  const stepsInData = [...new Set(allFeatures.map((f) => f.properties.step))];
  timeMin = Math.min(...stepsInData);
  timeMax = Math.max(...stepsInData);
  updateTicks();

  if (selectedAgent !== null && !byAgent.has(selectedAgent)) clearSelection();

  const nAgents = new Set(allFeatures.map((f) => f.properties.agent_id)).size;
  toast(`Loaded ${allFeatures.length.toLocaleString()} pings · ${nAgents} agents · ${stepToClock(timeMin)}–${stepToClock(timeMax)}`);

  slider.min = timeMin;
  slider.max = timeMax;
  slider.disabled = false;
  playBtn.disabled = false;
  setStep(timeMin);
}

/* ── Agent selection: click a dot → trace its full path ── */
function selectAgent(agentId, props, coords) {
  selectedAgent = agentId;
  const trail = byAgent.get(agentId) || [];
  updateAgentPanel();

  // Deduped full-day line for the gradient trace (smoothed)
  const coordsLine = trail.map((p) => [p.lng, p.lat]);
  map.getSource("selected-path").setData(
    trail.length >= 2
      ? { type: "Feature", properties: {}, geometry: { type: "LineString", coordinates: smoothCoords(coordsLine) } }
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

  toast(`Agent ${agentId} selected · ${trail.length} waypoints`);
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
 * Date objects), an ISO 8601 string, or "HH:MM(:SS)". Steps are
 * anchored at the CSV's earliest timestamp (epoch0), so multi-day
 * data scrubs continuously from the first ping onward. */
let epoch0 = 0; // ms of the data's first timestamp; set in ingestRows

function parseTimestamp(ts) {
  if (ts instanceof Date && !isNaN(ts)) return ts.getTime();
  if (typeof ts === "string") {
    let m = ts.match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/); // ISO 8601
    if (m) return Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]);
    m = ts.match(/^(\d{1,2}):(\d{2})/); // HH:MM — treated as day 0
    if (m) return (Number(m[1]) * 60 + Number(m[2])) * 60000;
  }
  return null;
}

function timestampToStep(ts) {
  const ms = parseTimestamp(ts);
  if (ms === null) return 0;
  return Math.max(0, Math.floor((ms - epoch0) / (PING_INTERVAL_MIN * 60000)));
}

function emptyFC() {
  return { type: "FeatureCollection", features: [] };
}

/* Chaikin corner-cutting: turns jagged waypoint polylines into smooth
 * curves while preserving endpoints. 2 iterations ≈ 4× the points. */
function smoothCoords(coords, iterations = 2) {
  if (coords.length < 3) return coords;
  let pts = coords;
  for (let it = 0; it < iterations; it++) {
    const out = [pts[0]];
    for (let i = 0; i < pts.length - 1; i++) {
      const [x1, y1] = pts[i];
      const [x2, y2] = pts[i + 1];
      out.push([0.75 * x1 + 0.25 * x2, 0.75 * y1 + 0.25 * y2]);
      out.push([0.25 * x1 + 0.75 * x2, 0.25 * y1 + 0.75 * y2]);
    }
    out.push(pts[pts.length - 1]);
    pts = out;
  }
  return pts;
}

/* ── Timeline ── */
function setStep(step) {
  currentStep = step;
  const feats = byStep.get(step) || [];
  slider.value = step;
  timeLabel.textContent = stepToClock(step);

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
  return { type: "Feature", properties: {}, geometry: { type: "LineString", coordinates: smoothCoords(coords) } };
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
      features.push({ type: "Feature", properties: {}, geometry: { type: "LineString", coordinates: smoothCoords(coords) } });
    }
  }
  return { type: "FeatureCollection", features };
}

function stepToClock(step) {
  // Display anchor = wall clock of the data's first timestamp
  const base = epoch0 ? new Date(epoch0) : new Date(0);
  const t = new Date(base.getTime() + step * PING_INTERVAL_MIN * 60000);
  const dayOffset = Math.floor((Date.UTC(t.getUTCFullYear(), t.getUTCMonth(), t.getUTCDate()) -
    Date.UTC(base.getUTCFullYear(), base.getUTCMonth(), base.getUTCDate())) / 86400000);
  const label = `${String(t.getUTCHours()).padStart(2, "0")}:${String(t.getUTCMinutes()).padStart(2, "0")}`;
  return dayOffset ? `${label}+${dayOffset}d` : label;
}

/* Fill the tick labels from the data's actual extent (5 evenly
 * spaced marks between timeMin and timeMax). */
function updateTicks() {
  const ticksEl = document.getElementById("ticks");
  if (!ticksEl) return;
  const spans = ticksEl.children;
  for (let i = 0; i < spans.length; i++) {
    const step = Math.round(timeMin + (timeMax - timeMin) * (i / (spans.length - 1)));
    spans[i].textContent = stepToClock(step);
  }
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
  if (currentStep >= timeMax) setStep(timeMin);
  playTimer = setInterval(() => {
    const next = currentStep + 1;
    if (next > timeMax) {
      pause();
      setStep(timeMax);
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
