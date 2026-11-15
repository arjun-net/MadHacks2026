/* ── Campus Pulse — building insights (story + prediction) ──────
 * Click any building footprint → panel with:
 *   • /story        "How busy is it vs. normal?" (past/current moment)
 *   • /prediction   "What's typical at this time?" (historical baseline)
 *
 * Both hit the Rust backend through the same-origin proxy (serve.py),
 * GET /api/v1/buildings/{building}/{story|prediction}. Building ids are
 * the exact stored location_events values (configs/buildings.json ids).
 *
 * Counting model (per API guide): these are location_observations —
 * recorded rows, NOT unique visitors or verified occupancy. The copy
 * below says "recorded observations", never "people".
 * ───────────────────────────────────────────────────────────────── */

const INSIGHTS = (() => {
  const WEEKS = 8;          // comparison weekdays (server range 2–12)
  const WINDOW_MIN = 15;    // ±15 min around the selected time

  const $ = (id) => document.getElementById(id);
  let current = null;       // { slug, name } shown in the panel
  let token = 0;            // invalidates in-flight renders on switch/close

  /* Same base as the live feed: api-base input → localStorage → proxy */
  function apiBase() {
    const inp = $("api-base");
    const v = inp && inp.value.trim();
    return v || localStorage.getItem("cp.apiBase") || "/api/v1";
  }

  function pad(n) { return String(n).padStart(2, "0"); }

  function todayLocal() {
    const d = new Date();
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  }

  /* Scrubbed timeline clock (e.g. "14:30", possibly "09:10+2d" for a
   * day offset in the simulated data). Returns null when the label is
   * unparseable (server then uses its own current time), and marks
   * day-offset labels so a mismatched-day time is NOT sent to the API
   * (a simulated past day's clock paired with today's date would be a
   * fabricated query). */
  function scrubClock() {
    const t = ($("time-label") || {}).textContent || "";
    const m = t.match(/^(\d{1,2}:\d{2})(?:\+(\d+)d)?/);
    if (!m) return null;
    return m[2] ? null : m[1]; // +Nd offset → let the server use "now"
  }

  function esc(s) {
    const d = document.createElement("div");
    d.textContent = String(s == null ? "" : s);
    return d.innerHTML;
  }

  /* Display name: configs/buildings.json id → name (cached). */
  let nameCache = null; // promise of Map<id, name> — cached as a promise
  async function displayName(slug) {
    if (!nameCache) {
      // Cache the promise itself so concurrent show() calls share one
      // fetch instead of the second seeing an empty map.
      nameCache = fetch("/configs/buildings.json")
        .then((r) => r.json())
        .then((j) => {
          const m = new Map();
          for (const b of j.buildings) m.set(b.id, b.name);
          return m;
        })
        .catch(() => new Map()); // fall back to the raw slug
    }
    const m = await nameCache;
    return m.get(slug) || slug;
  }

  async function fetchKind(slug, kind, params) {
    const qs = new URLSearchParams(params).toString();
    const url =
      `${apiBase()}/buildings/${encodeURIComponent(slug)}/${kind}` +
      (qs ? `?${qs}` : "");
    let r;
    try {
      r = await fetch(url);
    } catch (e) {
      throw new Error("network error — is the API server up?");
    }
    if (!r.ok) {
      const why =
        r.status === 422 ? "invalid date/time parameters"
        : r.status === 503 ? "analytics backend not configured on the server"
        : r.status === 502 ? "warehouse query failed"
        : `HTTP ${r.status}`;
      const err = new Error(why);
      err.status = r.status;
      throw err;
    }
    return r.json();
  }

  /* ── rendering ──────────────────────────────────────────────── */

  function statRow(label, value) {
    return `<div class="panel-row"><span>${esc(label)}</span><b>${esc(value)}</b></div>`;
  }

  function renderStory(container, data) {
    const c = (data && data.current) || {};
    if (c.status === "available") {
      const diff = data.difference_vs_weekday_average_pct;
      const diffTxt = diff == null ? "—" :
        `${diff > 0 ? "+" : ""}${Math.round(diff)}%`;
      const diffCls = diff == null ? "" : diff >= 0 ? "up" : "down";
      container.innerHTML =
        `<div class="ins-section-title">Activity story · now</div>` +
        `<div class="ins-story">${esc(data.story || "—")}</div>` +
        statRow("observations", `${c.observations ?? "—"}`) +
        statRow("same-weekday avg", `${data.weekday_average ?? "—"}`) +
        `<div class="panel-row"><span>vs average</span>` +
        `<b class="ins-diff ${diffCls}">${diffTxt}</b></div>` +
        `<div class="ins-note">recorded observations, not unique visitors</div>`;
    } else if (c.status === "suppressed") {
      container.innerHTML =
        `<div class="ins-section-title">Activity story · now</div>` +
        `<div class="ins-empty">Not enough activity data to display.</div>`;
    } else {
      // no_data / missing
      container.innerHTML =
        `<div class="ins-section-title">Activity story · now</div>` +
        `<div class="ins-empty">No activity data for this time.</div>`;
    }
  }

  function renderPrediction(container, data) {
    const p = (data && data.prediction) || {};
    if (p.status === "available") {
      const lo = p.typical_p25, hi = p.typical_p75, exp = p.expected_observations;
      // Range bar: p25–p75 window on a 0 … max(hi, exp)*1.35 scale
      const top = Math.max(hi ?? 0, exp ?? 0, 1) * 1.35;
      const lPct = lo != null ? Math.min(100, (lo / top) * 100) : 0;
      const wPct = hi != null && lo != null
        ? Math.max(4, ((hi - lo) / top) * 100) : 0;
      const ePct = exp != null ? Math.min(100, (exp / top) * 100) : 0;
      container.innerHTML =
        `<div class="ins-section-title">Prediction · typical for this time</div>` +
        `<div class="ins-story">${esc(data.summary || "—")}</div>` +
        statRow("expected", `~${p.rounded_observations ?? exp ?? "—"}`) +
        `<div class="panel-row"><span>typical range</span><b>${esc(lo != null ? lo : "?")}–${esc(hi != null ? hi : "?")}</b></div>` +
        `<div class="ins-range"><span class="ins-range-band" style="left:${lPct}%;width:${wPct}%"></span>` +
        `<span class="ins-range-mark" style="left:${ePct}%"></span></div>` +
        statRow("reliability", esc(p.reliability || "—")) +
        `<div class="ins-note">historical baseline of ${data.samples_used ?? "?"} similar days` +
        `${data.outliers_excluded ? ` · ${data.outliers_excluded} outliers excluded` : ""}</div>`;
    } else {
      // insufficient_history etc. — show summary copy, no numbers
      container.innerHTML =
        `<div class="ins-section-title">Prediction · typical for this time</div>` +
        `<div class="ins-empty">${esc(data.summary || "Needs more historical data.")}</div>`;
    }
  }

  function renderError(container, kindLabel, kind, err) {
    container.innerHTML =
      `<div class="ins-section-title">${esc(kindLabel)}</div>` +
      `<div class="ins-empty">Unavailable — ${esc(err.message || err)}</div>` +
      `<button class="ins-retry" data-kind="${kind}">Retry</button>`;
  }

  /* One section at a time so story and prediction stream in
   * independently; `my` token discards stale responses. */
  async function fillSection(kind) {
    const my = token;
    const box = kind === "story" ? $("ins-story-box") : $("ins-pred-box");
    if (!box || !current) return;
    box.innerHTML = `<div class="ins-loading">…</div>`;
    const params = { weeks: WEEKS, window_minutes: WINDOW_MIN };
    const t = scrubClock();
    if (t) params.time = t;
    try {
      let data;
      if (kind === "story") {
        // Future scrub time today can 422 — fall back to server "now".
        data = await fetchKind(current.slug, "story", { ...params, date: todayLocal() });
      } else {
        data = await fetchKind(current.slug, "prediction", params);
      }
      if (my !== token || !current) return;
      if (kind === "story") renderStory(box, data);
      else renderPrediction(box, data);
    } catch (err) {
      if (my !== token) return;
      // Story 422 with a scrubbed time: retry with server-default time.
      if (kind === "story" && err.status === 422 && params.time) {
        try {
          const data = await fetchKind(current.slug, "story",
            { weeks: WEEKS, window_minutes: WINDOW_MIN, date: todayLocal() });
          if (my !== token) return;
          renderStory(box, data);
          return;
        } catch (err2) {
          if (my !== token) return;
          renderError(box, "Activity story", "story", err2);
          return;
        }
      }
      renderError(box, kind === "story" ? "Activity story" : "Prediction",
        kind, err);
    }
  }

  function render() {
    const title = $("insight-title");
    const body = $("insight-body");
    if (!title || !body || !current) return;
    title.textContent = current.name;
    body.innerHTML =
      `<div id="ins-story-box"></div>` +
      `<div id="ins-pred-box"></div>`;
    fillSection("story");
    fillSection("prediction");
  }

  /* Delegated retry clicks */
  document.addEventListener("click", (e) => {
    const btn = e.target.closest && e.target.closest(".ins-retry");
    if (btn && current) {
      const kind = btn.dataset.kind === "story" ? "story" : "prediction";
      const box = kind === "story" ? $("ins-story-box") : $("ins-pred-box");
      if (box) box.innerHTML = `<div class="ins-loading">…</div>`;
      fillSection(kind);
    }
  });

  /* ── public API ─────────────────────────────────────────────── */

  async function show(slug) {
    // Bump the token FIRST so an earlier in-flight show() can't stomp
    // this one after its await resolves, and drop stale results.
    const my = ++token;
    const name = await displayName(slug);
    if (my !== token) return;
    current = { slug, name };
    // Opening insights closes the agent detail panel (same screen slot).
    const ap = $("agent-panel");
    if (ap) ap.hidden = true;
    const panel = $("insight-panel");
    if (!panel) return;
    panel.hidden = false;
    render();
  }

  function hide() {
    token++;
    current = null;
    const panel = $("insight-panel");
    if (panel) panel.hidden = true;
  }

  function init() {
    const close = $("insight-close");
    if (close) close.addEventListener("click", hide);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }

  return { show, hide, get current() { return current; } };
})();

window.INSIGHTS = INSIGHTS;
