/* ── Campus Pulse — live server feed ─────────────────────────────
 * Pulls analyzed pings from the Campus Location API (Rust/axum, see
 * pinging_api/ingest) instead of a manually uploaded CSV, then feeds
 * them through the same ingestRows() path in app.js.
 *
 * API surface used (openapi 3.0.3, base …/api/v1):
 *   GET /health              → { status, store_ok }
 *   GET /heatmap?start&end   → { start, end, count,
 *                                data: { "<ISO ts>": [ {lat, lng, building}, … ] } }
 *
 * building is a slug ("morgridge_hall") or null (no match) — ingestRows
 * maps those to IN_BUILDING / TRANSIT respectively.
 * ───────────────────────────────────────────────────────────────── */

const LIVE = (() => {
  /* Same-origin default: viewer/serve.py proxies /api/v1/* to the Campus
   * Location API (the tunnel sends no CORS headers, so direct browser
   * fetches are blocked — the proxy sidesteps that). Shift-click the
   * live button to point at a different base. */
  const DEFAULT_BASE = "/api/v1";

  // Window pulled per refresh. Each poll re-ingests the whole window
  // (ingestRows resets the buffers), so keep it modest. The live fleet
  // produces ~150 pings per 2-min tick ≈ 4.5k/h, and /heatmap returns
  // points OLDEST first — a window bigger than LIMIT/4.5k would push the
  // freshest pings past the limit and show stale data.
  const LOOKBACK_MIN = 360;   // 6 h of campus life ≈ 27k points
  const LIMIT = 50000;
  const POLL_MS = 60000;      // re-pull cadence; writes flush every 5 s
  const MAX_BACKOFF_MS = 600000; // poll interval ceiling after failures

  let base = DEFAULT_BASE;
  let timer = null;
  let busy = false;
  let lastCount = null;
  let lastEnd = null;   // ms — end of the last successful heatmap window
  let pollMs = POLL_MS;     // current interval; backs off after failures
  let currentInterval = POLL_MS; // interval the live timer is armed at

  const $btn = () => document.getElementById("live-btn");

  function setBtn(state, title) {
    const b = $btn();
    if (!b) return;
    // active and error are mutually exclusive states
    b.classList.toggle("active", state === "on");
    b.classList.toggle("error", state === "error");
    if (state === "error") b.classList.remove("active");
    if (title) b.title = title;
  }

  function toast(msg, sticky, err) {
    if (window.toast) window.toast(msg, sticky, err);
  }

  /* --- config: base URL from the API base input or localStorage --- */
  function readBase() {
    const input = document.getElementById("api-base");
    if (input && input.value.trim()) base = input.value.trim().replace(/\/+$/, "");
    else base = localStorage.getItem("cp.apiBase") || DEFAULT_BASE;
    if (input) input.value = base;
    localStorage.setItem("cp.apiBase", base);
  }

  /* --- timestamp helpers: ISO strings, tz-aware (API requires tz) --- */
  function isoAgo(minutes) {
    return new Date(Date.now() - minutes * 60000).toISOString().replace(/\.\d{3}Z$/, "Z");
  }

  /* --- API calls --- */
  async function checkHealth() {
    const r = await fetch(`${base}/health`, { headers: { Accept: "application/json" } });
    if (!r.ok) throw new Error(`health ${r.status}`);
    const j = await r.json();
    if (!j.store_ok) throw new Error("server up, database unreachable");
    return j;
  }

  /* Total points across all timestamps (fallback when count is absent). */
  function rowsTotal(j) {
    let n = 0;
    for (const pts of Object.values(j?.data || {})) n += (pts || []).length;
    return n;
  }

  /* Flatten the heatmap response into ping rows for ingestRows().
   * device_id (added to the /heatmap contract) becomes agent_id so
   * per-device path tracing works in live mode like it does for CSVs. */
  function heatmapToRows(j) {
    const rows = [];
    const data = j && j.data;
    if (!data) return rows;
    for (const [ts, points] of Object.entries(data)) {
      for (const p of points || []) {
        // Rows without a device_id can't be attributed to any device; the
        // bulk sender currently sends ~250 of these per 2-min tick. Feeding
        // them to ingestRows would collapse them into one fake "unknown"
        // agent whose interleaved TRANSIT trail draws a garbage campus-wide
        // line. Skip them — building heat and the density layer still
        // render from the byStep buckets they DO feed (see heat_only rows).
        const device = p.device_id;
        if (device == null || device === "") {
          rows.push({
            lat: p.lat,
            lng: p.lng,
            heat_only: true,       // counted for heat, excluded from agents
            timestamp: ts,
            building: p.building,
          });
          continue;
        }
        rows.push({
          lat: p.lat,
          lng: p.lng,
          device_id: device,       // present → per-device path tracing
          timestamp: ts,           // UTC ISO-8601 — parseTimestamp() handles it
          building: p.building,    // slug or null
        });
      }
    }
    return rows;
  }

  async function pull({ quiet = false, keepTime = false } = {}) {
    if (busy) return;
    busy = true;
    try {
      if (!quiet) {
        toast("Pulling live data…", true);
        setBtn("on", "Live feed — updating…");
      }
      const prevStep = keepTime && typeof currentStep === "number" ? currentStep : null;

      await checkHealth();
      // Every pull fetches the full lookback window (ingestRows resets
      // the buffers and rebuilds from scratch, so deltas can't be
      // appended). With LIMIT=50000 and a 2-min ping grid that covers
      // the busiest realistic window.
      const end = isoAgo(0);
      const start = isoAgo(LOOKBACK_MIN);
      const url = `${base}/heatmap?start=${encodeURIComponent(start)}`
        + `&end=${encodeURIComponent(end)}&limit=${LIMIT}`;
      const r = await fetch(url, { headers: { Accept: "application/json" } });
      if (!r.ok) {
        let detail = `${r.status}`;
        try { detail = (await r.json()).detail || detail; } catch (_) { /* plain status */ }
        throw new Error(`heatmap ${detail}`);
      }
      const j = await r.json();
      const nullPings = Object.values(j.data || {}).reduce(
        (n, pts) => n + (pts || []).filter((p) => p.device_id == null || p.device_id === "").length, 0);
      if (nullPings > 0) {
        console.warn(`[live] ${nullPings} pings have no device_id — they feed building heat but not device paths. ` +
          "The bulk sender must include device_id for per-device paths.");
      }
      lastEnd = Date.parse(j.end);
      pollMs = POLL_MS; // success resets backoff
      if (j.count >= LIMIT) {
        // Oldest-first truncation hit the cap: recent pings were cut off.
        console.warn("[live] heatmap hit limit", LIMIT, "— widening window beyond lookback");
        toast(`Server window saturated (${j.count.toLocaleString()} ≥ ${LIMIT.toLocaleString()}) — showing oldest ${LIMIT.toLocaleString()} points`, true);
      }
      // spec: count is required, but tolerate servers that omit it
      j.count = j.count ?? rowsTotal(j);
      const rows = heatmapToRows(j);
      if (!rows.length) {
        if (lastCount === null) {
          lastCount = 0;
          toast("Server reachable — no pings in the last 12 h window yet", true);
        }
        setBtn("on", "Live feed on — no pings yet");
        return;
      }
      // ingestRows resets the buffers and rebuilds from the given rows,
      // so each poll is a full re-ingest of the window. LIMIT is capped
      // at 50000 (the API default) to keep that rebuild cheap.
      ingestRows(rows, { quiet: true });

      // Jump the scrubber to the freshest step (or keep it pinned while polling)
      slider.max = timeMax;
      slider.value = timeMax;
      if (!keepTime) setStep(timeMax);
      else setStep(Math.min(prevStep ?? timeMax, timeMax));

      const delta = lastCount === null ? "" :
        (j.count - lastCount > 0 ? ` · +${(j.count - lastCount).toLocaleString()} new` : "");
      lastCount = j.count;
      toast(`Live: ${j.count.toLocaleString()} pings from server${delta}`);
      setBtn("on", "Live feed on — click to stop");
      window.dispatchEvent(new CustomEvent("cp:live-poll", { detail: { count: j.count } }));
    } catch (err) {
      console.error("[live] pull failed:", err);
      // TypeError from fetch() = network/CORS failure
      const msg = err instanceof TypeError ? "network error (server down or CORS blocked)" : err.message;
      if (!quiet || lastCount === null) {
        toast(`Live feed error: ${msg} — check the server URL`, quiet ? true : false, true);
      }
      setBtn("error", `Live feed error — ${msg} · retrying every ${Math.round(pollMs / 1000)}s`);
      if (timer) {
        // Timer-driven poll failed: back off so a dead server doesn't
        // spam requests. Doubling up to MAX_BACKOFF_MS; the next
        // successful poll resets the cadence.
        startPolling(); // re-arm at the new interval
      }
    } finally {
      busy = false;
    }
  }

  /* --- replay: load an arbitrary [start, end) window ---------------
   * Fetched in 6 h chunks so a long range never hits the API's per-call
   * limit (oldest-first truncation would silently drop the window's end).
   * Stops live polling — the scrubber then replays the loaded window. */
  const REPLAY_CHUNK_MS = 6 * 3600000;
  const REPLAY_LIMIT = 200000;       // API max per call
  const REPLAY_MAX_MS = 72 * 3600000;

  const isoMs = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");

  async function loadRange(startMs, endMs, onProgress) {
    if (!(endMs > startMs)) throw new Error("end must be after start");
    if (endMs - startMs > REPLAY_MAX_MS) throw new Error("range too long (max 72 h)");
    stopPolling();
    const b = $btn();
    if (b) { b.classList.remove("active", "error"); b.title = "Live feed off — click to connect"; }
    readBase();
    let rows = [];
    for (let s = startMs; s < endMs; s += REPLAY_CHUNK_MS) {
      const e = Math.min(s + REPLAY_CHUNK_MS, endMs);
      if (onProgress) onProgress(s - startMs, endMs - startMs);
      const url = `${base}/heatmap?start=${encodeURIComponent(isoMs(s))}`
        + `&end=${encodeURIComponent(isoMs(e))}&limit=${REPLAY_LIMIT}`;
      const r = await fetch(url, { headers: { Accept: "application/json" } });
      if (!r.ok) {
        let detail = `${r.status}`;
        try { detail = (await r.json()).detail || detail; } catch (_) { /* plain status */ }
        throw new Error(`heatmap ${detail}`);
      }
      const j = await r.json();
      if (j.count >= REPLAY_LIMIT) throw new Error("too many points in a 6 h chunk");
      rows = rows.concat(heatmapToRows(j));
    }
    if (!rows.length) throw new Error("no pings in that time frame");
    ingestRows(rows, { quiet: true });
    slider.max = timeMax;
    setStep(timeMin);
    lastCount = null;
    window.dispatchEvent(new CustomEvent("cp:replay-loaded", { detail: { count: rows.length } }));
    return rows.length;
  }

  function initReplay() {
    const btn = document.getElementById("replay-btn");
    const panel = document.getElementById("replay-panel");
    if (!btn || !panel) return;
    const $s = document.getElementById("replay-start");
    const $e = document.getElementById("replay-end");
    const $go = document.getElementById("replay-go");
    const $msg = document.getElementById("replay-msg");
    const say = (t, err) => { $msg.textContent = t; $msg.classList.toggle("err", !!err); };
    // datetime-local value <-> UTC ms
    const toInput = (ms) => new Date(ms).toISOString().slice(0, 16);
    const fromInput = (v) => Date.parse(v + ":00Z");
    const setRange = (a, z) => { $s.value = toInput(a); $e.value = toInput(z); };
    const DAY = 86400000;

    const presets = {
      "6h": () => { const n = Date.now(); return [n - 6 * 3600000, n]; },
      "24h": () => { const n = Date.now(); return [n - DAY, n]; },
      today: () => { const d = Math.floor(Date.now() / DAY) * DAY; return [d, d + DAY]; },
      yesterday: () => { const d = Math.floor(Date.now() / DAY) * DAY; return [d - DAY, d]; },
      "3d": () => { const n = Date.now(); return [n - 3 * DAY, n]; },
    };
    panel.querySelectorAll("[data-preset]").forEach((el) =>
      el.addEventListener("click", () => setRange(...presets[el.dataset.preset]())));

    btn.addEventListener("click", () => {
      panel.hidden = !panel.hidden;
      btn.classList.toggle("active", !panel.hidden);
      if (!panel.hidden && !$s.value) setRange(...presets["6h"]());
    });

    $go.addEventListener("click", async () => {
      const a = fromInput($s.value), z = fromInput($e.value);
      if (!Number.isFinite(a) || !Number.isFinite(z)) return say("Pick a start and end.", true);
      $go.disabled = true;
      try {
        say("Loading…");
        const n = await loadRange(a, z, (done, total) =>
          say(`Loading… ${Math.round((done / total) * 100)}%`));
        say(`Loaded ${n.toLocaleString()} pings — press ▶ to replay.`);
        toast(`Replay: ${n.toLocaleString()} pings`);
      } catch (err) {
        console.error("[replay]", err);
        say(err instanceof TypeError ? "Network error — is the server up?" : err.message, true);
      } finally {
        $go.disabled = false;
      }
    });
  }

  function startPolling() {
    stopPolling();
    timer = setInterval(() => {
      pull({ quiet: true, keepTime: true }).then(() => {
        if (timer) {
          // After any timer tick, re-arm so an interval change
          // (backoff/recovery) takes effect from the next tick on.
          if (pollMs !== currentInterval) {
            currentInterval = pollMs;
            startPolling();
          }
        }
      });
    }, pollMs);
    currentInterval = pollMs;
  }
  function stopPolling() {
    if (timer) { clearInterval(timer); timer = null; }
  }

  /* --- wiring --- */
  function init() {
    const btn = $btn();
    if (!btn) return;
    btn.addEventListener("click", (e) => {
      const input = document.getElementById("api-base");
      // Shift-click (or right-click): reveal/hide the API base input
      if (e.shiftKey || e.type === "contextmenu") {
        e.preventDefault();
        if (input) input.style.display = input.style.display === "none" ? "block" : "none";
        return;
      }
      const on = btn.classList.contains("active");
      readBase();
      if (on) {
        // Toggle off: back to manual mode; reset cadence + delta baseline
        // so the next connection starts fresh.
        stopPolling();
        pollMs = POLL_MS;
        lastCount = null;
        btn.classList.remove("active");
        btn.title = "Live feed off — click to connect";
        toast("Live feed off");
      } else {
        pull().then(() => {
          if (btn.classList.contains("error")) return; // failed — stay off
          btn.classList.add("active");
          startPolling();
        });
      }
    });
    const input = document.getElementById("api-base");
    input?.addEventListener("keydown", (e) => {
      // Enter applies the base and re-pulls — but only when the feed is
      // on; otherwise a stray Enter shouldn't pull data silently.
      if (e.key === "Enter" && btn.classList.contains("active")) {
        e.preventDefault(); readBase(); pull();
      }
    });
    input?.addEventListener("change", () => {
      readBase();
      if (btn.classList.contains("active")) pull();
    });
    // Restore last used base
    const saved = localStorage.getItem("cp.apiBase");
    if (saved && input) input.value = saved;
  }

  document.addEventListener("contextmenu", (e) => {
    if (e.target.closest && e.target.closest("#live-btn")) e.preventDefault();
  });

  document.addEventListener("DOMContentLoaded", init);
  document.addEventListener("DOMContentLoaded", initReplay);

  return {
    pull,
    loadRange,
    startPolling,
    stopPolling,
    get base() { return base; },
    get enabled() { return timer !== null; },
  };
})();

window.LIVE = LIVE;
