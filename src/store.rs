use std::sync::Mutex;
use std::time::Duration;

use chrono::{DateTime, Timelike, Utc};
use sqlx::postgres::{PgConnectOptions, PgPoolOptions, PgSslMode};
use sqlx::PgPool;

use crate::config::Settings;
use crate::models::{BBox, Point, Row};

const INSERT_RAW: &str = r#"
    INSERT INTO public.location_events (device_id, latitude, longitude, "time")
    SELECT * FROM UNNEST($1::text[], $2::float8[], $3::float8[], $4::timestamptz[])
"#;

// Deliberately omit id: the database's sequence/default generates a non-null,
// unique, monotonically increasing id even for concurrent API requests.
const INSERT_BROAD: &str = r#"
    INSERT INTO public.location_events_broad (device_id, latitude, longitude, "time")
    SELECT * FROM UNNEST($1::text[], $2::float8[], $3::float8[], $4::timestamptz[])
"#;

const QUERY_RAW: &str = r#"
    SELECT "time", latitude, longitude FROM public.location_events
    WHERE "time" >= $1 AND "time" < $2
      AND ($3::float8 IS NULL OR
           (longitude BETWEEN $3 AND $5 AND latitude BETWEEN $4 AND $6))
    ORDER BY "time" LIMIT $7
"#;

const QUERY_BROAD: &str = r#"
    SELECT "time", latitude, longitude FROM public.location_events_broad
    WHERE "time" >= $1 AND "time" < $2
      AND ($3::float8 IS NULL OR
           (longitude BETWEEN $3 AND $5 AND latitude BETWEEN $4 AND $6))
    ORDER BY "time" LIMIT $7
"#;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dataset {
    Raw,
    Broad,
}

#[derive(Default)]
pub struct MemoryStore {
    raw: Vec<Row>,
    broad: Vec<Row>,
}

/// Lakebase/PostgreSQL or an equivalent in-memory store for development.
pub enum Store {
    Memory(Mutex<MemoryStore>),
    Postgres(PgPool),
}

/// Return EVERY incoming point with UTC minute 00 (seconds 00-59).
/// Store its timestamp at the start of that hour. Duplicates are intentionally
/// retained: multiple points from the same device/hour all become broad rows.
/// PostgreSQL assigns a distinct, increasing BIGINT id to each inserted row.
fn hourly_candidates(points: &[Point]) -> Vec<Point> {
    points
        .iter()
        .filter(|point| point.time.minute() == 0)
        .map(|point| {
            let mut snapshot = point.clone();
            snapshot.time = snapshot.time
                .with_second(0).expect("zero is a valid second")
                .with_nanosecond(0).expect("zero is a valid nanosecond");
            snapshot
        })
        .collect()
}

impl Store {
    pub fn memory() -> Self {
        Store::Memory(Mutex::new(MemoryStore::default()))
    }

    pub fn postgres(s: &Settings) -> Self {
        let opts = PgConnectOptions::new()
            .host(&s.pg_host)
            .port(s.pg_port)
            .database(&s.pg_database)
            .username(&s.pg_user)
            .password(&s.pg_password)
            .ssl_mode(PgSslMode::Require);
        let pool = PgPoolOptions::new()
            .max_connections(5)
            .acquire_timeout(Duration::from_secs(10))
            .idle_timeout(Duration::from_secs(60))
            .test_before_acquire(true)
            .connect_lazy_with(opts);
        Store::Postgres(pool)
    }

    /// Persist all incoming points, and hourly candidates, atomically.
    pub async fn add_many(&self, points: &[Point]) -> Result<(), String> {
        if points.is_empty() {
            return Ok(());
        }

        let broad = hourly_candidates(points);
        match self {
            Store::Memory(mutex) => {
                let mut memory = mutex.lock().unwrap();
                memory.raw.extend(points.iter().map(|p| (p.time, p.lat, p.lng)));
                memory.broad.extend(broad.iter().map(|point| {
                    (point.time, point.lat, point.lng)
                }));
                Ok(())
            }
            Store::Postgres(pool) => {
                let mut transaction = pool.begin().await.map_err(|e| e.to_string())?;

                let devices: Vec<&str> = points.iter().map(|p| p.device_id.as_str()).collect();
                let lats: Vec<f64> = points.iter().map(|p| p.lat).collect();
                let lngs: Vec<f64> = points.iter().map(|p| p.lng).collect();
                let times: Vec<DateTime<Utc>> = points.iter().map(|p| p.time).collect();

                sqlx::query(INSERT_RAW)
                    .bind(devices).bind(lats).bind(lngs).bind(times)
                    .execute(&mut *transaction)
                    .await
                    .map_err(|e| e.to_string())?;

                if !broad.is_empty() {
                    let devices: Vec<&str> = broad.iter().map(|p| p.device_id.as_str()).collect();
                    let lats: Vec<f64> = broad.iter().map(|p| p.lat).collect();
                    let lngs: Vec<f64> = broad.iter().map(|p| p.lng).collect();
                    let times: Vec<DateTime<Utc>> = broad.iter().map(|p| p.time).collect();

                    sqlx::query(INSERT_BROAD)
                        .bind(devices).bind(lats).bind(lngs).bind(times)
                        .execute(&mut *transaction)
                        .await
                        .map_err(|e| e.to_string())?;
                }

                transaction.commit().await.map_err(|e| e.to_string())?;
                Ok(())
            }
        }
    }

    pub async fn query(
        &self,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
        bbox: Option<BBox>,
        limit: i64,
    ) -> Result<Vec<Row>, String> {
        self.query_dataset(Dataset::Raw, start, end, bbox, limit).await
    }

    pub async fn query_broad(
        &self,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
        bbox: Option<BBox>,
        limit: i64,
    ) -> Result<Vec<Row>, String> {
        self.query_dataset(Dataset::Broad, start, end, bbox, limit).await
    }

    pub async fn query_dataset(
        &self,
        dataset: Dataset,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
        bbox: Option<BBox>,
        limit: i64,
    ) -> Result<Vec<Row>, String> {
        match self {
            Store::Memory(mutex) => {
                let memory = mutex.lock().unwrap();
                let source = match dataset {
                    Dataset::Raw => &memory.raw,
                    Dataset::Broad => &memory.broad,
                };
                let mut out: Vec<Row> = source.iter()
                    .filter(|(t, lat, lng)| {
                        *t >= start && *t < end
                            && bbox.is_none_or(|(min_lng, min_lat, max_lng, max_lat)| {
                                *lat >= min_lat && *lat <= max_lat
                                    && *lng >= min_lng && *lng <= max_lng
                            })
                    })
                    .copied()
                    .collect();
                out.sort_by_key(|r| r.0);
                out.truncate(limit as usize);
                Ok(out)
            }
            Store::Postgres(pool) => {
                let (min_lng, min_lat, max_lng, max_lat) = match bbox {
                    Some((a, b, c, d)) => (Some(a), Some(b), Some(c), Some(d)),
                    None => (None, None, None, None),
                };
                let sql = match dataset {
                    Dataset::Raw => QUERY_RAW,
                    Dataset::Broad => QUERY_BROAD,
                };
                sqlx::query_as::<_, Row>(sql)
                    .bind(start).bind(end)
                    .bind(min_lng).bind(min_lat).bind(max_lng).bind(max_lat)
                    .bind(limit)
                    .fetch_all(pool)
                    .await
                    .map_err(|e| e.to_string())
            }
        }
    }

    pub async fn ping(&self) -> bool {
        match self {
            Store::Memory(_) => true,
            Store::Postgres(pool) => sqlx::query("SELECT 1").execute(pool).await.is_ok(),
        }
    }
}

#[cfg(test)]
mod tests {
    use chrono::{TimeZone, Utc};
    use super::*;

    fn p(hour: u32, minute: u32, second: u32, device_id: &str) -> Point {
        Point {
            lat: 43.0731,
            lng: -89.4012,
            time: Utc.with_ymd_and_hms(2026, 11, 14, hour, minute, second).unwrap(),
            device_id: device_id.to_string(),
        }
    }

    #[tokio::test]
    async fn stores_all_zero_minute_points_including_duplicate_device_hours() {
        let store = Store::memory();
        store.add_many(&[
            p(7, 0, 15, "device-a"),
            p(7, 0, 45, "device-a"),
            p(7, 1, 0, "device-a"),
            p(7, 0, 59, "device-b"),
            p(8, 0, 3, "device-a"),
        ]).await.unwrap();
        // Another batch at 07:00 must append another broad entry.
        store.add_many(&[p(7, 0, 55, "device-a")]).await.unwrap();

        let start = Utc.with_ymd_and_hms(2026, 11, 14, 7, 0, 0).unwrap();
        let end = Utc.with_ymd_and_hms(2026, 11, 14, 9, 0, 0).unwrap();
        let raw = store.query(start, end, None, 100).await.unwrap();
        let broad = store.query_broad(start, end, None, 100).await.unwrap();
        assert_eq!(raw.len(), 6);
        assert_eq!(broad.len(), 5);
        assert_eq!(broad.iter().filter(|row| row.0 == start).count(), 4);
        assert!(broad.iter().all(|(t, _, _)| t.minute() == 0 && t.second() == 0));
    }

    #[tokio::test]
    async fn query_broad_uses_same_bbox_filter_as_raw() {
        let store = Store::memory();
        let mut inside = p(7, 0, 0, "inside");
        let mut outside = p(7, 0, 0, "outside");
        inside.lat = 43.0;
        inside.lng = -89.0;
        outside.lat = 46.0;
        outside.lng = -92.0;
        store.add_many(&[inside, outside]).await.unwrap();
        let start = Utc.with_ymd_and_hms(2026, 11, 14, 7, 0, 0).unwrap();
        let end = Utc.with_ymd_and_hms(2026, 11, 14, 8, 0, 0).unwrap();
        assert_eq!(store.query_broad(start, end, Some((-90.0, 42.0, -88.0, 44.0)), 100)
            .await.unwrap().len(), 1);
    }
}
