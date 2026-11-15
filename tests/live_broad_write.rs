//! End-to-end test: send an actual HTTP POST to a running backend, then confirm
//! that PostgreSQL has an hourly row and that /heatmap/broad returns it.
//!
//! This test intentionally writes to your configured database. Run explicitly:
//!   cargo test --test live_broad_write -- --ignored --nocapture
//!
//! Start the API in a separate terminal first: cargo run
//! The API and this test must use the same PostgreSQL database (.env).

use std::error::Error;
use std::time::Duration;

use chrono::{DateTime, Timelike, Utc};
use madhacks_backend::config::Settings;
use madhacks_backend::store::Store;
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

// Minimal localhost-only HTTP client; no extra Cargo dependencies needed.
async fn api_request(
    port: u16,
    method: &str,
    path: &str,
    body: Option<&str>,
) -> Result<(u16, Value), Box<dyn Error>> {
    let payload = body.unwrap_or("");
    let mut socket = TcpStream::connect(("127.0.0.1", port)).await?;
    let request = format!(
        "{method} {path} HTTP/1.1\r\n\
         Host: 127.0.0.1:{port}\r\n\
         Content-Type: application/json\r\n\
         Connection: close\r\n\
         Content-Length: {}\r\n\r\n{payload}",
        payload.len()
    );
    socket.write_all(request.as_bytes()).await?;

    let mut bytes = Vec::new();
    tokio::time::timeout(Duration::from_secs(15), socket.read_to_end(&mut bytes)).await??;
    let response = String::from_utf8(bytes)?;
    let (headers, body) = response
        .split_once("\r\n\r\n")
        .ok_or("API returned an invalid HTTP response")?;
    let status: u16 = headers
        .lines()
        .next()
        .and_then(|s| s.split_whitespace().nth(1))
        .ok_or("HTTP status code missing")?
        .parse()?;
    let parsed: Value = serde_json::from_str(body)?;
    Ok((status, parsed))
}

// Read all records created by this test, including duplicates at the same hour.
async fn broad_rows(
    pool: &sqlx::PgPool,
    device_id: &str,
    hour: DateTime<Utc>,
) -> Result<Vec<(i64, f64, f64, Option<String>)>, sqlx::Error> {
    sqlx::query_as::<_, (i64, f64, f64, Option<String>)>(
        "SELECT id::bigint, latitude, longitude, building FROM public.location_events_broad \
         WHERE device_id = $1 AND \"time\" = $2 ORDER BY id"
    )
    .bind(device_id)
    .bind(hour)
    .fetch_all(pool)
    .await
}

#[tokio::test]
#[ignore = "Writes a real location row to the configured PostgreSQL database"]
async fn post_zero_minute_location_updates_broad_table() -> Result<(), Box<dyn Error>> {
    dotenvy::dotenv().ok();
    let settings = Settings::from_env();
    assert_eq!(
        settings.store_backend, "postgres",
        "Set STORE_BACKEND=postgres in .env for this live database test"
    );

    // Use the current UTC hour, regardless of what minute the test is run.
    // The API tests the timestamp, not the time the HTTP request arrives.
    let now = Utc::now();
    let hour: DateTime<Utc> = now
        .with_minute(0)
        .unwrap()
        .with_second(0)
        .unwrap()
        .with_nanosecond(0)
        .unwrap();
    let next_hour = hour + chrono::Duration::hours(1);

    // A unique device name scopes this test's reads without relying on a
    // uniqueness constraint for device/hour rows.
    let device_id = format!("hourly-api-test-{}-{}", std::process::id(), now.timestamp_micros());
    let lat = 43.0731;
    let lng = -89.4012;
    // The grid maps these coordinates to Grainger Hall, and the server stores its answer.
    let building = "Grainger Hall (Wisconsin School of Business)";
    let payload = json!({
        "device_id": device_id,
        "lat": lat,
        "lng": lng,
        "building": building,
        "timestamp": hour.to_rfc3339()
    });

    // First verify the API is reachable and connected to a healthy store.
    let (status, health) = api_request(settings.port, "GET", "/api/v1/health", None).await?;
    assert_eq!(status, 200, "Health request failed: {health}");
    assert_eq!(health["store_ok"], true, "Server database connection failed");

    // This is a REAL HTTP POST to the running Rust API, not an in-memory router test.
    let (status, accepted) = api_request(
        settings.port,
        "POST",
        "/api/v1/locations",
        Some(&payload.to_string()),
    )
    .await?;
    assert_eq!(status, 202, "Location POST failed: {accepted}");
    assert_eq!(accepted["accepted"], 1);
    println!("POST accepted: device_id={device_id}, timestamp={hour}");

    // The API buffers writes; poll PostgreSQL until the first row is persisted.
    let store = Store::postgres(&settings);
    let Store::Postgres(pool) = store else {
        unreachable!("Store::postgres must return Store::Postgres")
    };

    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    let first_id = loop {
        let rows = broad_rows(&pool, &device_id, hour).await?;
        if let Some((id, db_lat, db_lng, db_building)) = rows.first() {
            assert_eq!((*db_lat, *db_lng), (lat, lng));
            assert_eq!(db_building.as_deref(), Some(building));
            println!("First PostgreSQL row confirmed: id={id} at {hour}");
            break *id;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "First broad row not found within 20s. Check API logs and SQL migration."
        );
        tokio::time::sleep(Duration::from_millis(250)).await;
    };

    // Append ANOTHER point with the exact same device and hour.
    // It must not be deduplicated, and it must get a new, larger id.
    let (status, accepted) = api_request(
        settings.port,
        "POST",
        "/api/v1/locations",
        Some(&payload.to_string()),
    )
    .await?;
    assert_eq!(status, 202, "Second location POST failed: {accepted}");

    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    loop {
        let rows = broad_rows(&pool, &device_id, hour).await?;
        if rows.len() >= 2 {
            assert!(rows[0].0 > 0, "Broad id must be positive, never null");
            assert!(rows[1].0 > first_id, "Second broad id must increase");
            assert_eq!((rows[1].1, rows[1].2), (lat, lng));
            assert_eq!(rows[1].3.as_deref(), Some(building));
            println!("Duplicate-hour append verified: ids={} and {}", rows[0].0, rows[1].0);
            break;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "Second broad row not found within 20s: duplicate event must be appended"
        );
        tokio::time::sleep(Duration::from_millis(250)).await;
    }

    // Also verify that the new HTTP query endpoint exposes the broad data.
    let path = format!(
        "/api/v1/heatmap/broad?start={}&end={}&bbox={},{},{},{}",
        hour.to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        next_hour.to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        lng - 0.00001,
        lat - 0.00001,
        lng + 0.00001,
        lat + 0.00001,
    );
    let (status, heatmap) = api_request(settings.port, "GET", &path, None).await?;
    assert_eq!(status, 200, "Broad heatmap GET failed: {heatmap}");
    let key = hour.to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let rows = heatmap["data"]
        .get(&key)
        .and_then(Value::as_array)
        .ok_or("Broad heatmap did not contain the expected hourly timestamp")?;
    let matching = rows.iter().filter(|p| {
        p["lat"] == lat && p["lng"] == lng && p["building"] == building
    }).count();
    assert!(
        matching >= 2,
        "Broad heatmap must contain both appended points; found {matching}: {heatmap}"
    );
    // Confirm the original raw table also has the new building column.
    let raw_buildings: Vec<(Option<String>,)> = sqlx::query_as(
        "SELECT building FROM public.location_events WHERE device_id = $1 AND \"time\" = $2"
    )
    .bind(&device_id)
    .bind(hour)
    .fetch_all(&pool)
    .await?;
    assert!(raw_buildings.len() >= 2);
    assert!(raw_buildings.iter().all(|(name,)| name.as_deref() == Some(building)));
    println!("GET /api/v1/heatmap/broad returned both building-tagged points. Test passed.");
    Ok(())
}
