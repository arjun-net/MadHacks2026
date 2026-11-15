# Campus Pulse × Databricks — Live Streaming Dashboard Blueprint

Design for streaming the 400-agent / 720-tick simulation into the live Mapbox
dashboard (`viewer/index.html`, currently served at port 8770), using
**Databricks** (hackathon track requirement) on the **free tier**.

Core principle: **distill before transmit.** Raw rows are the wrong unit to
move; the browser wants one small snapshot per tick.

---

## 1. Why distill (the numbers)

| Representation | Size | Why it's wrong/right |
|---|---|---|
| Raw rows (per agent per tick) | 259,317 rows / 18.2 MB CSV | 400 rows per tick, ~25 KB/tick — far too much to push per tick |
| Per-tick positions (Float32) | 400 × 2 × 4 B ≈ **3.2 KB/tick** | One flat buffer, zero parsing client-side |
| Per-tick density bins | (cellIdx, count) pairs ≈ **1–2 KB/tick** | Carries the "pulse" visual at campus scale |

Whole simulation as positions: 720 ticks × 3.2 KB ≈ **2.3 MB total** (vs 18 MB).

---

## 2. Data shapes

### Positions layer (moving dots)
- Fixed agent order established once (agent index → id), sent at startup.
- Per tick: `Float32Array` of `[lat0, lng0, lat1, lng1, ...]` for all 400 agents.
- Pushed as a binary `ArrayBuffer` over SSE — no JSON parse in the hot loop.
- Optional garnish mode: stream only a subset (e.g. 50 agents) as dots if
  rendering gets tight; density carries the story.

### Density layer (heatmap "pulse")
- Campus gridded at ~50–100 m bins (cell index = `row * cols + col`).
- Per tick: only occupied cells as `(cellIndex: uint16, count: uint16)` pairs.
- This is the layer that makes the dashboard feel alive; the heatmap is the
  hero visual, dots are the garnish.

---

## 3. Databricks architecture (free-tier friendly)

```
generator.py (400 agents, 259k pings)
        │  batch write once
        ▼
Delta table: campus_pings_raw            (agent_id, tick, state, building, lat, lng)
        │  Structured Streaming job (rate/file source → real streaming)
        │  per-tick aggregation
        ▼
Delta table: campus_ticks_snapshot       (tick, positions_blob, density_pairs)
        │  read
        ▼
Databricks App (FastAPI)  ──SSE──▶  browser dashboard (Mapbox)
```

### Job 1 — landing
Run `generator.py` in a notebook/job; write all 259k rows to
`campus_pings_raw` as Delta. This is the raw landing zone.

### Job 2 — streaming aggregation (the track demo)
A **Structured Streaming** job (legitimately streaming — e.g. file-source
reading micro-batches of the raw table, or a rate source replaying ticks)
aggregates per tick:

```sql
-- concept
SELECT tick,
       collect_list(struct(agent_idx, lat, lng)) AS positions,  -- packed client-side
       ...                                                       -- density binning here
FROM campus_pings_raw
GROUP BY tick
```
Emits one snapshot row per tick into `campus_ticks_snapshot`. This is the
honest "distillation" story for judges: Delta + Structured Streaming doing
the work, not theater.

### Serving — Databricks Apps
- Host a small **FastAPI** app inside Databricks (Databricks Apps) that reads
  `campus_ticks_snapshot` and exposes:
  - `GET /stream` — SSE endpoint, one snapshot per tick (3 KB binary or JSON)
  - `GET /snapshot/{n}` — plain polling fallback
- The App talks to the warehouse via the built-in connection — **no external
  broker** (no Kafka/websocket gateway needed on free tier).
- **SSE over one HTTP connection** is the transport of choice: simple,
  free-tier-safe, 3 KB/tick is trivial bandwidth.

---

## 4. Transport efficiency ladder

| Approach | Verdict |
|---|---|
| Raw CSV rows over network | ❌ 25 KB/tick, wasteful |
| Browser polls warehouse per tick | ❌ statement-execution latency + free-tier rate limits → 429s mid-demo |
| Row-batch polling (Statement Execution API) | ⚠️ chunky, quota-hungry |
| Per-tick JSON snapshots over SSE | ✅ good |
| **Per-tick binary snapshots over SSE** | ✅ **pick** — 3.2 KB/tick, ArrayBuffer, zero client parsing |
| Server-side density-only | smallest payload, but loses the dots |

**Never query per tick from the client.** Aggregate in the job, push from
the App.

---

## 5. Recommended deployment (pragmatic hybrid)

1. **Databricks does the real work:** ingest + Structured Streaming
   aggregation into per-tick Delta snapshots. On-track, demonstrable, real.
2. **Local 8770 server proxies the stream:** the Node/Python static server
   forwards SSE from the Databricks App to the browser.
3. **Demo-room bulletproofing:** the local server can also read
   pre-computed snapshot artifacts and play them back at 1 tick/sec.
   Judges see live movement; the Databricks pipeline genuinely performed the
   distillation; if conference Wi-Fi dies mid-demo, playback keeps the
   dashboard running.

Client side stays dumb: every tick is "apply this 3 KB buffer" → Mapbox
holds 60 fps, zero client-side arithmetic.

---

## 6. Pitfalls

- **Per-tick warehouse polling from the browser** — latency + rate limits;
  will 429 at ~720 queries in a demo.
- **Websockets on free tier** — networking can be restrictive; SSE is the
  safer transport.
- **Sending per-agent rows instead of per-tick snapshots** — 80× more bytes.
- **Client-side density computation** — keep the browser dumb; precompute
  bins in the streaming job.

## 7. Future extensions

- Replay speed control (tick multiplier) server-side.
- State overlays per tick (CLASS/STUDY/TRANSIT counts) as a third tiny layer.
- Historical scrub: snapshot table is already time-indexed — time-travel
  through the day for free (Delta's selling point).
