//! Regenerates the building lookup grid from assets/buildings.json (or $BUILDINGS_JSON) and
//! prints what it found. Run after editing buildings.json:
//!   cargo run --release --bin build_building_grid
//! Exits non-zero if the JSON can't be used.

use std::time::Instant;

use madhacks_backend::buildings::{build, save, BuildingsConfig};

fn main() {
    let config = BuildingsConfig::from_env();
    let source = std::fs::read(&config.source).unwrap_or_else(|e| {
        eprintln!("can't read {}: {e}", config.source.display());
        std::process::exit(1);
    });
    let started = Instant::now();
    let (meta, cells) = build(&source, &config).unwrap_or_else(|e| {
        eprintln!("can't build the grid: {e}");
        std::process::exit(1);
    });
    let elapsed = started.elapsed();
    if let Err(e) = save(&config, &meta, &cells) {
        eprintln!("can't save the grid: {e}");
        std::process::exit(1);
    }

    let filled = cells.iter().filter(|&&c| c != 0).count();
    println!("campus:      {}", meta.campus);
    println!("buildings:   {} in the grid, {} left out", meta.buildings.len(), meta.skipped.len());
    println!("grid:        {} cols × {} rows at {} m ({} cells, {:.1}% on a building)",
        meta.cols, meta.rows, meta.resolution_m, cells.len(), 100.0 * filled as f64 / cells.len() as f64);
    println!("bounds:      lat {:.6}…{:.6}, lng {:.6}…{:.6} (margin {} m, buildings reach {} m past their walls)", meta.min_lat, meta.max_lat, meta.min_lng, meta.max_lng, meta.margin_m, meta.buffer_m);
    println!("memory:      {:.2} MB of u16 cells", (cells.len() * 2) as f64 / 1_048_576.0);
    println!("built in:    {elapsed:?}");
    println!("checksum:    {}", meta.source_checksum);
    for skipped in &meta.skipped {
        println!("left out:    #{} {:?}: {}", skipped.index, skipped.key, skipped.reason);
    }
    for overlap in &meta.overlaps {
        println!("overlap:     {} / {}: {} cells → {}", overlap.a, overlap.b, overlap.cells, overlap.winner);
    }
    println!("wrote:       {} and {}", config.meta_path().display(), config.cells_path().display());
}
