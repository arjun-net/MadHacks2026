//! Lookup speed for 100,000 and 1,000,000 GPS points.
//!
//!     cargo run --release --example bench_building_lookup
//!
//! Points are spread over the grid's bounding box plus 20% (so some fall off campus), from a
//! fixed-seed generator so runs are comparable. Only the lookups are timed.

use std::hint::black_box;
use std::time::Instant;

use madhacks_backend::buildings::{BuildingIndex, BuildingsConfig};

fn main() {
    let config = BuildingsConfig::default();
    let started = Instant::now();
    let index = BuildingIndex::load_or_build(&config).expect("building grid");
    let init = started.elapsed();
    let meta = index.meta();
    println!(
        "grid: {} cols x {} rows = {} cells at {} m, {} buildings",
        meta.cols, meta.rows, meta.cols * meta.rows, meta.resolution_m, meta.buildings.len()
    );
    println!("memory: {:.2} MB, startup load: {:.2} ms", index.memory_bytes() as f64 / 1e6, init.as_secs_f64() * 1e3);

    let (lat_pad, lng_pad) = ((meta.max_lat - meta.min_lat) * 0.1, (meta.max_lng - meta.min_lng) * 0.1);
    let (lat0, lat_span) = (meta.min_lat - lat_pad, meta.max_lat - meta.min_lat + 2.0 * lat_pad);
    let (lng0, lng_span) = (meta.min_lng - lng_pad, meta.max_lng - meta.min_lng + 2.0 * lng_pad);

    for n in [100_000usize, 1_000_000] {
        let mut seed = 0x9E37_79B9_7F4A_7C15u64;
        let mut unit = || {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            (seed >> 11) as f64 / (1u64 << 53) as f64
        };
        let points: Vec<(f64, f64)> = (0..n).map(|_| (lat0 + unit() * lat_span, lng0 + unit() * lng_span)).collect();

        // Warm up caches once, then time.
        for &(lat, lng) in points.iter().take(10_000) {
            black_box(index.building_name(lat, lng));
        }
        let started = Instant::now();
        let mut hits = 0usize;
        for &(lat, lng) in &points {
            hits += black_box(index.building_name(black_box(lat), black_box(lng))).is_some() as usize;
        }
        let name_time = started.elapsed();

        let started = Instant::now();
        for &(lat, lng) in &points {
            black_box(index.lookup(black_box(lat), black_box(lng), black_box(Some(10.0))));
        }
        let lookup_time = started.elapsed();

        println!(
            "{n:>9} lookups: building_name {:.2} ms ({:.1} ns each), lookup+accuracy {:.2} ms ({:.1} ns each), {:.1}% on a building",
            name_time.as_secs_f64() * 1e3,
            name_time.as_nanos() as f64 / n as f64,
            lookup_time.as_secs_f64() * 1e3,
            lookup_time.as_nanos() as f64 / n as f64,
            hits as f64 * 100.0 / n as f64,
        );
    }
}
