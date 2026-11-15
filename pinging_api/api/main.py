"""MadHacks 2026 Location API — reference implementation of the provided spec.

Endpoints:
  POST /locations          one point
  POST /locations/batch    1..500 points
  GET  /heatmap            raw points in [start,end) (+bbox,limit)
  GET  /heatmap/broad      building-level dataset in [start,end)
  GET  /health

Storage: SQLite (WAL). Buffered writes: accepted points are queued and
flushed in batches; reads always see a consistent committed snapshot.
Naive timestamps are rejected (422). All output timestamps are UTC ISO-8601.
"""
from __future__ import annotations

import os
import re
import sqlite3
import threading
import time
from collections import deque
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Any

from fastapi import FastAPI, HTTPException, Query
from pydantic import BaseModel, Field, field_validator, model_validator

DB_PATH = os.environ.get("PULSE_DB", "locations.db")
FLUSH_EVERY = float(os.environ.get("PULSE_FLUSH_EVERY", "0.5"))  # seconds

# ISO-8601 with explicit timezone (Z or ±HH:MM)
_NAIVE = re.compile(r"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?$")


def parse_ts(ts: str, *, field: str = "timestamp") -> datetime:
    if not isinstance(ts, str) or _NAIVE.match(ts.strip()):
        raise HTTPException(
            422,
            detail=f"{field}: ISO-8601 with explicit timezone (Z or offset) required",
        )
    t = ts.strip().replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(t)
    except ValueError:
        try:  # support e.g. 2026-11-14T22:34:00.123456+0000
            dt = datetime.strptime(t, "%Y-%m-%dT%H:%M:%S.%f%z")
        except ValueError:
            raise HTTPException(422, detail=f"{field}: invalid ISO-8601 timestamp")
    if dt.tzinfo is None:
        raise HTTPException(422, detail=f"{field}: naive timestamps are rejected")
    return dt.astimezone(timezone.utc)


def fmt_ts(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class LocationIn(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)
    timestamp: str
    device_id: str | None = Field(default=None, max_length=128)
    building: str | None = Field(default=None, max_length=256)

    @field_validator("device_id", "building")
    @classmethod
    def _trim(cls, v: str | None) -> str | None:
        return v.strip() if isinstance(v, str) else v

    @model_validator(mode="after")
    def _validate(self) -> "LocationIn":
        parse_ts(self.timestamp)
        self.device_id = self.device_id or "unknown"
        self.building = self.building or None
        return self


class BatchIn(BaseModel):
    points: list[LocationIn] = Field(min_length=1, max_length=500)


class Accepted(BaseModel):
    accepted: int


# ── store ────────────────────────────────────────────────────────────
class Store:
    def __init__(self, path: str):
        self.path = path
        self.conn = sqlite3.connect(path, check_same_thread=False)
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute(
            """CREATE TABLE IF NOT EXISTS points (
                   id INTEGER PRIMARY KEY,
                   ts TEXT NOT NULL,          -- 'YYYY-MM-DDTHH:MM:SSZ', UTC
                   ts_epoch REAL NOT NULL,
                   lat REAL NOT NULL, lng REAL NOT NULL,
                   device_id TEXT, building TEXT
               )"""
        )
        self.conn.execute(
            "CREATE INDEX IF NOT EXISTS ix_points_ts ON points(ts_epoch)"
        )
        self.conn.commit()
        self.lock = threading.Lock()
        self.buffer: deque[tuple] = deque()

    def buffer_point(self, p: LocationIn) -> None:
        dt = parse_ts(p.timestamp)
        row = (
            fmt_ts(dt),
            dt.timestamp(),
            p.lat,
            p.lng,
            p.device_id,
            p.building,
        )
        with self.lock:
            self.buffer.append(row)

    def flush(self) -> int:
        with self.lock:
            if not self.buffer:
                return 0
            rows = list(self.buffer)
            self.buffer.clear()
        try:
            with self.lock:
                self.conn.executemany(
                    "INSERT INTO points (ts,ts_epoch,lat,lng,device_id,building) "
                    "VALUES (?,?,?,?,?,?)",
                    rows,
                )
                self.conn.commit()
            return len(rows)
        except sqlite3.Error:
            with self.lock:
                self.buffer.extendleft(rows)
            raise

    def query(
        self,
        start: datetime,
        end: datetime,
        bbox: tuple[float, float, float, float] | None,
        limit: int,
        *,
        broad: bool = False,
    ) -> dict[str, Any]:
        sql = (
            "SELECT ts, lat, lng, device_id, building FROM points "
            "WHERE ts_epoch >= ? AND ts_epoch < ?"
        )
        params: list[Any] = [start.timestamp(), end.timestamp()]
        if bbox:
            sql += " AND lng >= ? AND lat >= ? AND lng <= ? AND lat <= ?"
            params += [*bbox]
        if broad:
            # building-level: one representative point per (ts, building)
            sql = (
                "SELECT ts, AVG(lat) AS lat, AVG(lng) AS lng, building "
                "FROM points WHERE ts_epoch >= ? AND ts_epoch < ?"
            )
            if bbox:
                sql += " AND lng >= ? AND lat >= ? AND lng <= ? AND lat <= ?"
            sql += " GROUP BY ts, building ORDER BY MIN(ts_epoch) LIMIT ?"
        params.append(limit)
        with self.lock:
            cur = self.conn.execute(sql, params)
            rows = cur.fetchall()
        data: dict[str, list[dict[str, Any]]] = {}
        count = 0
        for ts, lat, lng, device_id, building in rows:
            data.setdefault(ts, []).append(
                {"lat": lat, "lng": lng, "device_id": device_id,
                 "building": building}
            )
            count += 1
        return {
            "start": fmt_ts(start),
            "end": fmt_ts(end),
            "count": count,
            "data": dict(sorted(data.items())),
        }


store: Store


@asynccontextmanager
async def _lifespan(app: FastAPI):
    global store
    store = Store(DB_PATH)
    import asyncio

    async def _flusher():
        while True:
            await asyncio.sleep(FLUSH_EVERY)
            try:
                store.flush()
            except sqlite3.Error as e:
                print("flush failed:", e)
    task = asyncio.create_task(_flusher())
    yield
    task.cancel()
    store.flush()


app = FastAPI(title="MadHacks 2026 Location API", version="1.0.0",
              lifespan=_lifespan)


def _parse_bbox(bbox: str | None) -> tuple[float, float, float, float] | None:
    if bbox is None:
        return None
    parts = [p.strip() for p in bbox.split(",")]
    if len(parts) != 4:
        raise HTTPException(422, detail="bbox: expected minLng,minLat,maxLng,maxLat")
    try:
        vals = [float(p) for p in parts]
    except ValueError:
        raise HTTPException(422, detail="bbox: numeric values required")
    min_lng, min_lat, max_lng, max_lat = vals
    if not (-180 <= min_lng <= 180 and -180 <= max_lng <= 180
            and -90 <= min_lat <= 90 and -90 <= max_lat <= 90):
        raise HTTPException(422, detail="bbox: lat/lng out of range")
    if min_lng > max_lng or min_lat > max_lat:
        raise HTTPException(422, detail="bbox: min must be <= max")
    return min_lng, min_lat, max_lng, max_lat


def _query_common(start: str, end: str, bbox: str | None, limit: int, *,
                  broad: bool = False) -> dict[str, Any]:
    s = parse_ts(start, field="start")
    e = parse_ts(end, field="end")
    if e <= s:
        raise HTTPException(422, detail="end: must be after start")
    return store.query(s, e, _parse_bbox(bbox), limit, broad=broad)


@app.post("/locations", response_model=Accepted, status_code=202)
def post_location(p: LocationIn) -> Accepted:
    store.buffer_point(p)
    return Accepted(accepted=1)


@app.post("/locations/batch", response_model=Accepted, status_code=202)
def post_batch(b: BatchIn) -> Accepted:
    for p in b.points:
        store.buffer_point(p)
    return Accepted(accepted=len(b.points))


@app.get("/heatmap")
def heatmap(
    start: str = Query(...),
    end: str = Query(...),
    bbox: str | None = Query(default=None),
    limit: int = Query(default=50000, ge=1, le=200000),
) -> dict[str, Any]:
    return _query_common(start, end, bbox, limit)


@app.get("/heatmap/broad")
def heatmap_broad(
    start: str = Query(...),
    end: str = Query(...),
    bbox: str | None = Query(default=None),
    limit: int = Query(default=50000, ge=1, le=200000),
) -> dict[str, Any]:
    return _query_common(start, end, bbox, limit, broad=True)


@app.get("/health")
def health() -> dict[str, Any]:
    try:
        with store.lock:
            store.conn.execute("SELECT 1").fetchone()
        return {"status": "ok", "store_ok": True}
    except sqlite3.Error:
        return {"status": "ok", "store_ok": False}
