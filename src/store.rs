use std::sync::Mutex;
use std::time::Duration;

use chrono::{DateTime, Utc};
use sqlx::postgres::{PgConnectOptions, PgPoolOptions, PgSslMode};
use sqlx::PgPool;

use crate::config::Settings;
use crate::models::{BBox, Point, Row};

const INSERT_RAW: &str = r#"
    INSERT INTO public.location_events (device_id, latitude, longitude, "time", building)
    SELECT * FROM UNNEST($1::text[], $2::float8[], $3::float8[], $4::timestamptz[], $5::text[])
"#;

const QUERY_RAW: &str = r#"
    SELECT "time", latitude, longitude, building FROM public.location_events
    WHERE "time" >= $1 AND "time" < $2
      AND ($3::float8 IS NULL OR
           (longitude BETWEEN $3 AND $5 AND latitude BETWEEN $4 AND $6))
    ORDER BY "time" LIMIT $7
"#;

const QUERY_BROAD: &str = r#"
    SELECT "time", latitude, longitude, building FROM public.location_events_broad
    WHERE "time" >= $1 AND "time" < $2
      AND ($3::float8 IS NULL OR
           (longitude BETWEEN $3 AND $5 AND latitude BETWEEN $4 AND $6))
    ORDER BY "time" LIMIT $7
"#;

const COUNT_BY_BUILDING: &str = r#"
    SELECT building, COUNT(*) FROM public.location_events
    WHERE "time" >= $1 AND building IS NOT NULL
    GROUP BY building
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

    /// Persist all incoming points atomically.
    pub async fn add_many(&self, points: &[Point]) -> Result<(), String> {
        if points.is_empty() {
            return Ok(());
        }

        match self {
            Store::Memory(mutex) => {
                let mut memory = mutex.lock().unwrap();
                memory.raw.extend(points.iter().map(|p| {
                    (p.time, p.lat, p.lng, p.building.clone())
                }));
                Ok(())
            }
            Store::Postgres(pool) => {
                let mut transaction = pool.begin().await.map_err(|e| e.to_string())?;

                let devices: Vec<&str> = points.iter().map(|p| p.device_id.as_str()).collect();
                let lats: Vec<f64> = points.iter().map(|p| p.lat).collect();
                let lngs: Vec<f64> = points.iter().map(|p| p.lng).collect();
                let times: Vec<DateTime<Utc>> = points.iter().map(|p| p.time).collect();
                let buildings: Vec<Option<String>> = points.iter().map(|p| p.building.clone()).collect();

                sqlx::query(INSERT_RAW)
                    .bind(devices).bind(lats).bind(lngs).bind(times).bind(buildings)
                    .execute(&mut *transaction)
                    .await
                    .map_err(|e| e.to_string())?;

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
                    .filter(|(t, lat, lng, _building)| {
                        *t >= start && *t < end
                            && bbox.is_none_or(|(min_lng, min_lat, max_lng, max_lat)| {
                                *lat >= min_lat && *lat <= max_lat
                                    && *lng >= min_lng && *lng <= max_lng
                            })
                    })
                    .cloned()
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

    /// Points per building at or after `since`.
    pub async fn building_counts(&self, since: DateTime<Utc>) -> Result<Vec<(String, i64)>, String> {
        match self {
            Store::Memory(mutex) => {
                let memory = mutex.lock().unwrap();
                let mut counts: std::collections::BTreeMap<String, i64> = Default::default();
                for (_, _, _, building) in memory.raw.iter().filter(|r| r.0 >= since) {
                    if let Some(name) = building {
                        *counts.entry(name.clone()).or_default() += 1;
                    }
                }
                Ok(counts.into_iter().collect())
            }
            Store::Postgres(pool) => sqlx::query_as::<_, (String, i64)>(COUNT_BY_BUILDING)
                .bind(since)
                .fetch_all(pool)
                .await
                .map_err(|e| e.to_string()),
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
            building: None,
        }
    }

    #[tokio::test]
    async fn building_is_saved() {
        let store = Store::memory();
        let mut p1 = p(7, 0, 15, "device-a");
        p1.building = Some("Memorial Union".into());
        store.add_many(&[p1]).await.unwrap();
        let start = Utc.with_ymd_and_hms(2026, 11, 14, 7, 0, 0).unwrap();
        let end = Utc.with_ymd_and_hms(2026, 11, 14, 8, 0, 0).unwrap();
        let rows = store.query(start, end, None, 100).await.unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].3.as_deref(), Some("Memorial Union"));
    }
}
