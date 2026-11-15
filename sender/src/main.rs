//! Campus Pulse — persistent device-ping sender.
//!
//! Reads the generator's history CSV (all 400 agents × full day), then
//! replays it in real time: once per simulation tick (2 sim-minutes = one
//! wall-clock `--tick-ms` interval, default 2000 ms) it fires one HTTP POST
//! per device with that device's current ping, staggered by a small random
//! jitter (default 0–40 ms) for realism. All posts go to the configurable
//! FastAPI target. Runs forever (loops the day) until interrupted.
//!
//! CSV columns: agent_id,timestamp,minute_of_day,state,building_id,lat,lng

use anyhow::{Context, Result};
use clap::Parser;
use rand::Rng;
use serde::Serialize;
use std::fs::File;
use std::sync::Arc;
use tokio::sync::Semaphore;
use tokio::time::{sleep, Duration, Instant};

#[derive(Parser, Debug)]
#[command(name = "campus-pulse-sender", about = "Replays device pings from the simulation CSV to a live ingest endpoint")]
struct Args {
    /// Path to the simulation history CSV
    #[arg(short, long, default_value = "../data/campus_simulation_history.csv")]
    csv: String,

    /// Target base URL of the FastAPI ingest service (no trailing slash)
    #[arg(short, long, default_value = "http://127.0.0.1:8000")]
    target: String,

    /// Ingest path on the target
    #[arg(long, default_value = "/ingest")]
    path: String,

    /// Wall-clock milliseconds per simulation tick (720 ticks per day)
    #[arg(long, default_value_t = 2000)]
    tick_ms: u64,

    /// Max per-device POST stagger jitter in milliseconds (0..jitter_ms)
    #[arg(long, default_value_t = 40)]
    jitter_ms: u64,

    /// Max concurrent in-flight POSTs (400 devices → bursts; raise if the
    /// target can take it, lower to smooth the spike)
    #[arg(long, default_value_t = 400)]
    concurrency: usize,

    /// Number of devices to simulate (first N agent_ids from the CSV)
    #[arg(long)]
    devices: Option<usize>,

    /// Start at this simulation minute instead of 0
    #[arg(long, default_value_t = 0)]
    start_minute: u16,

    /// Exit after one full day instead of looping forever
    #[arg(long)]
    once: bool,
}

#[derive(Debug, Clone, Serialize)]
struct Ping {
    agent_id: u32,
    timestamp: String,
    minute_of_day: u16,
    state: String,
    building_id: String,
    lat: f64,
    lng: f64,
}

/// rows[minute][device_index] — 720 × N grid for O(1) tick lookup
struct Schedule {
    rows: Vec<Vec<Ping>>,
    device_count: usize,
}

fn load_schedule(path: &str, devices: Option<usize>) -> Result<Schedule> {
    let mut rdr = csv::ReaderBuilder::new()
        .trim(csv::Trim::All)
        .from_reader(File::open(path).with_context(|| format!("open {}", path))?);

    let mut ids_set: std::collections::HashSet<u32> = std::collections::HashSet::new();
    let mut ids: Vec<u32> = Vec::new();
    let mut minutes: Vec<Vec<Ping>> = vec![Vec::new(); 24 * 60];
    let mut n_rec = 0usize;

    for rec in rdr.records() {
        let rec = rec.with_context(|| "bad CSV record")?;
        n_rec += 1;
        let agent_id: u32 = rec[0].parse().unwrap_or(0);
        let minute: usize = rec[2].parse().unwrap_or(0);
        let timestamp = rec[1].to_string();
        let state = rec[3].to_string();
        let building_id = rec[4].to_string();
        let lat: f64 = rec[5].parse().unwrap_or(0.0);
        let lng: f64 = rec[6].parse().unwrap_or(0.0);
        if minute >= minutes.len() {
            continue;
        }
        if ids_set.insert(agent_id) {
            ids.push(agent_id);
        }
        minutes[minute].push(Ping {
            agent_id,
            timestamp,
            minute_of_day: minute as u16,
            state,
            building_id,
            lat,
            lng,
        });
    }
    let _ = n_rec;

    let device_count = match devices {
        Some(n) => n.min(ids.len()),
        None => ids.len(),
    };
    let keep: std::collections::HashSet<u32> = ids.iter().take(device_count).copied().collect();
    for m in minutes.iter_mut() {
        m.retain(|p| keep.contains(&p.agent_id));
        m.sort_by_key(|p| p.agent_id);
    }
    Ok(Schedule {
        rows: minutes,
        device_count,
    })
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let schedule = Arc::new(load_schedule(&args.csv, args.devices)?);
    println!(
        "loaded {} devices · {} minutes · target {}{}",
        schedule.device_count,
        schedule.rows.len(),
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

    let mut minute = args.start_minute as usize % schedule.rows.len();
    let mut tick = Instant::now();
    let mut rng = rand::thread_rng();

    loop {
        let pings = &schedule.rows[minute];
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
            if minute % 60 == 0 {
                println!(
                    "[{:02}:{:02}] posted {}/{} pings",
                    minute / 60,
                    minute % 60,
                    ok,
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

        minute += 1;
        if minute >= schedule.rows.len() && args.once {
            break;
        }
        minute %= schedule.rows.len();
    }
    Ok(())
}
