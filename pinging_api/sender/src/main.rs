//! Campus Pulse — persistent device-ping sender.
//!
//! Reads the apicalls CSV (lat,long,timestamp,building) and replays it in
//! real time against the Location API (see openapi spec in the repo): once
//! per tick (one CSV timestamp, 2 sim-minutes = wall-clock `--tick-ms`) it
//! submits every device's ping via `POST /locations/batch` in 500-point
//! chunks, staggered by a small random jitter for realism.
//!
//! Payload shape per point (API contract):
//! ```json
//! {"lat": 43.07, "lng": -89.39, "timestamp": "2026-11-12T00:00:00Z",
//!  "device_id": "sim-12", "building": "sellery_hall"}
//! ```

use anyhow::{Context, Result};
use clap::Parser;
use rand::Rng;
use serde::Serialize;
use std::collections::BTreeMap;
use std::fs::File;
use std::sync::Arc;
use tokio::sync::Semaphore;
use tokio::time::{sleep, Duration, Instant};

#[derive(Parser, Debug)]
#[command(name = "campus-pulse-sender", about = "Replays device pings from the apicalls CSV to the Location API")]
struct Args {
    /// Input CSV (lat,long,timestamp,building). Default: PULSE_CSV or
    /// data/campus_simulation_apicalls.csv relative to the .env location.
    #[arg(short, long, env = "PULSE_CSV", default_value = "data/campus_simulation_apicalls.csv")]
    csv: String,

    /// Location API base URL (no trailing slash, includes /api/v1 if used)
    #[arg(short, long, env = "PULSE_TARGET", default_value = "http://127.0.0.1:8000/api/v1")]
    target: String,

    /// Wall-clock milliseconds per tick (one CSV timestamp per tick)
    #[arg(long, env = "PULSE_TICK_MS", default_value_t = 2000)]
    tick_ms: u64,

    /// Max per-device POST stagger jitter in milliseconds (0..jitter_ms)
    #[arg(long, env = "PULSE_JITTER_MS", default_value_t = 40)]
    jitter_ms: u64,

    /// Max concurrent in-flight POSTs
    #[arg(long, env = "PULSE_CONCURRENCY", default_value_t = 200)]
    concurrency: usize,

    /// Devices (rows) to post per tick — first N rows
    #[arg(long, env = "PULSE_DEVICES")]
    devices: Option<usize>,

    /// Start at this tick index instead of 0
    #[arg(long, env = "PULSE_START_TICK", default_value_t = 0)]
    start_tick: usize,

    /// Exit after one full pass of the CSV instead of looping forever
    #[arg(long, env = "PULSE_ONCE", action = clap::ArgAction::SetTrue)]
    once: bool,
}

/// One point, exactly the API's LocationIn schema.
#[derive(Debug, Clone, Serialize)]
struct Point {
    lat: f64,
    lng: f64,
    timestamp: String,
    device_id: String,
    building: String,
}

/// Batch envelope per the API's BatchIn schema (max 500 points).
#[derive(Serialize)]
struct BatchIn {
    points: Vec<Point>,
}

/// ticks in chronological order; ticks[i] = the device points for tick i
struct Schedule {
    ticks: Vec<Vec<Point>>,
}

fn load_schedule(path: &str, devices: Option<usize>) -> Result<Schedule> {
    let mut rdr = csv::ReaderBuilder::new()
        .trim(csv::Trim::All)
        .from_reader(File::open(path).with_context(|| format!("open {}", path))?);

    // BTreeMap over timestamp sorts chronologically (ISO 8601 UTC sorts
    // lexicographically) and merges same-timestamp rows.
    let mut by_ts: BTreeMap<String, Vec<Point>> = BTreeMap::new();

    for rec in rdr.records() {
        let rec = rec.with_context(|| "bad CSV record")?;
        // columns: lat,long,timestamp,building
        let lat: f64 = rec[0].parse().unwrap_or(0.0);
        let long: f64 = rec[1].parse().unwrap_or(0.0);
        let timestamp = rec[2].to_string();
        let building = rec[3].to_string();
        let ts = timestamp.clone();
        let slot = by_ts.entry(ts).or_default().len();
        by_ts.entry(rec[2].to_string()).or_default().push(Point {
            lat,
            lng: long,
            timestamp,
            device_id: format!("sim-{slot}"),
            building,
        });
    }

    let mut ticks: Vec<Vec<Point>> = by_ts.into_values().collect();
    if let Some(n) = devices {
        for t in ticks.iter_mut() {
            t.truncate(n);
        }
    }
    Ok(Schedule { ticks })
}

#[tokio::main]
async fn main() -> Result<()> {
    // Load .env: the worker may be started from any cwd, so look in the
    // workspace dir (pinging_api/), the current dir, then walk up.
    let _ = dotenvy::from_path("pinging_api/.env")
        .or_else(|_| dotenvy::from_path(".env"))
        .or_else(|_| dotenvy::dotenv().map(|_| ()));
    let args = Args::parse();

    // Resolve the CSV relative to the workspace root if the raw path
    // doesn't exist from the current directory (worker may be started from
    // pinging_api/sender/ or pinging_api/).
    let csv_path = {
        let p = std::path::Path::new(&args.csv);
        if p.exists() {
            args.csv.clone()
        } else {
            let root = std::env::current_dir()
                .ok()
                .and_then(|d| {
                    if d.file_name().map(|n| n == "sender").unwrap_or(false) {
                        d.parent().map(|p| p.to_path_buf())
                    } else {
                        Some(d)
                    }
                })
                .unwrap_or_default();
            let candidate = root.join(&args.csv);
            if candidate.exists() {
                candidate.to_string_lossy().into_owned()
            } else {
                args.csv.clone()
            }
        }
    };
    let schedule = Arc::new(load_schedule(&csv_path, args.devices)?);
    println!(
        "loaded {} ticks · target {}",
        schedule.ticks.len(),
        args.target
    );

    let client = Arc::new(
        reqwest::Client::builder()
            .pool_idle_timeout(Duration::from_secs(90))
            .tcp_nodelay(true)
            .build()?,
    );
    let url = format!("{}/locations/batch", args.target.trim_end_matches('/'));
    let semaphore = Arc::new(Semaphore::new(args.concurrency));

    let mut tick_idx = args.start_tick.min(schedule.ticks.len().saturating_sub(1));
    let mut tick = Instant::now();
    let mut rng = rand::thread_rng();

    loop {
        let points = &schedule.ticks[tick_idx];
        if !points.is_empty() {
            // Chunk into API-legal batches of <=500 points
            let mut handles = Vec::new();
            for chunk in points.chunks(500) {
                let n = chunk.len();
                let client = client.clone();
                let url = url.clone();
                let sem = semaphore.clone();
                let batch = BatchIn {
                    points: chunk.to_vec(),
                };
                let jitter = if args.jitter_ms > 0 {
                    rng.gen_range(0..args.jitter_ms)
                } else {
                    0
                };
                handles.push(tokio::spawn(async move {
                    sleep(Duration::from_millis(jitter)).await;
                    let _permit = sem.acquire().await;
                    // Retry with exponential backoff on failures — the
                    // tunnel target intermittently 502s whole bursts.
                    let mut posted = 0usize;
                    for attempt in 0..4u32 {
                        if attempt > 0 {
                            sleep(Duration::from_millis(200 << (attempt * 2))).await;
                        }
                        match client.post(&url).json(&batch).send().await {
                            Ok(r) if r.status().is_success() => {
                                posted = n;
                                break;
                            }
                            Ok(r) => {
                                let status = r.status();
                                let body = r.text().await.unwrap_or_default();
                                eprintln!(
                                    "post failed (attempt {}): HTTP {} · {}",
                                    attempt + 1,
                                    status,
                                    body
                                );
                            }
                            Err(e) => {
                                eprintln!("post error (attempt {}): {}", attempt + 1, e);
                            }
                        }
                    }
                    posted
                }));
            }
            let mut ok = 0usize;
            for h in handles {
                ok += h.await.unwrap_or(0);
            }
            if tick_idx % 60 == 0 {
                println!(
                    "[{} · tick {}] posted {}/{} points",
                    points[0].timestamp, tick_idx, ok,
                    points.len()
                );
            }
        }

        // Pace: next tick starts exactly tick_ms after the previous one
        tick += Duration::from_millis(args.tick_ms);
        let now = Instant::now();
        if tick > now {
            sleep(tick - now).await;
        } else {
            tick = now; // fell behind — reset pace instead of bursting
        }

        tick_idx += 1;
        if tick_idx >= schedule.ticks.len() {
            if args.once {
                break;
            }
            tick_idx = 0;
        }
    }
    Ok(())
}
