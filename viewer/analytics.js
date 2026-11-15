/* ── Campus Pulse — analytics layer ───────────────────────────────
 * Computes staff-facing analytics from the loaded simulation pings
 * (allFeatures / byStep / epoch0 are script-globals from app.js).
 * Each "tool" returns a ranked list of map pins (recommendations)
 * plus a human summary. The agent (agent.js) and the dock buttons
 * both call runTool(). Databricks-backed views can later replace
 * aggregate() with a fetch to the snapshot endpoint.
 * ───────────────────────────────────────────────────────────────── */

const ANALYTICS = (() => {
  // Analysis grid: ~167m × ~180m cells over campus
  const BINS = { lat0: 43.0670, lng0: -89.4290, dLat: 0.0015, dLng: 0.0024 };

  let buildings = null;      // id → { name, center:[lat,lng] }
  let lastToolId = null;     // for dock toggle behavior
  let lastResult = null;     // { tool, title, summary, pins }

  /* ── building metadata ── */
  async function ensureBuildings() {
    if (buildings) return buildings;
    buildings = {};
    try {
      const r = await fetch("/configs/buildings.json");
      const j = await r.json();
      for (const b of j.buildings) buildings[b.id] = { name: b.name || b.id, center: b.center };
    } catch (_) { /* pins still work without names */ }
    return buildings;
  }

  /* ── grid helpers ── */
  const binKey = (lat, lng) =>
    Math.floor((lat - BINS.lat0) / BINS.dLat) + ":" + Math.floor((lng - BINS.lng0) / BINS.dLng);

  function binCenter(key) {
    const [a, b] = key.split(":").map(Number);
    return [BINS.lng0 + (b + 0.5) * BINS.dLng, BINS.lat0 + (a + 0.5) * BINS.dLat]; // [lng, lat]
  }

  /* Nearest known building within ~220m, for naming pins */
  function nearBuilding(lngLat) {
    if (!buildings) return null;
    let best = null, bestD = Infinity;
    for (const [id, b] of Object.entries(buildings)) {
      if (!b.center) continue;
      const d = Math.hypot((b.center[1] - lngLat[0]) * 78600, (b.center[0] - lngLat[1]) * 111320);
      if (d < bestD) { bestD = d; best = b.name; }
    }
    return bestD <= 220 ? best : null;
  }

  /* minute-of-day (0..1439) for a ping, in UTC (matches the sim's
   * timestamp clock). The CSV's minute_of_day column is minutes-since-
   * sim-start + 2, NOT wall-clock minute — so derive from the stored
   * step (ms since epoch0) which is exact. */
  function minuteOf(f) {
    return (Math.floor(epoch0 / 60000) + f.properties.step * PING_INTERVAL_MIN) % 1440;
  }

  /* ── aggregate pings into the grid ── */
  function aggregate() {
    const cells = new Map(); // key → { day, night, morning }
    for (const f of allFeatures) {
      const st = f.properties.state;
      if (st === "SLEEP") continue;
      const key = binKey(f.geometry.coordinates[1], f.geometry.coordinates[0]);
      let c = cells.get(key);
      if (!c) { c = { day: 0, night: 0, morning: 0 }; cells.set(key, c); }
      const m = minuteOf(f);
      if (m >= 420 && m < 1320) c.day++;
      else if (st === "TRANSIT") c.night++;
      if (m >= 420 && m < 570) c.morning++;
    }
    return cells;
  }

  /* ── building occupancy by hour ── */
  function buildingHours() {
    const occ = new Map(); // id → [24] counts
    for (const f of allFeatures) {
      if (f.properties.state === "TRANSIT" || f.properties.state === "SLEEP") continue;
      const b = f.properties.building_id;
      if (!b) continue;
      let arr = occ.get(b);
      if (!arr) { arr = new Array(24).fill(0); occ.set(b, arr); }
      arr[Math.floor(minuteOf(f) / 60)]++;
    }
    return occ;
  }

  /* ── tool implementations ── */
  const TOOLS = {
    snow_priority: {
      label: "Snow-clearing priority",
      run(cells) {
        const ranked = [...cells.entries()]
          .filter(([, c]) => c.morning >= 40)
          .sort((a, b) => b[1].morning - a[1].morning)
          .slice(0, 8);
        const pins = ranked.map(([key, c], i) => {
          const ll = binCenter(key);
          const near = nearBuilding(ll);
          return {
            lngLat: ll,
            severity: Math.min(1, c.morning / ranked[0][1].morning),
            title: `Snow priority #${i + 1}${near ? " · near " + near : ""}`,
            metric: `${c.morning.toLocaleString()} pings, 7:00–9:30am`,
            reco: "Clear + salt before the 7–9:30am wave; highest overnight-adjacent foot traffic on campus.",
          };
        });
        return {
          title: "Snow-clearing priority queue",
          summary: `Ranked path segments by 7:00–9:30am pedestrian load. Clear in this order before the morning wave — the top ${Math.min(3, pins.length)} segments carry the heaviest commute traffic.`,
          pins,
        };
      },
    },

    lighting: {
      label: "Night lighting candidates",
      run(cells) {
        // Day-busy corridors where night use outstrips passive daytime
        // presence. Ranked by absolute night traffic among cells whose
        // daytime population is modest relative to their night use.
        const ranked = [...cells.entries()]
          .filter(([, c]) => c.night >= 10 && c.night >= 0.15 * Math.max(1, c.day))
          .sort((a, b) => b[1].night / Math.max(1, b[1].day) - a[1].night / Math.max(1, a[1].day))
          .slice(0, 8);
        const pins = ranked.map(([key, c], i) => {
          const ll = binCenter(key);
          const near = nearBuilding(ll);
          const ratio = (c.night / Math.max(1, c.day)).toFixed(2);
          return {
            lngLat: ll,
            severity: Math.min(1, c.night / 200),
            title: `Lighting candidate #${i + 1}${near ? " · near " + near : ""}`,
            metric: `${c.night} night crossings vs ${c.day} day — night/day ${ratio}×`,
            reco: "Walked heavily after dark relative to daytime use: no passive surveillance exactly when people head home. Add lighting + sightline clearing.",
          };
        });
        return {
          title: "Night safety — lighting candidates",
          summary: `Corridors that carry meaningful after-dark traffic relative to their daytime population — people walk home through these with little surrounding presence. Ranked by night/day ratio; these are where lighting and call boxes buy the most safety.`,
          pins,
        };
      },
    },

    deadzones: {
      label: "Night dead zones",
      run(cells) {
        // Night-travel cells below the campus-wide MEDIAN of daytime
        // presence: real foot traffic, below-average daytime "eyes".
        const withDay = [...cells.values()].map((c) => c.day).sort((a, b) => a - b);
        const dayMedian = withDay[Math.floor(withDay.length / 2)] || 0;
        const ranked = [...cells.entries()]
          .filter(([, c]) => c.night >= 20 && c.day <= dayMedian)
          .sort((a, b) => b[1].night - a[1].night)
          .slice(0, 8);
        const pins = ranked.map(([key, c], i) => {
          const ll = binCenter(key);
          const near = nearBuilding(ll);
          return {
            lngLat: ll,
            severity: Math.min(1, c.night / 200),
            title: `Dead zone #${i + 1}${near ? " · near " + near : ""}`,
            metric: `${c.night} solo night crossings · day use ${c.day}`,
            reco: "Active night traffic with almost no daytime eyes. Consider patrol stops, escort-service stops, or emergency phones.",
          };
        });
        return {
          title: "Night dead zones",
          summary: dayMedian === 0
            ? "Not enough daytime contrast in the loaded window — every cell has night traffic. Try a narrower time window."
            : `Places with real night foot traffic but bottom-quartile daytime population — low passive surveillance exactly where people walk alone. Escort routes or emergency infrastructure belong here.`,
          pins,
        };
      },
    },

    congestion: {
      label: "Passing-period congestion",
      run(cells) {
        const ranked = [...cells.entries()]
          .filter(([, c]) => c.morning >= 40)
          .sort((a, b) => b[1].morning - a[1].morning)
          .slice(0, 8);
        const pins = ranked.map(([key, c], i) => {
          const ll = binCenter(key);
          const near = nearBuilding(ll);
          return {
            lngLat: ll,
            severity: Math.min(1, c.morning / ranked[0][1].morning),
            title: `Crush point #${i + 1}${near ? " · near " + near : ""}`,
            metric: `${c.morning.toLocaleString()} crossings, 7:00–9:30am`,
            reco: "Worst morning squeeze. Review crossing timing / pathway width before fall enrollment growth.",
          };
        });
        return {
          title: "Passing-period congestion",
          summary: `The morning crush points — where the 8–9am class release physically funnels. Any capacity or signal-timing change should start at these ${pins.length} segments.`,
          pins,
        };
      },
    },

    hotspots: {
      label: "All-day hotspots",
      run(cells) {
        const ranked = [...cells.entries()]
          .filter(([, c]) => c.day >= 400)
          .sort((a, b) => b[1].day - a[1].day)
          .slice(0, 8);
        const pins = ranked.map(([key, c], i) => {
          const ll = binCenter(key);
          const near = nearBuilding(ll);
          return {
            lngLat: ll,
            severity: Math.min(1, c.day / ranked[0][1].day),
            title: `Hotspot #${i + 1}${near ? " · " + near : ""}`,
            metric: `${c.day.toLocaleString()} daytime pings`,
            reco: "Sustained all-day draw. Prioritize for dwell space, wayfinding, and maintenance frequency.",
          };
        });
        return {
          title: "All-day hotspots",
          summary: `The campus's centers of gravity by sustained daytime presence — where people stay, not just pass. Space-planning and service placement should follow this ranking.`,
          pins,
        };
      },
    },

    peaks: {
      label: "Peak hours by building",
      run() {
        const occ = buildingHours();
        const names = buildings || {};
        const ranked = [...occ.entries()]
          .map(([id, hours]) => {
            const total = hours.reduce((a, b) => a + b, 0);
            const peakH = hours.indexOf(Math.max(...hours));
            const center = names[id] && names[id].center ? [names[id].center[1], names[id].center[0]] : null;
            return { id, total, peakH, center };
          })
          .filter((r) => r.center && r.total >= 200)
          .sort((a, b) => b.total - a.total)
          .slice(0, 8);
        const pins = ranked.map((r, i) => ({
          lngLat: r.center,
          severity: Math.min(1, r.total / ranked[0].total),
          title: `Peak #${i + 1} · ${names[r.id] ? names[r.id].name : r.id}`,
          metric: `${r.total.toLocaleString()} presence-pings · peaks ${String(r.peakH).padStart(2, "0")}:00`,
          reco: r.peakH < 10
            ? "Morning-peaked. Shift-dependent demand — staffing and openings should lead the peak."
            : "Afternoon/evening-peaked. Consider extended hours or crowd smoothing (e.g. dining time offsets).",
        }));
        return {
          title: "Peak hours by building",
          summary: `Each building's occupancy peak and total daytime presence. Use it to stagger class release, dining service windows, and library staffing.`,
          pins,
        };
      },
    },
  };

  /* ── pins rendering ── */
  /* ── pins: manually projected overlay (geo-locked) ─────────────
   * Mapbox Marker elements can visually lag the map during trackpad
   * pinch (CSS blur/shadow re-raster cost). We instead project each
   * pin's lngLat to screen coordinates ourselves on every map move
   * and position plain DOM nodes in an overlay — they cannot drift. */
  const pinLayer = document.createElement("div");
  pinLayer.className = "cp-pin-layer";
  map.getContainer().appendChild(pinLayer);
  let activePins = []; // { el, lngLat, open } — DOM nodes we position

  function repositionPins() {
    if (!activePins.length) return;
    for (const p of activePins) {
      const pt = map.project(p.lngLat);
      p.el.style.transform = `translate(${pt.x}px, ${pt.y}px) translate(-50%, -100%)`;
      p.el.style.display = pt.x < -80 || pt.y < -80 ||
        pt.x > pinLayer.clientWidth + 80 || pt.y > pinLayer.clientHeight + 80
        ? "none" : "";
    }
  }
  map.on("move", repositionPins);
  map.on("zoom", repositionPins);
  map.on("resize", repositionPins);

  function clearPins() {
    for (const p of activePins) p.el.remove();
    activePins = [];
  }

  function showPins(pins) {
    clearPins();
    if (!pins.length) return;
    const bounds = new mapboxgl.LngLatBounds();
    for (const p of pins) {
      const el = document.createElement("div");
      el.className = "cp-pin";
      // Map-style teardrop pin (CSS: circle + rotated square tail)
      const head = document.createElement("div");
      head.className = "cp-pin-head";
      const rank = document.createElement("span");
      rank.className = "cp-pin-rank";
      rank.style.color = p.severity > 0.66 ? "var(--accent-hot)" : p.severity > 0.33 ? "var(--accent-warm)" : "var(--accent)";
      rank.textContent = pins.indexOf(p) + 1;
      head.appendChild(rank);
      const tip = document.createElement("div");
      tip.className = "cp-pin-tip";
      tip.innerHTML =
        `<div class="cp-pin-title">${p.title}</div>` +
        `<div class="cp-pin-metric">${p.metric}</div>` +
        `<div class="cp-pin-reco">${p.reco}</div>`;
      el.appendChild(head);
      el.appendChild(tip);
      el.addEventListener("click", (e) => {
        e.stopPropagation();
        // one open tooltip at a time
        for (const other of activePins) other.el.classList.remove("open");
        el.classList.add("open");
      });
      pinLayer.appendChild(el);
      activePins.push({ el, lngLat: p.lngLat });
      bounds.extend(p.lngLat);
    }
    repositionPins();
    map.fitBounds(bounds, { padding: 150, maxZoom: 14.8, duration: 900 });
  }

  /* ── public entry point (agent + dock buttons) ── */
  async function runTool(toolId) {
    if (!allFeatures.length) {
      toast("Load a simulation CSV first", false, true);
      return null;
    }
    await ensureBuildings();
    const tool = TOOLS[toolId];
    if (!tool) return null;

    // Dock toggle: clicking the active tool again clears the overlay
    if (lastToolId === toolId && activePins.length) {
      clearPins();
      lastToolId = null;
      lastResult = null;
      setActiveDockBtn(null);
      return null;
    }

    const result = tool.run(aggregate());
    result.tool = toolId;
    result.label = tool.label;
    showPins(result.pins);
    lastToolId = toolId;
    lastResult = result;
    setActiveDockBtn(toolId);
    return result;
  }

  function setActiveDockBtn(toolId) {
    for (const id of ["tool-congestion", "tool-peaks", "tool-hotspots", "tool-lighting", "tool-snow"]) {
      const el = document.getElementById(id);
      if (el) el.classList.toggle("active", id === toolId);
    }
  }

  return { runTool, TOOLS, get lastResult() { return lastResult; }, clearPins };
})();

/* ── dock button wiring (replaces the old mock handlers) ── */
document.getElementById("tool-congestion").addEventListener("click", () => ANALYTICS.runTool("congestion"));
document.getElementById("tool-peaks").addEventListener("click", () => ANALYTICS.runTool("peaks"));
document.getElementById("tool-hotspots").addEventListener("click", () => ANALYTICS.runTool("hotspots"));
document.getElementById("tool-lighting").addEventListener("click", () => ANALYTICS.runTool("lighting"));
document.getElementById("tool-snow").addEventListener("click", () => ANALYTICS.runTool("snow_priority"));

/* Re-run nothing automatically; the agent re-runs tools on demand. */
window.addEventListener("cp:ingest", () => ANALYTICS.clearPins());
