/* Path Tracer — trace walking paths the OSM snapshot is missing and save
 * them to configs/traced_paths.json. Parallel to the geofence editor.
 *
 * Workflow (two-phase, per user request):
 *   1. PLACE  — click the map to drop free vertices (dots), any order.
 *   2. CONNECT — click the dots in the order the path runs; the line
 *      grows as you chain them. Enter/done finalizes the path.
 *
 * Map navigation: drag = pan, wheel = zoom (no mode/keyboard needed).
 *
 * JSON shape written:
 *   { "campus": "UW-Madison",
 *     "paths": [ { "name": "...", "vertices": [[lat, lng], ...] }, ... ] }
 *
 * router.py merges these with OSM ways as corridor seeds (see
 * router._apply_traced_paths()).
 */

const METERS_PER_DEG_LAT = 111320.0;
const COS_LAT = Math.cos(43.07 * Math.PI / 180);
const METERS_PER_DEG_LNG = METERS_PER_DEG_LAT * COS_LAT;
const MAPBOX_TOKEN = "pk.eyJ1Ijoiam9zaGNvbGNvcmQiLCJhIjoiY213Z3k4ajMyMDJ1cTJ4cGw5OHR5eW5vayJ9.dO1J5qNiwkkYCwTC3UBEwg";
const MAP_CENTER = [-89.4005, 43.0765];
const PATH_COLORS = ["#38bdf8", "#4ade80", "#facc15", "#c084fc", "#fb923c", "#f472b6", "#a3e635", "#22d3ee"];

/* ── State ── */
let paths = [];            // [{ name, vertices: [[lat,lng],...], order: [vi,...]|null }]
let selectedIdx = null;    // path being traced / inspected
let mode = null;           // "place" | "connect" | null
let showBuildings = true;
let showExisting = true;

/* ── Persisted storage (localStorage as working copy; file on save) ── */
const LS_KEY = "campuspulse_traced_paths_v2";
try {
  const saved = localStorage.getItem(LS_KEY);
  if (saved) {
    paths = (JSON.parse(saved).paths || []).map(p => ({
      name: p.name || "",
      vertices: p.vertices || [],
      // v1 files had no order — the stored chain IS the order
      order: Array.isArray(p.order) ? p.order
        : (p.vertices && p.vertices.length >= 2 ? p.vertices.map((_, i) => i) : []),
    }));
  }
} catch { /* fresh start */ }

function persist() {
  try { localStorage.setItem(LS_KEY, JSON.stringify({ campus: "UW-Madison", paths })); } catch {}
}

function chained(p) {
  return p.order && p.order.length ? p.order.map(i => p.vertices[i]) : [];
}

function doc() {
  return {
    campus: "UW-Madison",
    paths: paths.map(p => ({
      name: p.name,
      vertices: chained(p).length >= 2 ? chained(p) : p.vertices,
    })),
  };
}

/* ── Map ── */
const map = new mapboxgl.Map({
  container: "map",
  style: "mapbox://styles/mapbox/dark-v11",
  center: MAP_CENTER,
  zoom: 14.2,
  accessToken: MAPBOX_TOKEN,
  // free navigation: drag pans, wheel zooms, no grab-to-move friction
});
map.keyboard.enable();
map.keyboard._panStep = 100;
map.keyboard._time = 0.32;

map.on("load", () => {
  // buildings (footprints only, dim)
  map.addSource("buildings", { type: "geojson", data: emptyFC() });
  map.addLayer({
    id: "building-fill", type: "fill", source: "buildings",
    paint: { "fill-color": "#60a5fa", "fill-opacity": 0.18 },
  });
  map.addLayer({
    id: "building-line", type: "line", source: "buildings",
    paint: { "line-color": "#60a5fa", "line-opacity": 0.4, "line-width": 1 },
  });

  // existing OSM paths (dim, for reference)
  map.addSource("existing", { type: "geojson", data: emptyFC() });
  map.addLayer({
    id: "existing-line", type: "line", source: "existing",
    paint: { "line-color": "#5b6a7f", "line-width": 2, "line-opacity": 0.55 },
  });

  // traced paths (connected chains)
  map.addSource("traced", { type: "geojson", data: emptyFC() });
  map.addLayer({
    id: "traced-line", type: "line", source: "traced",
    paint: {
      "line-color": ["get", "color"],
      "line-width": 3.5,
      "line-opacity": ["case", ["get", "selected"], 1.0, 0.85],
    },
  });

  // placed vertices as dots
  map.addSource("dots", { type: "geojson", data: emptyFC() });
  map.addLayer({
    id: "trace-dots", type: "circle", source: "dots",
    paint: {
      "circle-radius": ["case", ["get", "sel"], 6, 4.5],
      "circle-color": ["case", ["get", "sel"], "#38bdf8", "#94a3b8"],
      "circle-stroke-width": 1.5,
      "circle-stroke-color": "rgba(255,255,255,0.85)",
    },
  });

  // live rubber band from last connected vertex to cursor
  map.addSource("rubber", { type: "geojson", data: emptyFC() });
  map.addLayer({
    id: "rubber-line", type: "line", source: "rubber",
    paint: { "line-color": "#38bdf8", "line-width": 1.5, "line-dasharray": [2, 2], "line-opacity": 0.7 },
  });

  map.on("mousemove", (e) => {
    if (mode === "connect" && selectedIdx !== null) {
      const chain = chained(paths[selectedIdx]);
      if (chain.length) {
        const last = chain[chain.length - 1];
        map.getSource("rubber").setData(lineFC([[last, [e.lngLat.lat, e.lngLat.lng]]]));
        return;
      }
    }
    if (map.getSource("rubber")) map.getSource("rubber").setData(emptyFC());
  });

  map.on("click", (e) => {
    if (mode === null || selectedIdx === null) return;
    const p = paths[selectedIdx];
    const hits = map.queryRenderedFeatures(e.point, { layers: ["trace-dots"] })
      .filter(f => f.properties.pi === selectedIdx);

    if (mode === "place") {
      if (hits.length) {
        // click an existing dot to remove it
        const vi = hits[0].properties.vi;
        p.vertices.splice(vi, 1);
        if (p.order) {
          p.order = p.order.filter(j => j !== vi).map(j => (j > vi ? j - 1 : j));
        }
      } else {
        p.vertices.push([+e.lngLat.lat.toFixed(6), +e.lngLat.lng.toFixed(6)]);
      }
      persist(); renderAll(); updateTracePanel();
      return;
    }

    if (mode === "connect") {
      if (!hits.length) return;
      const vi = hits[0].properties.vi;
      if (!p.order) p.order = [];
      const last = p.order[p.order.length - 1];
      if (vi === last) return;                 // already the tip of the chain
      if (!p.order.includes(vi)) p.order.push(vi);
      persist(); renderAll(); updateTracePanel();
    }
  });

  // pointer feedback
  map.on("mouseenter", "trace-dots", () => (map.getCanvas().style.cursor = "pointer"));
  map.on("mouseleave", "trace-dots", () => setCursor());

  fetch("/osm_paths.geojson").then(r => r.ok ? r.json() : null).then(fc => {
    if (fc) map.getSource("existing").setData(fc);
  }).catch(() => loadExistingFallback());

  fetch("/buildings.geojson").then(r => r.ok ? r.json() : null).then(fc => {
    if (fc) map.getSource("buildings").setData(fc);
  }).catch(() => {});

  renderAll();
});

function setCursor() {
  map.getCanvas().style.cursor = mode ? "crosshair" : "";
}

function emptyFC() { return { type: "FeatureCollection", features: [] }; }
function lineFC(segs) {
  return { type: "FeatureCollection", features: segs.map(s => ({
    type: "Feature", properties: {},
    geometry: { type: "LineString", coordinates: s.map(v => [v[1], v[0]]) },
  })) };
}
function tracedFC() {
  return { type: "FeatureCollection", features: paths.flatMap((p, i) => {
    const chain = chained(p);
    if (chain.length < 2) return [];
    return [{
      type: "Feature",
      properties: { color: PATH_COLORS[i % PATH_COLORS.length], selected: i === selectedIdx ? 1 : 0, name: p.name },
      geometry: { type: "LineString", coordinates: chain.map(v => [v[1], v[0]]) },
    }];
  }) };
}
function dotsFC() {
  return { type: "FeatureCollection", features: paths.flatMap((p, i) =>
    p.vertices.map((v, vi) => ({
      type: "Feature",
      properties: { pi: i, vi, sel: i === selectedIdx ? 1 : 0 },
      geometry: { type: "Point", coordinates: [v[1], v[0]] },
    }))
  ) };
}

/* file:// fallback: pull buildings from the local data.js snapshot */
async function loadExistingFallback() {
  try {
    const r = await fetch("data.js");
    if (r.ok) {
      const txt = await r.text();
      const m = txt.match(/window.BUILDINGS_DATA = (.*);\n?$/s);
      if (m) {
        const docB = JSON.parse(m[1]);
        map.getSource("buildings").setData({
          type: "FeatureCollection",
          features: docB.buildings.map(b => ({
            type: "Feature", properties: {},
            geometry: { type: "Polygon", coordinates: [b.perimeter_polygon.map(v => [v[1], v[0]])] },
          })),
        });
      }
    }
  } catch {}
}

/* ── UI ── */
function setStatus(msg) { document.getElementById("status").textContent = msg; }
function markDirty() { document.getElementById("save-status").textContent = "unsaved changes"; }

function pathLenM(vts) {
  let L = 0;
  for (let i = 1; i < vts.length; i++) {
    L += Math.hypot((vts[i][0] - vts[i-1][0]) * METERS_PER_DEG_LAT,
                    (vts[i][1] - vts[i-1][1]) * METERS_PER_DEG_LNG);
  }
  return L;
}

function renderPathList() {
  const el = document.getElementById("path-list");
  document.getElementById("path-count").textContent = paths.length ? `(${paths.length})` : "";
  el.innerHTML = "";
  paths.forEach((p, i) => {
    const row = document.createElement("div");
    row.className = "path-list-item" + (i === selectedIdx ? " selected" : "");
    const sw = document.createElement("span");
    sw.className = "path-swatch";
    sw.style.background = PATH_COLORS[i % PATH_COLORS.length];
    row.appendChild(sw);
    const n = chained(p).length;
    const label = document.createElement("span");
    label.textContent = `${p.name || "untitled"} · ${p.vertices.length}v · ${n >= 2 ? `${pathLenM(chainOf(p)) | 0}m` : "not connected"}`;
    row.appendChild(label);
    const del = document.createElement("button");
    del.className = "del"; del.textContent = "×"; del.title = "delete path";
    del.addEventListener("click", (e) => {
      e.stopPropagation();
      paths.splice(i, 1);
      if (selectedIdx === i) { selectedIdx = null; mode = null; }
      else if (selectedIdx > i) selectedIdx--;
      persist(); renderAll(); setCursor();
    });
    row.appendChild(del);
    row.addEventListener("click", () => {
      selectedIdx = i;
      if (!p.order) p.order = p.vertices.length ? p.vertices.map((_, k) => k) : [];
      setMode("place");
      renderAll();
      updateTracePanel();
    });
    el.appendChild(row);
  });
  function chainOf(p) { return chained(p); }
}

function renderAll() {
  if (map.getSource("traced")) map.getSource("traced").setData(tracedFC());
  if (map.getSource("dots")) map.getSource("dots").setData(dotsFC());
  if (map.getSource("buildings")) map.getSource("buildings").setData(
    showBuildings ? map.getSource("buildings").getData() : emptyFC());
  if (map.getSource("existing")) map.getSource("existing").setData(
    showExisting ? map.getSource("existing").getData() : emptyFC());
  renderPathList();
}

function updateTracePanel() {
  if (selectedIdx === null) return;
  const p = paths[selectedIdx];
  const chain = chained(p);
  document.getElementById("tp-count").textContent =
    `${p.vertices.length} placed · ${chain.length} connected`;
  document.getElementById("tp-length").textContent = chain.length >= 2 ? `${pathLenM(chain) | 0} m` : "—";
  if (document.activeElement !== document.getElementById("tp-name-input")) {
    document.getElementById("tp-name-input").value = p.name || "";
  }
  document.getElementById("tp-connect").classList.toggle("active", mode === "connect");
}

function showTracePanel(show) {
  document.getElementById("trace-panel").hidden = !show;
}

function setMode(m) {
  mode = m;
  setCursor();
  if (map.getSource("rubber") && m !== "connect") map.getSource("rubber").setData(emptyFC());
  document.getElementById("tp-connect").classList.toggle("active", m === "connect");
}

/* ── Buttons ── */
document.getElementById("btn-new").addEventListener("click", () => {
  paths.push({ name: "", vertices: [], order: [] });
  selectedIdx = paths.length - 1;
  setMode("place");
  persist(); renderAll(); showTracePanel(true); updateTracePanel();
  setStatus("Phase 1 — click the map to drop vertices. Then press Connect.");
});

document.getElementById("tp-close").addEventListener("click", () => {
  setMode(null); showTracePanel(false); renderAll();
});

document.getElementById("tp-undo").addEventListener("click", undoStep);

function undoStep() {
  if (selectedIdx === null) return;
  const p = paths[selectedIdx];
  if (mode === "connect") {
    if (p.order) p.order.pop();
  } else if (p.vertices.length) {
    const vi = p.vertices.length - 1;
    p.vertices.pop();
    if (p.order) p.order = p.order.filter(j => j !== vi).map(j => (j > vi ? j - 1 : j));
  }
  persist(); renderAll(); updateTracePanel();
}

document.getElementById("tp-connect").addEventListener("click", () => {
  if (selectedIdx === null) return;
  const p = paths[selectedIdx];
  if (mode === "connect") { setMode("place"); renderAll(); updateTracePanel(); return; }
  if (p.vertices.length < 2) {
    setStatus("Place at least 2 vertices first, then connect.");
    return;
  }
  setMode("connect");
  setStatus("Click the vertices in the order the path runs. Enter = done.");
  updateTracePanel();
});

document.getElementById("tp-done").addEventListener("click", finishPath);

function finishPath() {
  if (selectedIdx === null) return;
  const p = paths[selectedIdx];
  if (mode === "place") {
    if (p.vertices.length < 2) {
      setStatus("A path needs at least 2 vertices — place more or delete it.");
      return;
    }
    setMode("connect");
    setStatus("Now connect: click vertices in the order the path runs.");
    updateTracePanel();
    return;
  }
  // connect mode
  if (!p.order || p.order.length < 2) {
    setStatus("Connect at least 2 vertices before finishing.");
    return;
  }
  if (p.order.length < p.vertices.length) {
    setStatus(`${p.vertices.length - p.order.length} vertex(es) not connected — connect or delete them.`);
    return;
  }
  p.vertices = chained(p);
  p.order = null;
  setMode(null); showTracePanel(false);
  persist(); renderAll();
  setStatus("Path saved locally. Use Save to config to write the JSON.");
}

document.getElementById("tp-name-input").addEventListener("input", (e) => {
  if (selectedIdx === null) return;
  paths[selectedIdx].name = e.target.value;
  persist(); markDirty(); renderPathList();
});

document.getElementById("toggle-buildings").addEventListener("click", (e) => {
  showBuildings = !showBuildings;
  e.target.classList.toggle("active", showBuildings);
  renderAll();
});

document.getElementById("toggle-existing").addEventListener("click", (e) => {
  showExisting = !showExisting;
  e.target.classList.toggle("active", showExisting);
  renderAll();
});

document.getElementById("btn-save").addEventListener("click", async () => {
  const btn = document.getElementById("btn-save");
  btn.disabled = true;
  try {
    const r = await fetch("/save_traced", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(doc()),
    });
    const j = await r.json();
    document.getElementById("save-status").textContent = j.ok
      ? `saved ${j.saved} paths` : `save failed: ${j.error}`;
  } catch (err) {
    // file:// or server down — offer download instead
    download();
    document.getElementById("save-status").textContent = "server unreachable — downloaded instead";
  }
  btn.disabled = false;
});

function download() {
  const blob = new Blob([JSON.stringify(doc(), null, 2)], { type: "application/json" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = "traced_paths.json";
  a.click();
  URL.revokeObjectURL(a.href);
}
document.getElementById("btn-download").addEventListener("click", download);

/* ── Keyboard ── */
window.addEventListener("keydown", (e) => {
  if (e.target.tagName === "INPUT") {
    if (e.key === "Escape") e.target.blur();
    return;
  }
  if (e.key === "z" || e.key === "Z") {
    undoStep();
  } else if (e.key === "Enter") {
    finishPath();
  } else if (e.key === "Escape") {
    setMode(null); showTracePanel(false); renderAll();
  }
});
