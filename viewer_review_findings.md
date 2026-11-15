# Objective Code Review — Campus Pulse viewer (`viewer/`)

**Date:** 2026-11-15 · **Scope:** read-only review of `viewer/` only
**Symptoms reported:** (1) clicking a building footprint does not open the insights panel (`#insight-panel`); (2) live-feed paths don't render while CSV-simulation paths do.
**Environment facts verified by reviewer:** server on :8080 is a single process serving byte-identical current files with `Cache-Control: no-store, must-revalidate`; `/api/v1/health` and `/api/v1/heatmap` return 200 through the proxy.

---

## 0. TL;DR — ranked root-cause hypotheses

| # | Symptom | Root cause (ranked) | Confidence | Key evidence |
|---|---------|--------------------|------------|--------------|
| 1 | Insights panel never opens | **Stale browser cache of pre-`no-store` `index.html` + `app.js`** (cached before commit `bddb893` added `no-store` at 09:47 today). Old `index.html` has no `<aside id="insight-panel">` and no `<script src="insights.js">`; old `app.js` has no `building-click` layer. `window.INSIGHTS` is undefined and `app.js:182`'s guard `if (window.INSIGHTS)` silently no-ops. | HIGH | git diff `bddb893~1..bddb893`; old `Cache-Control` absent; no SW/bfcache path needed |
| 2 | Insights panel doesn't open (fresh code, live/CSV mode) | **`app.js:181` agent-dot guard swallows the building click.** `if (map.queryRenderedFeatures(e.point, { layers: ["agent-dots"] }).length) return;` — with live data, ~250 stacked `agent-dots` features render per step (all `agent_id:"unknown"`), and with CSV data `IN_BUILDING` agents are also drawn as dots (`app.js:608`). Any footprint click that lands under a dot is dropped before `INSIGHTS.show()`. | MEDIUM-HIGH | app.js:174–183, 608; live capture shows 250 features/step |
| 3 | Live paths don't render (CSV paths do) | **Backend `/heatmap` returns `device_id: null` for nearly all real pings** → `app.js:331` `r.agent_id || r.device_id || "unknown"` collapses the whole fleet into one pseudo-agent `"unknown"`. The trail dedupe (`app.js:373–380`) keeps only building-change points, and `cometTrails`' 30-min window + singleton merge (`app.js:661–706`) yields ≈1 LineString. Executed the real code against a captured 45,025-point heatmap: `agents=4, trail feats=1`. CSV works because sim rows carry real per-agent ids and every TRANSIT ping is kept. | HIGH (mechanically reproduced) | live `/heatmap` capture: `device_id:null` on real points; harness output |

Hypotheses 1 and 3 are independent and can both be true on the user's machine. Hypothesis 2 is a genuine logic bug in the current code that produces the same symptom as 1 for occupied buildings.

---

## 1. Server-side review (`viewer/serve.py`) — essentially clean

1.1 `viewer/serve.py:109-113` — `end_headers()` adds `Cache-Control: no-store, must-revalidate` to **every** response (static and proxied). Verified live: `curl -I http://localhost:8080/app.js` → `HTTP/1.0 200 OK` + `Cache-Control: no-store, must-revalidate` + correct `Content-Length: 29680` + `Last-Modified`. No stale-directory risk: `Handler.__init__` pins `directory=ROOT` (`serve.py:44-46`), `ROOT` is `__file__`-derived (`serve.py:38`), so CWD is irrelevant. The running process (PID 34140, started 09:45:32, cwd = repo root) post-dates `serve.py`'s mtime (09:45:29) → it is running the current code.

1.2 Port conflicts ruled out: `lsof -nP -iTCP:8080 -sTCP:LISTEN` shows exactly one listener (PID 34140). A second `serve.py` instance cannot bind the same port; an *older* instance could only exist on a different port, and the browser is pointed at :8080 (per the verified serving facts). Also the server binds `127.0.0.1` only (`serve.py:154`).

1.3 HTTP/1.0: `SimpleHTTPRequestHandler` defaults to `protocol_version = "HTTP/1.0"` (visible in the curl output). Harmless for correctness (each response carries `Content-Length`), just no keep-alive. Not a bug.

1.4 `translate_path` `/configs/*` mapping (`serve.py:113-127`) correctly serves repo-root `configs/`; verified `GET /configs/buildings.json → 200`. Minor hardening note: when the sanitized `rel` is empty, `translate_path` returns the `configs/` directory itself, and `SimpleHTTPRequestHandler` will render a directory listing. Cosmetic/info-disclosure nit only.

1.5 One important *temporal* conclusion: `no-store` was itself added in commit **`bddb893` ("trying to make webdash work", 2026-11-15 09:47:03)** — the same commit that added `#insight-panel`, `insights.js`, and the `building-click` layer. Every page/scripts fetched **before** that moment was served **without** `Cache-Control`. Such responses carry only `Last-Modified`, which browsers may cache **heuristically** (typically 10% of (now − Last-Modified)) and reuse **without revalidating**. A normal (non-hard) reload may therefore keep serving the pre-09:47 `index.html`/`app.js` from disk cache. This is the load-bearing Family-1 fact.

## 2. Browser-side staleness review

2.1 Service workers: **none**. `grep -rn serviceWorker viewer/` → 0 hits; `index.html` registers nothing. Ruled out.

2.2 bfcache: possible for a *restored* tab (back/forward or session restore), but a plain reload escapes bfcache. Can produce a one-time stale view; cannot explain a persistent failure after reloads. Low-probability contributor.

2.3 Disk cache without `no-store` (the pre-09:47 responses): see 1.5 — **primary Family-1 mechanism**. Stale `index.html` (old revision) is self-reinforcing: it references only `app.js, analytics.js, agent.js, live.js` (`git show bddb893~1:viewer/index.html`, script block lines 92–99) — no `insights.js` at all — so even a "successful" reload fetches the *old* app and `window.INSIGHTS` never exists.

2.4 Mapbox GL JS / PapaParse CDN caches: irrelevant to staleness of app code; a CDN *failure* cascade is ruled out as the cause of symptom 1 because the user reports CSV paths working — which requires `mapboxgl` and `PapaParse` to have loaded and `app.js` to have run to completion. (If `app.js` had thrown at `viewer/app.js:16` (`mapboxgl.LngLatBounds`), CSV parsing would be dead too.)

## 3. `index.html` review

3.1 Script order (`viewer/index.html:92-107`): PapaParse → Mapbox GL → `app.js` → `analytics.js` → `agent.js` → `live.js` → `insights.js`. All classic (non-module) synchronous scripts at end of `<body>` — no `defer`/`async`. DOM above them is already parsed when they run. Order is **correct** for the dependency graph (analytics/agent consume `app.js`'s globals; live consumes `ingestRows`; insights is self-contained).

3.2 No inline scripts → no parse-abort risk from inline code. DOM ids referenced by scripts (`map, status, chat, chat-*, agent-*, insight-*, live-btn, csv-input, time-*, speed-select, ticks, tool-*, toggle-*, api-base`) all exist in the HTML — verified by cross-grep.

3.3 `#insight-panel` (`index.html:73-78`) is `class="glass agent-panel"` + `hidden`. CSS `.agent-panel` (`styles.css:238`) sets only position/size/z-index — **no `display` property** — and there is **no `[hidden] { display:... }` override anywhere** (`grep '\[hidden\]' styles.css` → 0 hits). Since `.agent-panel` never sets `display`, the UA default `[hidden] { display: none }` remains authoritative, and `panel.hidden = false` (`insights.js:259`) reliably reveals it. **CSS-hides-the-panel hypothesis: ruled out.**

## 4. Front-end load-order / initialization review (Family 2)

4.1 Cross-script globals: all five files are classic scripts; top-level `const`/`let` (`map`, `allFeatures`, `slider`, `currentStep`, …) live in the *global lexical environment* and are visible to later classic scripts as bare identifiers. `live.js` calls `ingestRows`, `setStep`, `slider`, `currentStep`, `timeMax` — all defined in `app.js`, which is fully evaluated before `live.js` even starts parsing (sequential classic scripts). TDZ is not an issue because `live.js`'s IIFE only *defines* functions at eval time; `pull()` runs on user click/timer, long after `app.js` finished. **Load-order mechanism: correct.**

4.2 `live.js` top-level code (`viewer/live.js:243-247`): only `document.addEventListener("contextmenu"…)` and `document.addEventListener("DOMContentLoaded", init)` — nothing that touches `app.js` state at eval time. `init()` (`live.js:216-251`) guards every lookup (`if (!btn) return;`, optional chaining on `input`). No top-level hazard found.

4.3 `insights.js` top-level: the IIFE touches only DOM APIs and registers listeners; `init()` guards `if (close)`. Nothing references `live.js`/`agent.js`. `window.INSIGHTS = INSIGHTS` is the last statement (`insights.js:271`). The only way `window.INSIGHTS` is undefined in a *current* page is `insights.js` never being loaded/fetched — which points back to a stale `index.html` (§2.3), not an eval-order crash.

4.4 Map load ordering: `map.on("load", …)` in `app.js:71` registers the `building-click` source/layer *asynchronously* via `ensureBuildingShapes().then(...)` (`app.js:159`). Registration order relative to `insights.js` is irrelevant because the click handler reads `window.INSIGHTS` **at click time**, not at registration time. By click time all five scripts have long finished. Correct.

4.5 **The agent-dot guard — genuine logic bug (`viewer/app.js:174-183`):**
```js
map.on("click", "building-click", (e) => {
  ...
  if (map.queryRenderedFeatures(e.point, { layers: ["agent-dots"] }).length) return;   // :181
  if (window.INSIGHTS) window.INSIGHTS.show(f.properties.building_id);                 // :182
});
```
- `mapboxgl.Map#on("click", layerId, …)` in v3.12.0 fires for **every** intersecting queryable layer (delegated listeners verified in the shipped bundle: `mapbox-gl.js` `_createDelegatedListener`/`_delegatedListeners`, char offset ≈1,492,889). So a click on a building that also has a rendered dot triggers *both* handlers.
- `app.js:608` renders dots for **both** `TRANSIT` **and** `IN_BUILDING` agents. In live mode the captured heatmap step contained **250 point features** (all `agent_id:"unknown"`), so occupied buildings are peppered with dots; any click landing within a dot's 3.5–7 px radius is silently swallowed. In CSV mode the same applies to every `IN_BUILDING` agent.
- Symptom signature: insights opens on *empty* buildings but not on *busy* ones — easy to misread as "never opens".
- Note the same guard is mirrored in the clear-selection handler (`app.js:207-211`) which correctly *preserves* the panel; only the `:181` guard suppresses opening.

4.6 Live-mode path rendering — mechanically reproduced (the strongest new evidence in this review):
- Captured the exact window `live.js` pulls (360 min lookback, `limit=50000`): **45,025 points, 183 timestamps, 09:56:00Z → 15:54:00Z, oldest-first** (matches `live.js` comment). Real pings carry **`device_id: null`** (5-device sample: one `ios-…`, two `probe-dev-*`, `unknown`, and `null` for the fleet).
- Executed `viewer/app.js`'s actual `normBuilding`/`parseTimestamp`/`timestampToStep`/`ingestRows`/`cometTrails` source in Node against that capture:
  ```
  ingest OK timeMin=0 timeMax=179 agents=4      ← whole campus = 4 "agents"
  trail feats: 1                                 ← comet trails: 1 LineString
  feats at final step: 250
  occupied buildings at final step: 44
  ```
- Why trails die: `app.js:331` `const agentId = r.agent_id || r.device_id || "unknown";` merges everyone into `"unknown"`; `app.js:373-380` then keeps a waypoint **only** when state/building changes (or TRANSIT), so the trail is a skeleton of first-arrivals; `cometTrails` (`app.js:661`) only draws the last `TRAIL_FADE_MIN=30` min (`cutoff = step − 15` steps, `app.js:666`) and merges singleton segments (`app.js:690-700`) until ~1 segment survives. Heat and dots still render (heat doesn't need agent identity), which is exactly "CSV paths render, live paths don't".
- CSV mode works because sim rows have real `agent_id`s and each agent's TRANSIT pings are all kept → dozens of fading segments per agent.

## 5. Secondary findings (correct, but worth noting)

5.1 `viewer/insights.js:43-49` `scrubClock()` + `:175-181`: in **live** mode the timeline label is derived from the server's **UTC** ISO timestamps (`stepToClock`, `app.js:746-757`, uses UTC getters), and `fillSection("story")` sends `date=todayLocal()` (local date) together with that UTC-clock `time`. In a UTC≠local timezone this queries the wrong hour window (CST −6 h) and can even 422 near midnight. Objective correctness bug in live mode (does not affect panel *opening*).

5.2 `viewer/live.js:126-133`: on `j.count >= LIMIT` it correctly warns about oldest-first truncation. With LIMIT=50000 and ~4.5k pings/h a 6 h window (~27k) is safe; fine.

5.3 `viewer/live.js:143-147` empty-window path returns without dispatching `cp:live-poll`; the button stays "on — no pings yet". Intentional; fine.

5.4 `viewer/serve.py:149-151` default `--api` falls back to `http://localhost:8000/api/v1`; the actual `.env` points at a `trycloudflare.com` tunnel. Health/heatmap 200s confirm the tunnel is alive. Not a bug.

5.5 Security nits (out of the two symptoms but in scope as "risks"): `viewer/app.js:9` ships a public Mapbox token with no URL restrictions visible from the repo — recommend restricting the token to your origins in the Mapbox dashboard. `viewer/agent.js:20-23` supports pasting an OpenRouter key into client JS (`CONFIG.apiKey`) — currently empty, but if ever filled it becomes a leaked credential (bundle-visible to anyone); keep it server-side. `serve.py` `/configs/` directory listing nit (§1.4).

5.6 `viewer/app.js:226-240` wheel-forwarding loop runs at script eval time over `.glass` nodes — all exist in static HTML; fine.

## 6. What was explicitly ruled out (with evidence)

| Hypothesis | Evidence against |
|---|---|
| Server serving stale files / wrong directory | byte-identical verified (given); `directory=ROOT` from `__file__` (`serve.py:44-46`); mtimes: serve.py 09:45:29 < process start 09:45:32 |
| Two `serve.py` instances / port conflict | single LISTEN socket, PID 34140 |
| Missing `Cache-Control` on current server | `curl -I /app.js` shows `no-store, must-revalidate` |
| Service worker serving stale assets | zero `serviceWorker` references in `viewer/` |
| CSS hiding `#insight-panel` / specificity bug | `.agent-panel` sets no `display` (`styles.css:238-244`); no `[hidden]` overrides anywhere in `styles.css` |
| Script load-order crash / TDZ | classic scripts, sequential; `live.js`/`insights.js` top-levels touch no `app.js` state; all referenced DOM ids exist |
| Mapbox/PapaParse CDN failure cascade | CSV paths render ⇒ mapboxgl + PapaParse loaded and `app.js` ran to completion |
| Backend down for live feed | `/health` → `{"status":"ok","store_ok":true}`; `/heatmap` → 200 with 45k points |

## 7. DevTools verification recipe (for the human, in their browser)

**Step 1 — prove which code revision the browser is running (tests Hypothesis 1):**
1. Open `http://localhost:8080`, DevTools → **Network** tab, check ☑ **Disable cache**, then **hard reload** (⌘⇧R).
2. In the Network list click `index.html` → **Response** tab: it must contain `<aside id="insight-panel"` and `<script src="insights.js">`. If **absent → stale cache confirmed**; do one more hard reload with cache disabled and re-check.
3. In the **Console** run: `!!document.getElementById("insight-panel")` → must be `true`; `typeof window.INSIGHTS` → must be `"object"`. If `undefined`, `insights.js` didn't load or threw — check Network for its status and Console for a red error above it.
4. In **Sources**, open `app.js` and confirm line ~174 contains `map.on("click", "building-click"` (pre-`bddb893` app.js has no such string — `Ctrl/Cmd-F` for `building-click`). Absence = stale app.js.
5. Also check **Application → Service Workers** (expect "none for this origin") to close out §2.1.

**Step 2 — test the click pipeline directly (tests Hypothesis 2):**
6. With the panel absent, Console:
   `map.queryRenderedFeatures({layers:["building-click"]}).length` → should be 87 (all footprints). `0` ⇒ the click layer never loaded (fetch of `/configs/buildings.json` failed — check Network).
7. Simulate the exact click bypassing the guard:
   `const f = map.queryRenderedFeatures({layers:["building-click"]})[0]; window.INSIGHTS.show(f.properties.building_id)` → panel must open and fill. If it opens here but not on real clicks, the `app.js:181` agent-dot guard is eating your clicks — hover a busy building: if the cursor shows *pointer* only in dot-free spots, that's it. Confirm by clicking a building with no dots inside vs one with dots.
8. Watch the Console while clicking a footprint: the `building-click` handler has no logging; temporarily (in DevTools, live-edit) add `console.log("bclick", e.features?.[0]?.properties?.building_id)` at the top of the handler at `app.js:174` to see whether Mapbox delivers the event at all.

**Step 3 — prove the live-paths root cause (tests Hypothesis 3):**
9. Toggle the live feed on. In Console after the pull toast:
   `Object.keys(byAgent ?? {})` is not exposed; instead use the observable proxy — count dots vs trails: `map.queryRenderedFeatures({layers:["agent-dots"]}).length` (expect ~hundreds at a busy step) versus switching paths off/on (`#toggle-paths`) and watching the map: you will see dots + heat but essentially **one** short violet segment.
10. Direct data check in Console:
    `fetch("/api/v1/heatmap?start=" + new Date(Date.now()-36e5).toISOString() + "&end=" + new Date().toISOString() + "&limit=5").then(r=>r.json()).then(j=>console.table(Object.values(j.data)[0]))` → observe `device_id: null` on real pings. That null is why everything collapses into the `"unknown"` agent (`app.js:331`) and why per-agent comet trails can't form. Fix belongs in the pinging backend (populate `device_id` on `/heatmap` rows); a viewer-side mitigation would be keying trails by lat/lng-change clusters, but that is a design change.

**Step 4 — final clean-slate control:** quit the browser entirely (or DevTools → Application → Clear storage → Clear site data), relaunch, load `http://localhost:8080`, and repeat steps 2–3. If everything passes there, the incident was 100% stale-cache (Hypothesis 1) plus the dot-guard (Hypothesis 2) for any residual occupied-building clicks.

---

## 8. Reviewer-verdict summary

- The **server and current static assets are healthy**; the two symptoms are client-side.
- Symptom 1 (insights): most probably a **stale pre-`no-store` cached `index.html`+`app.js`** (H1) — the same commit that added the feature also added the cache header, so any pre-09:47 cached copy lacks the feature entirely — with a real residual bug where **occupied buildings' clicks are swallowed by the `agent-dots` guard** (`app.js:181`, H2).
- Symptom 2 (live paths): **not a rendering bug** — live data is ingested and rendered, but `device_id: null` collapses the fleet into one pseudo-agent whose deduped, 30-min-windowed trail degenerates to ~1 segment (`app.js:331, 373-380, 661-706`; reproduced: `agents=4, trail feats=1`). CSV paths work because sim rows carry per-agent ids. Fix the backend's `/heatmap` `device_id` population.
