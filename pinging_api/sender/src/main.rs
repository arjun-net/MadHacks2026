//! Campus Pulse — persistent device-ping sender.
//!
//! Reads the apicalls CSV (lat,long,timestamp,building) and replays it in
//! real time: once per tick (one CSV timestamp, 2 minutes of sim time =
//! wall-clock `--tick-ms`) it fires one HTTP POST per device — one row per
//! device — all within the same tick, staggered by a small random jitter
//! (default 0–40 ms) for realism. All posts go to the configurable FastAPI
//! target with the exact new shape:
//!
//! ```json
//! [{"lat": 43.071658, "long": -89.399816, "timestamp": "2026-11-12T00:00:00Z", "building": "sellery_hall"}]
//! ```
//!
//! Runs forever (loops the CSV timeline) until interrupted.

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
#[command(name = "campus-pulse-sender", about = "Replays device pings from the apicalls CSV to a live ingest endpoint")]
struct Args {
    /// Input CSV (lat,long,timestamp,building). Default: PULSE_CSV or
    /// data/campus_simulation_apicalls.csv relative to the .env location.
    #[arg(short, long, env = "PULSE_CSV", default_value = "data/campus_simulation_apicalls.csv")]
    csv: String,

    /// Target base URL of the FastAPI ingest service (no trailing slash)
    #[arg(short, long, env = "PULSE_TARGET", default_value = "http://127.0.0.1:8000")]
    target: String,

    /// Ingest path on the target
    #[arg(long, env = "PULSE_PATH", default_value = "/ingest")]
    path: String,

    /// Wall-clock milliseconds per tick (one CSV timestamp per tick)
    #[arg(long, env = "PULSE_TICK_MS", default_value_t = 2000)]
    tick_ms: u64,

    /// Max per-device POST stagger jitter in milliseconds (0..jitter_ms)
    #[arg(long, env = "PULSE_JITTER_MS", default_value_t = 40)]
    jitter_ms: u64,

    /// Max concurrent in-flight POSTs
    #[arg(long, env = "PULSE_CONCURRENCY", default_value_t = 200)]
    concurrency: usize,

    /// Number of devices (rows) to post per tick — first N rows
    #[arg(long, env = "PULSE_DEVICES")]
    devices: Option<usize>,

    /// Start at this tick index instead of 0
    #[arg(long, env = "PULSE_START_TICK", default_value_t = 0)]
    start_tick: usize,

    /// Exit after one full pass of the CSV instead of looping forever
    #[arg(long, env = "PULSE_ONCE", action = clap::ArgAction::SetTrue)]
    once: bool,
}

#[derive(Debug, Clone, Serialize)]
struct Ping {
    lat: f64,
    long: f64,
    timestamp: String,
    building: String,
}

/// ticks in chronological order; ticks[i] = the device pings for tick i
struct Schedule {
    ticks: Vec<Vec<Ping>>,
}

fn load_schedule(path: &str, devices: Option<usize>) -> Result<Schedule> {
    let mut rdr = csv::ReaderBuilder::new()
        .trim(csv::Trim::All)
        .from_reader(File::open(path).with_context(|| format!("open {}", path))?);

    // BTreeMap over timestamp string sorts chronologically (ISO 8601 UTC
    // sorts lexicographically) and merges same-timestamp rows.
    let mut by_ts: BTreeMap<String, Vec<Ping>> = BTreeMap::new();

    for rec in rdr.records() {
        let rec = rec.with_context(|| "bad CSV record")?;
        // columns: lat,long,timestamp,building
        let lat: f64 = rec[0].parse().unwrap_or(0.0);
        let long: f64 = rec[1].parse().unwrap_or(0.0);
        let timestamp = rec[2].to_string();
        let building = rec[3].to_string();
        by_ts.entry(timestamp.clone()).or_default().push(Ping {
            lat,
            long,
            timestamp,
            building,
        });
    }

    let mut ticks: Vec<Vec<Ping>> = by_ts.into_values().collect();
    if let Some(n) = devices {
        for t in ticks.iter_mut() {
            t.truncate(n);
        }
    }
    Ok(Schedule { ticks })
}

#[tokio::main]
async fn main() -> Result<()> {
    // Load .env: the worker may be started from any cwd, so look next to the
    // executable's Cargo-project root (sender/) and its parent dir.
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
        "loaded {} ticks · target {}{}",
        schedule.ticks.len(),
        args.target,
        args.path
    );

    let client = Arc::new(
        reqwest::Client::builder()
            .pool_idle_timeout(Duration::from_secs(90))
            .tcp_nodelay(true)
            .build()?,
    );
    let url = format!("{}{}", args.target.trim_end_matches('/'), args.path);
    let semaphore = Arc::new(Semaphore::new(args.concurrency));

    let mut tick_idx = args.start_tick.min(schedule.ticks.len().saturating_sub(1));
    let mut tick = Instant::now();
    let mut rng = rand::thread_rng();

    loop {
        let pings = &schedule.ticks[tick_idx];
        if !pings.is_empty() {
            let mut handles = Vec::with_capacity(pings.len());
            for ping in pings {
                let client = client.clone();
                let url = url.clone();
                let ping = ping.clone();
                let sem = semaphore.clone();
                let jitter = if args.jitter_ms > 0 {
                    rng.gen_range(0..args.jitter_ms)
                } else {
                    0
                };
                handles.push(tokio::spawn(async move {
                    sleep(Duration::from_millis(jitter)).await;
                    let _permit = sem.acquire().await;
                    let res = client.post(&url).json(&vec![ping]).send().await;
                    match res {
                        Ok(r) if r.status().is_success() => 1,
                        Ok(r) => {
                            eprintln!("post failed: HTTP {}", r.status());
                            0
                        }
                        Err(e) => {
                            eprintln!("post error: {e}");
                            0
                        }
                    }
                }));
            }
            let mut ok = 0usize;
            for h in handles {
                ok += h.await.unwrap_or(0);
            }
            if tick_idx % 60 == 0 {
                println!(
                    "[{} · tick {}] posted {}/{} pings",
                    pings[0].timestamp, tick_idx, ok,
                    pings.len()
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
