<<<<<<< HEAD
# MadHacks2026
=======
# MadHacks 2026 – Location API (Rust)

Same API as the Python version (`~/Code/MadHacks2026`), built with axum + sqlx. Phone → `POST /api/v1/locations` → buffered → Lakebase. Frontend → `GET /api/v1/heatmap`.

## Run
```
cp .env.example .env     # STORE_BACKEND=memory works with no database
cargo run --release
```
Set `STORE_BACKEND=postgres` plus the `PG_*` vars for Lakebase (rows go to `public.location_events(device_id, latitude, longitude, "time")`, owned by the DB teammate; this server never creates it). Port defaults to 8000, set `PORT` to change it.

## API (base: `http://<host>:<port>/api/v1`)
Timestamps are ISO-8601 with timezone (e.g. `2026-11-14T22:34:00Z`); naive timestamps get 422. The field is `lng`, not `long`.

| Method | Path | Notes |
|---|---|---|
| POST | `/locations` | `{"lat","lng","timestamp","device_id"?}` → 202 `{"accepted":1}` |
| POST | `/locations/batch` | `{"points":[...]}` (1–500) → 202 `{"accepted":n}` |
| GET | `/heatmap?start=&end=[&bbox=minLng,minLat,maxLng,maxLat][&limit=]` | points in `[start,end)`; `limit` default 50000, max 200000 |
| GET | `/health` | `{"status":"ok","store_ok":bool}` |

Heatmap response: `{"start","end","count","data":{"<timestamp>":[{"lat","lng"},...]}}`, keys in ascending order.

Writes are buffered and flushed every 5s or 100 points, so a heatmap read right after a POST may not include it yet.

## Test
`cargo test` (in-memory store only; never touches the database).
>>>>>>> fcd15e6d7fd9343962cb77cf5182c8f7a920ad55
