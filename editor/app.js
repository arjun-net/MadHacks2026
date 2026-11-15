/* ── Geofence & Walkability Editor ─────────────────────────────────
 * Independently open-able (file:// friendly — data.js embeds configs).
 * Renders every geofence vertex (draggable markers) and the walkability
 * grid exactly as router.py computes it:
 *   - 6 m cells, 4 m margin around building footprints, 30 m bbox pad
 *   - projection constants: METERS_PER_DEG_LAT = 111320,
 *     COS_LAT = cos(radians(43.07))
 * ────────────────────────────────────────────────────────────────── */

const MAPBOX_TOKEN = "pk.eyJ1Ijoiam9zaGNvbGNvcmQiLCJhIjoiY213Z3k4ajMyMDJ1cTJ4cGw5OHR5eW5vayJ9.dO1J5qNiwkkYCwTC3UBEwg";
const MAP_CENTER = [-89.4005, 43.0765];

/* ── Grid constants — MUST mirror router.py ── */
const METERS_PER_DEG_LAT = 111320.0;
const COS_LAT = Math.cos(43.07 * Math.PI / 180);
const METERS_PER_DEG_LNG = METERS_PER_DEG_LAT * COS_LAT;
const CELL = 6.0;    // grid cell size, meters
const MARGIN = 4.0;  // blocked wall around each building, meters
const BBOX_PAD = 30; // meters of pad around all polygons
const DOOR_OFFSET = 6.0;

const TYPE_COLORS = {
  study: "#60a5fa",
  class: "#facc15",
  dining: "#f87171",
  dorm: "#4ade80",
  social: "#c084fc",
  gym: "#fb923c",
  housing: "#f472b6",
};

/* ── State ── */
const buildings = (window.BUILDINGS_DATA && window.BUILDINGS_DATA.buildings
  ? window.BUILDINGS_DATA.buildings : []).map((b) => JSON.parse(JSON.stringify(b)));
let selectedBldgIdx = null;
let selectedVertex = null; // { bIdx, vIdx }
let addMode = false;
let gridData = null; // GeoJSON FeatureCollection of blocked cells
let rebuildTimer = null;

/* ── Geometry helpers (mirror router.py) ── */
function distM(a, b) {
  return Math.hypot((a[0] - b[0]) * METERS_PER_DEG_LAT,
                    (a[1] - b[1]) * METERS_PER_DEG_LNG);
}

function pointInPolygon(lat, lng, poly) {
  let inside = false;
  const n = poly.length;
  for (let i = 0, j = n - 1; i < n; j = i++) {
    const [latI, lngI] = poly[i];
    const [latJ, lngJ] = poly[j];
    if ((lngI > lng) !== (lngJ > lng)) {
      const t = (lng - lngJ) / (lngI - lngJ);
      if (lat < latJ + t * (latI - latJ)) inside = !inside;
    }
  }
  return inside;
}

function pointSegDistM(p, a, b) {
  const ax = a[1] * METERS_PER_DEG_LNG, ay = a[0] * METERS_PER_DEG_LAT;
  const bx = b[1] * METERS_PER_DEG_LNG, by = b[0] * METERS_PER_DEG_LAT;
  const px = p[1] * METERS_PER_DEG_LNG, py = p[0] * METERS_PER_DEG_LAT;
  const dx = bx - ax, dy = by - ay;
  const len2 = dx * dx + dy * dy;
  if (len2 < 1e-12) return Math.hypot(px - ax, py - ay);
  const t = Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / len2));
  return Math.hypot(px - (ax + t * dx), py - (ay + t * dy));
}

function nearPolygon(lat, lng, poly, marginM) {
  const mlat = marginM / METERS_PER_DEG_LAT;
  const mlng = marginM / METERS_PER_DEG_LNG;
  const n = poly.length;
  for (let i = 0; i < n; i++) {
    const a = poly[i], b = poly[(i + 1) % n];
    if (Math.abs(lat - a[0]) > mlat * 2 && Math.abs(lat - b[0]) > mlat * 2) continue;
    if (Math.abs(lng - a[1]) > mlng * 2 && Math.abs(lng - b[1]) > mlng * 2) continue;
    if (pointSegDistM([lat, lng], a, b) <= marginM) return true;
  }
  return false;
}

function pushOut(point, poly, dist) {
  const clat = poly.reduce((s, p) => s + p[0], 0) / poly.length;
  const clng = poly.reduce((s, p) => s + p[1], 0) / poly.length;
  const dlat = point[0] - clat, dlng = point[1] - clng;
  const norm = Math.hypot(dlat * METERS_PER_DEG_LAT, dlng * METERS_PER_DEG_LNG);
  if (norm < 1e-9) return [point[0], point[1]];
  const s = dist / norm;
  return [clat + dlat * s, clng + dlng * s];
}

function doorOf(b) {
  const poly = b.perimeter_polygon;
  const clat = poly.reduce((s, p) => s + p[0], 0) / poly.length;
  const clng = poly.reduce((s, p) => s + p[1], 0) / poly.length;
  let best = poly[0], bestD = Infinity;
  for (const p of poly) {
    const d = distM(p, [clat, clng]);
    if (d < bestD) { bestD = d; best = p; }
  }
  return pushOut(best, poly, DOOR_OFFSET);
}

/* ── Walkability grid (mirror Router.__init__) ── */
function computeGrid() {
  const pts = buildings.flatMap((b) => b.perimeter_polygon);
  const lats = pts.map((p) => p[0]);
  const lngs = pts.map((p) => p[1]);
  const latMin = Math.min(...lats) - BBOX_PAD / METERS_PER_DEG_LAT;
  const latMax = Math.max(...lats) + BBOX_PAD / METERS_PER_DEG_LAT;
  const lngMin = Math.min(...lngs) - BBOX_PAD / METERS_PER_DEG_LNG;
  const lngMax = Math.max(...lngs) + BBOX_PAD / METERS_PER_DEG_LNG;

  const nrows = Math.trunc((latMax - latMin) * METERS_PER_DEG_LAT / CELL);
  const ncols = Math.trunc((lngMax - lngMin) * METERS_PER_DEG_LNG / CELL);
  const toLatLng = (r, c) => [
    latMax - (r + 0.5) * CELL / METERS_PER_DEG_LAT,
    lngMin + (c + 0.5) * CELL / METERS_PER_DEG_LNG,
  ];
  const row = (lat) => Math.trunc((latMax - lat) * METERS_PER_DEG_LAT / CELL);
  const col = (lng) => Math.trunc((lng - lngMin) * METERS_PER_DEG_LNG / CELL);

  // mark blocked cells (per-building window, same as router.py)
  const blocked = new Uint8Array(nrows * ncols);
  const marginLat = MARGIN / METERS_PER_DEG_LAT;
  const marginLng = MARGIN / METERS_PER_DEG_LNG;
  for (const b of buildings) {
    const poly = b.perimeter_polygon;
    const plats = poly.map((p) => p[0]);
    const plngs = poly.map((p) => p[1]);
    const r0 = row(Math.max(...plats) + marginLat);
    const r1 = row(Math.min(...plats) - marginLat);
    const c0 = col(Math.min(...plngs) - marginLng);
    const c1 = col(Math.max(...plngs) + marginLng);
    for (let r = Math.max(0, r0); r <= Math.min(nrows - 1, r1); r++) {
      for (let c = Math.max(0, c0); c <= Math.min(ncols - 1, c1); c++) {
        const [lat, lng] = toLatLng(r, c);
        if (pointInPolygon(lat, lng, poly) || nearPolygon(lat, lng, poly, MARGIN)) {
          blocked[r * ncols + c] = 1;
        }
      }
    }
  }

  // merge horizontal runs of blocked cells into rectangles (keeps the
  // GeoJSON feature count small)
  const features = [];
  for (let r = 0; r < nrows; r++) {
    let c = 0;
    while (c < ncols) {
      if (!blocked[r * ncols + c]) { c++; continue; }
      let cEnd = c;
      while (cEnd < ncols && blocked[r * ncols + cEnd]) cEnd++;
      const [swLat] = toLatLng(r + 1, c); // bottom edge of row r
      const [neLat] = toLatLng(r, c);     // top edge of row r
      const wLng = lngMin + c * CELL / METERS_PER_DEG_LNG;
      const eLng = lngMin + cEnd * CELL / METERS_PER_DEG_LNG;
      features.push({
        type: "Feature",
        properties: {},
        geometry: { type: "Polygon", coordinates: [[
          [wLng, swLat], [eLng, swLat], [eLng, neLat], [wLng, neLat], [wLng, swLat],
        ]] },
      });
      c = cEnd;
    }
  }

  return {
    bbox: [[lngMin, latMin], [lngMax, latMax]],
    stats: { nrows, ncols, blockedCells: blocked.reduce((s, v) => s + v, 0) },
    blockedFC: { type: "FeatureCollection", features },
  };
}

/* ── Map ── */
const map = new mapboxgl.Map({
  container: "map",
  style: "mapbox://styles/mapbox/dark-v11",
  center: MAP_CENTER,
  zoom: 14.2,
  accessToken: MAPBOX_TOKEN,
  // mouse drag is reserved for geofence vertices — map panning is
  // arrow-key only; zoom stays on scroll wheel / +/- keys
  dragPan: false,
  dragRotate: false,
  touchZoomRotate: false,
});
map.keyboard.enable();
// arrows pan at a sane speed (default 100ms pan/step is quite slow)
map.keyboard._panStep = 100;
map.keyboard._time = 0.32; // seconds per arrow-key press (default 0.1)

const vertexMarkers = []; // map of bIdx -> [markers]

function polyToGeo(bIdx) {
  const poly = buildings[bIdx].perimeter_polygon;
  return {
    type: "Feature",
    properties: {
      id: buildings[bIdx].id,
      type: buildings[bIdx].type,
      selected: bIdx === selectedBldgIdx ? 1 : 0,
    },
    geometry: { type: "Polygon", coordinates: [[...poly, poly[0]]] },
  };
}

function geofenceFC() {
  return {
    type: "FeatureCollection",
    features: buildings.map((_, i) => polyToGeo(i)),
  };
}

function doorsFC() {
  return {
    type: "FeatureCollection",
    features: buildings.map((b) => {
      const d = doorOf(b);
      return {
        type: "Feature",
        properties: { id: b.id, type: b.type },
        geometry: { type: "Point", coordinates: [d[1], d[0]] },
      };
    }),
  };
}

function renderGeofence() {
  map.getSource("geofence").setData(geofenceFC());
  map.getSource("doors").setData(doorsFC());
}

function renderGrid() {
  gridData = computeGrid();
  map.getSource("grid-blocked").setData(gridData.blockedFC);
  map.getSource("grid-bbox").setData({
    type: "Feature",
    geometry: {
      type: "Polygon",
      coordinates: [[
        gridData.bbox[0],
        [gridData.bbox[1][0], gridData.bbox[0][1]],
        gridData.bbox[1],
        [gridData.bbox[0][0], gridData.bbox[1][1]],
        gridData.bbox[0],
      ]],
    },
    properties: {},
  });
  setStatus(`${gridData.stats.nrows}×${gridData.stats.ncols} grid · ` +
    `${gridData.stats.blockedCells.toLocaleString()} blocked cells · ` +
    `arrows = pan · wheel = zoom · drag vertex = move`);
}

function scheduleRebuild() {
  markDirty();
  clearTimeout(rebuildTimer);
  rebuildTimer = setTimeout(renderGrid, 120);
}

function setStatus(msg) {
  document.getElementById("status").textContent = msg;
}

/* ── Vertex markers ── */
function markerEl(bIdx, vIdx, selected) {
  const el = document.createElement("div");
  el.className = "vertex-marker" + (selected ? " selected" : "");
  el.style.borderColor = TYPE_COLORS[buildings[bIdx].type] || "#e8ecf2";
  el.dataset.b = bIdx;
  el.dataset.v = vIdx;
  return el;
}

function rebuildMarkers() {
  for (const list of vertexMarkers) for (const m of list) m.remove();
  vertexMarkers.length = 0;
  buildings.forEach((b, bIdx) => {
    vertexMarkers[bIdx] = b.perimeter_polygon.map((p, vIdx) => {
      const el = markerEl(bIdx, vIdx, false);
      const m = new mapboxgl.Marker({
        element: el,
        draggable: true,
        anchor: "center",
      })
        .setLngLat([p[1], p[0]])
        .addTo(map);
      el.addEventListener("click", (e) => {
        e.stopPropagation();
        selectVertex(bIdx, vIdx);
      });
      m.on("dragstart", () => selectVertex(bIdx, vIdx, { noRebuild: true }));
      m.on("drag", () => {
        const ll = m.getLngLat();
        buildings[bIdx].perimeter_polygon[vIdx] = [ll.lat, ll.lng];
        renderGeofence();
        syncVertexPanel();
      });
      m.on("dragend", () => {
        scheduleRebuild();
        syncVertexPanel();
      });
      return m;
    });
  });
  highlightSelectedVertex();
}

function highlightSelectedVertex() {
  vertexMarkers.forEach((list, bIdx) => {
    list.forEach((m, vIdx) => {
      m.getElement().classList.toggle(
        "selected",
        selectedVertex && selectedVertex.bIdx === bIdx && selectedVertex.vIdx === vIdx
      );
    });
  });
}

/* ── Selection / panel ── */
function selectVertex(bIdx, vIdx, opts = {}) {
  selectedBldgIdx = bIdx;
  selectedVertex = { bIdx, vIdx };
  hideNamePopup();
  if (!opts.noRebuild) {
    renderGeofence();
    highlightSelectedVertex();
    renderBldgList();
  }
  showVertexPanel();
}

function selectBuilding(bIdx, { zoom = false } = {}) {
  selectedBldgIdx = bIdx;
  if (!bIdx) selectedBldgIdx = null;
  selectedVertex = null;
  renderGeofence();
  highlightSelectedVertex();
  renderBldgList();
  if (zoom) {
    const poly = buildings[bIdx].perimeter_polygon;
    const lats = poly.map((p) => p[0]);
    const lngs = poly.map((p) => p[1]);
    map.fitBounds(
      [[Math.min(...lngs), Math.min(...lats)], [Math.max(...lngs), Math.max(...lats)]],
      { padding: 120, duration: 500 }
    );
  }
}

function showVertexPanel() {
  const b = buildings[selectedVertex.bIdx];
  const p = b.perimeter_polygon[selectedVertex.vIdx];
  document.getElementById("vertex-panel").hidden = false;
  document.getElementById("vp-bldg").textContent = b.name || b.id;
  document.getElementById("vp-index").textContent = selectedVertex.vIdx;
  document.getElementById("vp-bid").textContent = b.id;
  document.getElementById("vp-type").textContent = b.type;
  document.getElementById("vp-type").style.color = TYPE_COLORS[b.type] || "inherit";
  syncVertexPanel();
  updateAddModeNote();
}

function syncVertexPanel() {
  if (!selectedVertex) return;
  const b = buildings[selectedVertex.bIdx];
  const p = b.perimeter_polygon[selectedVertex.vIdx];
  const latEl = document.getElementById("vp-lat");
  const lngEl = document.getElementById("vp-lng");
  if (document.activeElement !== latEl) latEl.value = p[0].toFixed(5);
  if (document.activeElement !== lngEl) lngEl.value = p[1].toFixed(5);
  document.getElementById("vp-count").textContent = b.perimeter_polygon.length;
}

function hideVertexPanel() {
  document.getElementById("vertex-panel").hidden = true;
  selectedVertex = null;
  highlightSelectedVertex();
  hideNamePopup();
}

function updateAddModeNote() {
  const note = document.getElementById("vp-note");
  if (addMode) {
    note.textContent = "Add mode: click the map to insert a vertex after the selected one.";
    note.className = "panel-note warn";
  } else {
    note.textContent = "Drag the marker to move this vertex. The walkability grid rebuilds as you edit.";
    note.className = "panel-note";
  }
}

/* ── Building list ── */
function renderBldgList() {
  const list = document.getElementById("bldg-list");
  list.innerHTML = "";
  buildings.forEach((b, i) => {
    const btn = document.createElement("button");
    btn.className = "bldg-item" + (i === selectedBldgIdx && selectedBldgIdx !== null ? " selected" : "");
    btn.innerHTML =
      `<span class="dot" style="background:${TYPE_COLORS[b.type] || "#e8ecf2"}"></span>` +
      `<span class="name">${b.name || b.id}</span>` +
      `<span class="count">${b.perimeter_polygon.length}v</span>`;
    btn.addEventListener("click", () => selectBuilding(i, { zoom: true }));
    list.appendChild(btn);
  });
}

/* ── Save to config ── */
let dirty = false;
const DRAFT_KEY = "geofence-editor-draft";

function exportDoc() {
  return {
    campus: (window.BUILDINGS_DATA && window.BUILDINGS_DATA.campus) || "UW-Madison",
    buildings: buildings.map((b) => ({
      ...b,
      center: [
        b.perimeter_polygon.reduce((s, p) => s + p[0], 0) / b.perimeter_polygon.length,
        b.perimeter_polygon.reduce((s, p) => s + p[1], 0) / b.perimeter_polygon.length,
      ],
    })),
  };
}

/* Persist the working state to localStorage on every edit so a failed
   save, a reload, or a crash never loses progress. */
function stashDraft() {
  try {
    localStorage.setItem(DRAFT_KEY, JSON.stringify({
      savedAt: Date.now(),
      // draft is only meaningful against the exact baseline it started from;
      // a mismatch means data.js changed on disk, so the draft is stale
      base: JSON.stringify(window.BUILDINGS_DATA || null),
      doc: exportDoc(),
    }));
  } catch (_) { /* storage full/blocked — editor keeps working in-memory */ }
}

function restoreDraft() {
  try {
    const raw = localStorage.getItem(DRAFT_KEY);
    if (!raw) return false;
    const { base, doc } = JSON.parse(raw);
    if (!doc || !Array.isArray(doc.buildings)) return false;
    // discard drafts made against a different baseline (data.js regenerated
    // since this session) — otherwise stale polygons overwrite real edits
    if (base !== JSON.stringify(window.BUILDINGS_DATA || null)) {
      clearDraft();
      return false;
    }
    // apply by id — tolerates buildings added/removed between sessions
    const byId = new Map(buildings.map((b, i) => [b.id, i]));
    let applied = 0;
    for (const saved of doc.buildings) {
      const i = byId.get(saved.id);
      if (i === undefined) continue;
      buildings[i].perimeter_polygon = saved.perimeter_polygon.map((p) => [p[0], p[1]]);
      applied++;
    }
    if (!applied) return false;
    renderGeofence();
    rebuildMarkers();
    scheduleRebuild(); // marks dirty + refreshes the grid
    return true;
  } catch (_) {
    return false;
  }
}

function clearDraft() {
  try { localStorage.removeItem(DRAFT_KEY); } catch (_) {}
}

function markDirty() {
  if (!dirty) {
    dirty = true;
    setSaveStatus("unsaved edits", "warn");
  }
  stashDraft();
}

function setSaveStatus(text, cls) {
  const el = document.getElementById("save-status");
  el.textContent = text;
  el.className = "save-status" + (cls ? " " + cls : "");
}

async function saveToConfig() {
  const btn = document.getElementById("btn-save");
  btn.disabled = true;
  setSaveStatus("saving…", "");
  try {
    const res = await fetch("http://localhost:8765/save", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(exportDoc()),
    });
    const out = await res.json();
    if (!res.ok || !out.ok) throw new Error(out.error || `HTTP ${res.status}`);
    dirty = false;
    clearDraft();
    setSaveStatus(`saved ✓ (${out.saved} buildings)`, "ok");
    // data.js was regenerated by the server; reload it so the baseline
    // matches what's on disk — in-memory edits are already identical
    delete window.BUILDINGS_DATA;
    await loadScript("data.js");
    setStatus(`Saved ${out.saved} buildings to configs/buildings.json.`);
  } catch (err) {
    setSaveStatus("save failed", "err");
    setStatus(
      `Save failed: ${err.message}. Your edits are kept (autosaved in this ` +
      `browser). Start the server: \`python3 editor/serve.py\`, then retry — ` +
      `works from file:// too. Download as fallback if needed.`
    );
  } finally {
    btn.disabled = false;
  }
}

function loadScript(src) {
  return new Promise((resolve, reject) => {
    const s = document.createElement("script");
    s.src = src;
    s.onload = resolve;
    s.onerror = () => reject(new Error(`failed to load ${src}`));
    document.head.appendChild(s);
  });
}

/* ── Download edited JSON ── */
function downloadJSON() {
  const blob = new Blob([JSON.stringify(exportDoc(), null, 2)], { type: "application/json" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = "buildings.json";
  a.click();
  URL.revokeObjectURL(a.href);
}

/* ── Map load: layers + events ── */
map.on("load", () => {
  // sources
  map.addSource("grid-bbox", { type: "geojson", data: { type: "FeatureCollection", features: [] } });
  map.addSource("grid-blocked", { type: "geojson", data: { type: "FeatureCollection", features: [] } });
  map.addSource("geofence", { type: "geojson", data: geofenceFC() });
  map.addSource("doors", { type: "geojson", data: doorsFC() });

  // walkable bbox (base fill under everything)
  map.addLayer({
    id: "grid-bbox-fill",
    type: "fill",
    source: "grid-bbox",
    paint: { "fill-color": "#4ade80", "fill-opacity": 0.10 },
  });

  // blocked cells (buildings + margin)
  map.addLayer({
    id: "grid-blocked-fill",
    type: "fill",
    source: "grid-blocked",
    paint: { "fill-color": "#f87171", "fill-opacity": 0.35 },
  });

  // geofence polygons
  map.addLayer({
    id: "geofence-fill",
    type: "fill",
    source: "geofence",
    paint: {
      "fill-color": "#e8ecf2",
      "fill-opacity": [
        "case",
        ["==", ["get", "selected"], 1], 0.28,
        0.12,
      ],
    },
  });
  // per-type colors via match (property-driven color strings aren't supported)
  map.setPaintProperty("geofence-fill", "fill-color", [
    "match", ["get", "type"],
    "study", "#60a5fa",
    "class", "#facc15",
    "dining", "#f87171",
    "dorm", "#4ade80",
    "social", "#c084fc",
    "gym", "#fb923c",
    "housing", "#f472b6",
    "#e8ecf2",
  ]);

  map.addLayer({
    id: "geofence-outline",
    type: "line",
    source: "geofence",
    paint: {
      "line-color": [
        "case",
        ["==", ["get", "selected"], 1], "#4ade80",
        "#ffffff",
      ],
      "line-width": [
        "case",
        ["==", ["get", "selected"], 1], 2.5,
        1,
      ],
      "line-opacity": 0.7,
    },
  });

  // doors (computed like router.py: nearest-to-centroid vertex pushed 6 m out)
  map.addLayer({
    id: "doors-circle",
    type: "circle",
    source: "doors",
    paint: {
      "circle-color": "#ffffff",
      "circle-radius": 3.5,
      "circle-stroke-color": "#0b0e13",
      "circle-stroke-width": 1.5,
      "circle-opacity": 0.85,
    },
  });

  // restore any unsaved draft from a previous session (failed save,
  // accidental reload) — applied before the initial grid render
  if (restoreDraft()) {
    setSaveStatus("draft restored", "warn");
    setStatus("Restored unsaved edits from your last session — click “Save to config” to write them to disk.");
  }

  renderGrid();
  rebuildMarkers();
  renderBldgList();
  renderTypeLegend();

  // click empty map: in add mode insert a vertex; otherwise clear selection
  // (do NOT re-enable dragPan here — mouse drag is reserved for vertices)
  map.on("click", (e) => {
    if (addMode && selectedVertex) {
      const b = buildings[selectedVertex.bIdx];
      const insertAt = selectedVertex.vIdx + 1;
      b.perimeter_polygon.splice(insertAt, 0, [e.lngLat.lat, e.lngLat.lng]);
      addMode = false;
      renderGeofence();
      rebuildMarkers();
      selectVertex(selectedVertex.bIdx, insertAt);
      scheduleRebuild();
      updateAddModeNote();
      return;
    }
    // clicked a building polygon (not a vertex marker)? show its name
    const hits = map.queryRenderedFeatures(e.point, { layers: ["geofence-fill"] });
    if (hits.length) {
      const { id, type } = hits[0].properties;
      const b = buildings.find((x) => x.id === id);
      if (b) {
        selectBuilding(buildings.indexOf(b), { zoom: false });
        const poly = b.perimeter_polygon;
        const clat = poly.reduce((s, p) => s + p[0], 0) / poly.length;
        const clng = poly.reduce((s, p) => s + p[1], 0) / poly.length;
        showNamePopup(clng, clat, b.name || b.id, type, poly.length);
        setStatus(`${b.name || b.id} · type: ${type} · ${poly.length} vertices`);
        return;
      }
    }
    hideVertexPanel();
    hideNamePopup();
    selectBuilding(null);
  });

  // map cursor
  map.on("mousemove", () => {
    map.getCanvas().style.cursor = addMode ? "crosshair" : "";
  });
});

/* ── Building-name popup (click polygon interior/midpoint) ── */
const namePopup = new mapboxgl.Popup({
  closeButton: false,
  closeOnClick: false,
  offset: 0,
});

function showNamePopup(lng, lat, name, type, nVerts) {
  namePopup
    .setLngLat([lng, lat])
    .setHTML(
      `<div class="name-pop">
         <div class="name-pop-title" style="color:${TYPE_COLORS[type] || "#e8ecf2"}">${name}</div>
         <div class="name-pop-sub">${type} · ${nVerts} vertices</div>
       </div>`
    )
    .addTo(map);
}

function hideNamePopup() {
  namePopup.remove();
}

function renderTypeLegend() {
  const el = document.getElementById("type-legend");
  el.innerHTML = Object.entries(TYPE_COLORS)
    .map(([t, c]) =>
      `<span class="key"><i class="swatch" style="background:${c}"></i>${t}</span>`
    ).join("");
}

/* ── Controls wiring ── */
document.getElementById("toggle-grid").addEventListener("click", (e) => {
  const btn = e.currentTarget;
  btn.classList.toggle("active");
  const on = btn.classList.contains("active");
  map.setLayoutProperty("grid-bbox-fill", "visibility", on ? "visible" : "none");
  map.setLayoutProperty("grid-blocked-fill", "visibility", on ? "visible" : "none");
});

document.getElementById("toggle-geofence").addEventListener("click", (e) => {
  const btn = e.currentTarget;
  btn.classList.toggle("active");
  const on = btn.classList.contains("active");
  for (const id of ["geofence-fill", "geofence-outline", "doors-circle"]) {
    map.setLayoutProperty(id, "visibility", on ? "visible" : "none");
  }
  vertexMarkers.forEach((list) => list.forEach((m) => {
    m.getElement().style.display = on ? "" : "none";
  }));
});

document.getElementById("btn-download").addEventListener("click", downloadJSON);
document.getElementById("btn-save").addEventListener("click", saveToConfig);

// warn before leaving with unsaved edits
window.addEventListener("beforeunload", (e) => {
  if (dirty) { e.preventDefault(); e.returnValue = ""; }
});

document.getElementById("vp-close").addEventListener("click", hideVertexPanel);

document.getElementById("vp-delete").addEventListener("click", () => {
  if (!selectedVertex) return;
  const b = buildings[selectedVertex.bIdx];
  if (b.perimeter_polygon.length <= 3) {
    setStatus("Cannot delete: a polygon needs at least 3 vertices.");
    return;
  }
  b.perimeter_polygon.splice(selectedVertex.vIdx, 1);
  const { bIdx, vIdx } = selectedVertex;
  selectedVertex = null;
  renderGeofence();
  rebuildMarkers();
  hideVertexPanel();
  selectBuilding(bIdx);
  scheduleRebuild();
  setStatus(`Deleted vertex from ${b.id}.`);
});

document.getElementById("vp-add").addEventListener("click", () => {
  if (!selectedVertex) {
    setStatus("Select a vertex first — new vertices insert after it.");
    return;
  }
  addMode = !addMode;
  updateAddModeNote();
});

function wireCoordInput(id, axis) {
  const el = document.getElementById(id);
  el.addEventListener("input", () => {
    if (!selectedVertex) return;
    const v = parseFloat(el.value);
    if (Number.isNaN(v)) return;
    const b = buildings[selectedVertex.bIdx];
    b.perimeter_polygon[selectedVertex.vIdx][axis] = v;
    const m = vertexMarkers[selectedVertex.bIdx][selectedVertex.vIdx];
    const p = b.perimeter_polygon[selectedVertex.vIdx];
    m.setLngLat([p[1], p[0]]);
    renderGeofence();
    scheduleRebuild();
  });
}
wireCoordInput("vp-lat", 0);
wireCoordInput("vp-lng", 1);
