# Campus Pulse — Analytics layer & Databricks swap-in guide

## What's where

| File | Role |
|---|---|
| `viewer/analytics.js` | The **seam**: `ANALYTICS.runTool(toolId)` → `{title, summary, pins}` and map pins |
| `viewer/agent.js` | Chat assistant; never touches data — only calls `ANALYTICS.runTool` |
| `viewer/index.html` | Dock buttons (`tool-snow`, `tool-lighting`, …) + chat widget |
| `docs/databricks-streaming-blueprint.md` | Full streaming architecture (distill-first design) |

## Current state: client-side stand-ins

`aggregate()` in `analytics.js` computes everything from the loaded CSV in the
browser (grid bins ~167m×180m; day = 7:00–22:00, night = 22:00–7:00, morning =
7:00–9:30). Six tools ship:

| tool id | Question it answers | Pin metric |
|---|---|---|
| `snow_priority` | Where to clear snow first | 7:00–9:30am pedestrian load |
| `lighting` | Where lights buy the most safety | day/night exposure ratio |
| `deadzones` | Night corridors with no daytime eyes | solo night crossings |
| `congestion` | Morning crush points | 7:00–9:30am crossings |
| `hotspots` | All-day centers of gravity | sustained daytime presence |
| `peaks` | When each building peaks | peak hour + total occupancy |

These produce correct results for the demo, but they are **stand-ins** — same
contract, different backend.

## Swapping in Databricks

The streaming pipeline (see the blueprint doc) continuously rolls raw pings
into a snapshot table:

```
campus_ticks_snapshot:  tick_ts, cell_idx, cell_lat, cell_lng, count
campus_building_occupancy: tick_ts, building_id, count
```

Replace **only** `aggregate()` (and `buildingHours()`) in `analytics.js` with
fetches against your Databricks Apps endpoint. Everything else — tools, agent,
pins, dock — stays untouched:

```js
async function aggregate() {
  // BEFORE (client-side stand-in):
  //   ...scan allFeatures into a Map of grid bins...

  // AFTER (Databricks-backed):
  const r = await fetch(`${DBX_BASE}/api/1.0/campus/density?start=${startTs}&end=${endTs}`);
  const rows = (await r.json()).data;            // [{cell_lat, cell_lng, day, night, morning}]
  const cells = new Map();
  for (const row of rows) {
    const key = binKey(row.cell_lat, row.cell_lng);
    cells.set(key, { day: row.day, night: row.night, morning: row.morning });
  }
  return cells;
}
```

Key properties that make the swap trivial:

1. **Same grain.** The snapshot table is aggregated to the same
   cell/window buckets (`campus_ticks_snapshot` already carries `cell_idx`).
   The tool definitions and pin logic don't change at all.
2. **Never raw pings.** The dashboard queries only the distilled snapshot —
   sub-second serverless warehouse queries, no rate-limit exposure, cold-start
   covered by the app-tier cache (serve last snapshot + timestamp).
3. **Async-ready.** `runTool()` is already `async`; make `aggregate()` return
   a Promise and add a loading toast. No signature changes elsewhere.
4. **Agent unchanged.** The agent's `run_analytics` tool serializes
   `{title, summary, top_pins}` into the model context — it never needs to
   know where the numbers came from.

### Endpoint sketch (Databricks Apps FastAPI)

```
GET /api/v1/density?start=<ts>&end=<ts>[&bbox=minLng,minLat,maxLng,maxLat]
  → { start, end, data: [{cell_lat, cell_lng, day, night, morning}] }

GET /api/v1/occupancy?start=<ts>&end=<ts>
  → { data: [{building_id, hours: [24 counts]}] }
```

Both are single-pass GROUP BYs over the snapshot tables and can be served from
the streaming job's sink table directly (materialized view), keeping
interactive latency under ~1s.

## OpenRouter agent config

`agent.js` reads:

```js
const CONFIG = {
  apiKey: "",                    // ← paste OpenRouter key here (or window.CP_OPENROUTER_KEY)
  model: "z-ai/glm-4.6",        // GLM family id — bump when GLM 5.3 flash ships
  endpoint: "https://openrouter.ai/api/v1/chat/completions",
};
```

Until a key is set, the agent runs in **offline mode**: questions are
pattern-matched to the right tool and the tool's own summary is shown, so the
whole UX (chat → tool call → map pins) is demoable with no external calls.
The tool schema (`run_analytics`) and the two-hop conversation
(tool result → natural-language summary) are already wired for live mode.
