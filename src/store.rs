use std::sync::Mutex;
use std::time::Duration;

use chrono::{DateTime, Utc};
use sqlx::postgres::{PgConnectOptions, PgPoolOptions, PgSslMode};
use sqlx::PgPool;

use crate::config::Settings;
use crate::models::{BBox, Point, Row};

const TABLE: &str = "public.location_events";

/// Lakebase (Postgres) or an in-memory store for local dev and tests.
pub enum Store {
    Memory(Mutex<Vec<Row>>),
    Postgres(PgPool),
}

impl Store {
    pub fn memory() -> Self {
        Store::Memory(Mutex::new(Vec::new()))
    }

    pub fn postgres(s: &Settings) -> Self {
        let opts = PgConnectOptions::new()
            .host(&s.pg_host)
            .port(s.pg_port)
            .database(&s.pg_database)
            .username(&s.pg_user)
            .password(&s.pg_password)
            .ssl_mode(PgSslMode::Require);
        // Lazy pool: starts fine even if the DB is briefly unreachable. Idle connections are
        // recycled and checked before use, so a stale connection is replaced instead of failing.
        let pool = PgPoolOptions::new()
            .max_connections(5)
            .acquire_timeout(Duration::from_secs(10))
            .idle_timeout(Duration::from_secs(60))
            .test_before_acquire(true)
            .connect_lazy_with(opts);
        Store::Postgres(pool)
    }

    pub async fn add_many(&self, points: &[Point]) -> Result<(), String> {
        if points.is_empty() {
            return Ok(());
        }
        match self {
            Store::Memory(rows) => {
                rows.lock().unwrap().extend(points.iter().map(|p| (p.time, p.lat, p.lng)));
                Ok(())
            }
            Store::Postgres(pool) => {
                let devices: Vec<&str> = points.iter().map(|p| p.device_id.as_str()).collect();
                let lats: Vec<f64> = points.iter().map(|p| p.lat).collect();
                let lngs: Vec<f64> = points.iter().map(|p| p.lng).collect();
                let times: Vec<DateTime<Utc>> = points.iter().map(|p| p.time).collect();
                sqlx::query(sqlx::AssertSqlSafe(format!(
                    "INSERT INTO {TABLE} (device_id, latitude, longitude, \"time\") \
                     SELECT * FROM UNNEST($1::text[], $2::float8[], $3::float8[], $4::timestamptz[])"
                )))
                .bind(devices)
                .bind(lats)
                .bind(lngs)
                .bind(times)
                .execute(pool)
                .await
                .map_err(|e| e.to_string())?;
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
        match self {
            Store::Memory(rows) => {
                let mut out: Vec<Row> = rows
                    .lock()
                    .unwrap()
                    .iter()
                    .filter(|(t, lat, lng)| {
                        *t >= start
                            && *t < end
                            && bbox.is_none_or(|(min_lng, min_lat, max_lng, max_lat)| {
                                *lat >= min_lat && *lat <= max_lat && *lng >= min_lng && *lng <= max_lng
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
                sqlx::query_as::<_, Row>(sqlx::AssertSqlSafe(format!(
                    "SELECT \"time\", latitude, longitude FROM {TABLE} \
                     WHERE \"time\" >= $1 AND \"time\" < $2 \
                     AND ($3::float8 IS NULL OR (longitude BETWEEN $3 AND $5 AND latitude BETWEEN $4 AND $6)) \
                     ORDER BY \"time\" LIMIT $7"
                )))
                .bind(start)
                .bind(end)
                .bind(min_lng)
                .bind(min_lat)
                .bind(max_lng)
                .bind(max_lat)
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
