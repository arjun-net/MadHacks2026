//! GPS → campus building in constant time.
//!
//! Preprocessing (rare): read `assets/buildings.json`, validate each building, give it a small
//! integer id (1, 2, 3, …; 0 means "no building"), and rasterize every perimeter polygon onto a
//! grid of ~2 m cells laid over campus. The grid and the id → name table are saved next to the
//! JSON (`building_grid.json` + `building_grid.bin`) together with a checksum of the JSON, so a
//! stale grid is detected instead of silently used.
//!
//! Runtime (every ping): two multiplications turn latitude/longitude into a row and column,
//! one array read gives the building id, one more gives the name. No loops over buildings,
//! no polygon tests, no database or network calls.
//!
//! The grid is square (N × N cells). Each building also claims a buffer around its outline
//! (`buffer_m`, 15 m by default), because phone GPS indoors is often off by 10–50 m and tends to
//! put someone inside a building just outside its walls. A cell inside a real outline always
//! belongs to that building; a cell only in buffers goes to the nearest building.
//!
//! This is an approximation. A building name means "the reported position is on or near that
//! building's footprint", not "the student is indoors there". Pings whose reported accuracy is
//! worse than a threshold get no building.

use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Bump when the grid file layout or rasterization rules change.
pub const FORMAT_VERSION: u32 = 2;

/// Settings for building and using the grid. Read from the environment by `from_env`.
#[derive(Clone, Debug)]
pub struct BuildingsConfig {
    /// `assets/buildings.json` by default.
    pub source: PathBuf,
    /// Folder for `building_grid.json` and `building_grid.bin` (the JSON's folder by default).
    pub grid_dir: PathBuf,
    /// Cell size in meters.
    pub resolution_m: f64,
    /// Empty border around the outermost building, in meters.
    pub margin_m: f64,
    /// How far outside its outline a building still claims cells, in meters (GPS slack).
    pub buffer_m: f64,
    /// Pings reporting a horizontal accuracy worse than this get no building. `None` = no limit.
    pub max_accuracy_m: Option<f64>,
    /// Rebuild (and save) the grid at startup when it's missing or out of date.
    pub rebuild_if_stale: bool,
}

impl Default for BuildingsConfig {
    fn default() -> Self {
        let assets = Path::new(env!("CARGO_MANIFEST_DIR")).join("assets");
        Self {
            source: assets.join("buildings.json"),
            grid_dir: assets,
            resolution_m: 2.0,
            margin_m: 10.0,
            buffer_m: 15.0,
            max_accuracy_m: Some(30.0),
            rebuild_if_stale: true,
        }
    }
}

impl BuildingsConfig {
    pub fn from_env() -> Self {
        let mut config = Self::default();
        if let Ok(path) = std::env::var("BUILDINGS_JSON") {
            config.source = PathBuf::from(&path);
            config.grid_dir = config.source.parent().map(Path::to_path_buf).unwrap_or_default();
        }
        if let Ok(dir) = std::env::var("BUILDING_GRID_DIR") {
            config.grid_dir = PathBuf::from(dir);
        }
        if let Some(v) = env_f64("BUILDING_GRID_RESOLUTION_M") {
            config.resolution_m = v;
        }
        if let Some(v) = env_f64("BUILDING_GRID_MARGIN_M") {
            config.margin_m = v;
        }
        if let Some(v) = env_f64("BUILDING_BUFFER_M") {
            config.buffer_m = v;
        }
        match std::env::var("BUILDING_MAX_ACCURACY_M").as_deref() {
            Ok("" | "off" | "none") => config.max_accuracy_m = None,
            Ok(v) => config.max_accuracy_m = Some(v.parse().expect("BUILDING_MAX_ACCURACY_M must be a number or 'off'")),
            Err(_) => {}
        }
        if let Ok(v) = std::env::var("BUILDING_GRID_REBUILD") {
            config.rebuild_if_stale = !matches!(v.as_str(), "0" | "false" | "no");
        }
        config
    }

    pub fn meta_path(&self) -> PathBuf {
        self.grid_dir.join("building_grid.json")
    }

    pub fn cells_path(&self) -> PathBuf {
        self.grid_dir.join("building_grid.bin")
    }
}

fn env_f64(name: &str) -> Option<f64> {
    std::env::var(name).ok().map(|v| v.parse().unwrap_or_else(|_| panic!("{name} must be a number")))
}

/// One building as stored with the grid. `id` is the integer in the grid cells.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct BuildingEntry {
    pub id: u16,
    /// The `id` string from buildings.json.
    pub key: String,
    pub name: String,
    #[serde(rename = "type")]
    pub kind: String,
    /// Polygon area in square meters (used by the overlap rule).
    pub area_m2: f64,
}

/// Two outlines that claim the same cells, and who got them.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Overlap {
    pub a: String,
    pub b: String,
    pub cells: usize,
    pub winner: String,
}

/// A building left out of the grid, and why.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Skipped {
    pub index: usize,
    pub key: Option<String>,
    pub reason: String,
}

/// Everything needed to turn a coordinate into a cell, plus the id → name table.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct GridMeta {
    pub format_version: u32,
    /// FNV-1a 64 of the exact bytes of buildings.json the grid was made from.
    pub source_checksum: String,
    pub campus: String,
    pub resolution_m: f64,
    pub margin_m: f64,
    #[serde(default)]
    pub buffer_m: f64,
    /// Grid edges in degrees. Row 0 is the northern edge (`max_lat`), column 0 the western edge.
    pub min_lat: f64,
    pub max_lat: f64,
    pub min_lng: f64,
    pub max_lng: f64,
    /// Local flat-earth scale at the grid's middle latitude (good to well under 0.1% across campus).
    pub meters_per_deg_lat: f64,
    pub meters_per_deg_lng: f64,
    pub rows: usize,
    pub cols: usize,
    pub buildings: Vec<BuildingEntry>,
    /// How overlaps were resolved: the smaller outline wins (it's the more specific building,
    /// e.g. a hall drawn inside a larger complex); equal areas go to the lower id.
    pub overlap_policy: String,
    pub overlaps: Vec<Overlap>,
    pub skipped: Vec<Skipped>,
}

/// The loaded grid, kept in memory for the life of the server.
pub struct BuildingIndex {
    meta: GridMeta,
    cells: Vec<u16>,
    /// `names[id]`; index 0 is unused (no building).
    names: Vec<Option<Arc<str>>>,
    /// Cells per degree, precomputed so a lookup is two multiplications.
    cols_per_deg: f64,
    rows_per_deg: f64,
    max_accuracy_m: Option<f64>,
}

impl BuildingIndex {
    // MARK: Runtime lookups (constant time)

    /// Grid cell for a coordinate, or `None` outside the grid (or for NaN/infinite input).
    /// Cells are half-open: a point exactly on a line between two cells belongs to the cell to
    /// its east/south, and the grid's own eastern/southern edge is outside.
    #[inline]
    pub fn cell_index(&self, lat: f64, lng: f64) -> Option<(usize, usize)> {
        let x = (lng - self.meta.min_lng) * self.cols_per_deg;
        let y = (self.meta.max_lat - lat) * self.rows_per_deg;
        // Written so NaN fails both comparisons.
        if !(x >= 0.0 && y >= 0.0 && x < self.meta.cols as f64 && y < self.meta.rows as f64) {
            return None;
        }
        Some((y as usize, x as usize))
    }

    /// Building id at a coordinate (0 = none). O(1): index arithmetic and one array read.
    #[inline]
    pub fn building_id(&self, lat: f64, lng: f64) -> u16 {
        match self.cell_index(lat, lng) {
            Some((row, col)) => self.cells[row * self.meta.cols + col],
            None => 0,
        }
    }

    /// Name for an id (`None` for 0 or an unknown id). O(1).
    #[inline]
    pub fn name_for_id(&self, id: u16) -> Option<&Arc<str>> {
        self.names.get(id as usize).and_then(Option::as_ref)
    }

    /// Building name at a coordinate, or `None` when it's not on a mapped building.
    #[inline]
    pub fn building_name(&self, lat: f64, lng: f64) -> Option<&Arc<str>> {
        self.name_for_id(self.building_id(lat, lng))
    }

    /// What the ingest pipeline stores. `accuracy_m` is the phone's reported horizontal
    /// accuracy (meters); when it's worse than the configured limit, or reported as invalid
    /// (negative), the ping isn't classified rather than guessed.
    #[inline]
    pub fn lookup(&self, lat: f64, lng: f64, accuracy_m: Option<f64>) -> Option<Arc<str>> {
        if let (Some(limit), Some(accuracy)) = (self.max_accuracy_m, accuracy_m) {
            if !(accuracy >= 0.0 && accuracy <= limit) {
                return None;
            }
        }
        self.building_name(lat, lng).cloned()
    }

    pub fn meta(&self) -> &GridMeta {
        &self.meta
    }

    pub fn cells(&self) -> &[u16] {
        &self.cells
    }

    /// Bytes held by the grid and the name table.
    pub fn memory_bytes(&self) -> usize {
        self.cells.len() * std::mem::size_of::<u16>()
            + self.names.iter().flatten().map(|n| n.len()).sum::<usize>()
            + self.names.len() * std::mem::size_of::<Option<Arc<str>>>()
    }

    /// An index that never finds a building (for tests and tools that don't need one).
    pub fn empty() -> Self {
        let meta = GridMeta {
            format_version: FORMAT_VERSION,
            source_checksum: String::new(),
            campus: String::new(),
            resolution_m: 1.0,
            margin_m: 0.0,
            buffer_m: 0.0,
            min_lat: 0.0,
            max_lat: 0.0,
            min_lng: 0.0,
            max_lng: 0.0,
            meters_per_deg_lat: 1.0,
            meters_per_deg_lng: 1.0,
            rows: 0,
            cols: 0,
            buildings: vec![],
            overlap_policy: String::new(),
            overlaps: vec![],
            skipped: vec![],
        };
        Self::from_parts(meta, vec![], None)
    }

    fn from_parts(meta: GridMeta, cells: Vec<u16>, max_accuracy_m: Option<f64>) -> Self {
        let mut names: Vec<Option<Arc<str>>> = vec![None; meta.buildings.len() + 1];
        for building in &meta.buildings {
            names[building.id as usize] = Some(Arc::from(building.name.as_str()));
        }
        Self {
            cols_per_deg: meta.meters_per_deg_lng / meta.resolution_m,
            rows_per_deg: meta.meters_per_deg_lat / meta.resolution_m,
            meta,
            cells,
            names,
            max_accuracy_m,
        }
    }

    // MARK: Startup

    /// Loads the saved grid. If it's missing or was made from a different buildings.json (or
    /// different settings), rebuilds and saves it when `rebuild_if_stale` is set, otherwise
    /// fails with an explanation. Never returns a grid that doesn't match the current JSON.
    pub fn load_or_build(config: &BuildingsConfig) -> Result<Self, String> {
        let source = fs::read(&config.source)
            .map_err(|e| format!("can't read buildings file {}: {e}", config.source.display()))?;
        match Self::load(config, &source) {
            Ok(index) => Ok(index),
            Err(reason) if config.rebuild_if_stale => {
                tracing::warn!("building grid needs rebuilding ({reason}); building it from {}", config.source.display());
                let (meta, cells) = build(&source, config)?;
                for overlap in &meta.overlaps {
                    tracing::warn!("buildings overlap: {} and {} share {} cells; {} keeps them", overlap.a, overlap.b, overlap.cells, overlap.winner);
                }
                for skipped in &meta.skipped {
                    tracing::warn!("building #{} ({:?}) left out: {}", skipped.index, skipped.key, skipped.reason);
                }
                if let Err(e) = save(config, &meta, &cells) {
                    // Still correct, just rebuilt again next start.
                    tracing::warn!("couldn't save the building grid: {e}");
                }
                Ok(Self::from_parts(meta, cells, config.max_accuracy_m))
            }
            Err(reason) => Err(format!(
                "building grid is missing or out of date ({reason}). Run `cargo run --release --bin build_building_grid`, \
                 or set BUILDING_GRID_REBUILD=1"
            )),
        }
    }

    /// Loads the saved grid, checking it was made from exactly `source` with these settings.
    pub fn load(config: &BuildingsConfig, source: &[u8]) -> Result<Self, String> {
        let meta_bytes = fs::read(config.meta_path()).map_err(|e| format!("no grid metadata: {e}"))?;
        let meta: GridMeta = serde_json::from_slice(&meta_bytes).map_err(|e| format!("unreadable grid metadata: {e}"))?;
        if meta.format_version != FORMAT_VERSION {
            return Err(format!("grid format {} but this server expects {FORMAT_VERSION}", meta.format_version));
        }
        if meta.source_checksum != checksum(source) {
            return Err("buildings.json changed since the grid was made".into());
        }
        if meta.resolution_m != config.resolution_m || meta.margin_m != config.margin_m || meta.buffer_m != config.buffer_m {
            return Err("grid resolution, margin or buffer differs from the configured values".into());
        }
        let packed = fs::read(config.cells_path()).map_err(|e| format!("no grid cells: {e}"))?;
        let cells = decode_cells(&packed, meta.rows * meta.cols)?;
        let max_id = meta.buildings.len() as u16;
        if cells.iter().any(|&id| id > max_id) {
            return Err("grid refers to a building id that isn't in its table".into());
        }
        Ok(Self::from_parts(meta, cells, config.max_accuracy_m))
    }
}

// MARK: Preprocessing

struct Candidate {
    /// Position in the JSON's buildings array.
    index: usize,
    key: String,
    name: String,
    kind: String,
    /// Polygon in degrees: (lat, lng).
    ring: Vec<(f64, f64)>,
}

/// FNV-1a 64-bit, hex. Detects any change to buildings.json (not a security hash).
pub fn checksum(bytes: &[u8]) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for &b in bytes {
        hash ^= b as u64;
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{hash:016x}")
}

/// Meters per degree of latitude and longitude at a latitude (WGS-84 series).
pub fn meters_per_degree(lat: f64) -> (f64, f64) {
    let phi = lat.to_radians();
    let lat_m = 111_132.92 - 559.82 * (2.0 * phi).cos() + 1.175 * (4.0 * phi).cos();
    let lng_m = 111_412.84 * phi.cos() - 93.5 * (3.0 * phi).cos();
    (lat_m, lng_m)
}

/// Reads and checks every building. Bad ones are reported in `skipped`, not guessed at.
fn parse_buildings(source: &[u8]) -> Result<(String, Vec<Candidate>, Vec<Skipped>), String> {
    let root: Value = serde_json::from_slice(source).map_err(|e| format!("buildings.json isn't valid JSON: {e}"))?;
    let campus = root.get("campus").and_then(Value::as_str).unwrap_or("").to_string();
    let list = root.get("buildings").and_then(Value::as_array).ok_or("buildings.json has no \"buildings\" array")?;

    let mut candidates = Vec::new();
    let mut skipped = Vec::new();
    let mut seen = HashSet::new();
    for (index, item) in list.iter().enumerate() {
        let key = item.get("id").and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()).map(String::from);
        let mut skip = |reason: String| skipped.push(Skipped { index, key: key.clone(), reason });

        let Some(key_value) = key.clone() else { skip("missing id".into()); continue };
        let Some(name) = item.get("name").and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()) else {
            skip("missing name".into());
            continue;
        };
        if !seen.insert(key_value.clone()) {
            skip("duplicate id".into());
            continue;
        }
        let kind = item.get("type").and_then(Value::as_str).unwrap_or("").to_string();
        let Some(raw) = item.get("perimeter_polygon").and_then(Value::as_array) else {
            skip("missing perimeter_polygon".into());
            continue;
        };

        let mut ring: Vec<(f64, f64)> = Vec::with_capacity(raw.len());
        let mut bad_vertex = None;
        for (i, vertex) in raw.iter().enumerate() {
            let pair = vertex.as_array().filter(|v| v.len() == 2).and_then(|v| Some((v[0].as_f64()?, v[1].as_f64()?)));
            match pair {
                Some((lat, lng)) if lat.is_finite() && lng.is_finite() && (-90.0..=90.0).contains(&lat) && (-180.0..=180.0).contains(&lng) => {
                    // Drop repeated points (including a closing copy of the first point).
                    if ring.last() != Some(&(lat, lng)) {
                        ring.push((lat, lng));
                    }
                }
                _ => {
                    bad_vertex = Some(i);
                    break;
                }
            }
        }
        if let Some(i) = bad_vertex {
            skip(format!("vertex {i} isn't a valid [lat, lng] pair"));
            continue;
        }
        if ring.len() > 1 && ring.first() == ring.last() {
            ring.pop();
        }
        if ring.len() < 3 {
            skip(format!("polygon needs at least 3 distinct points, has {}", ring.len()));
            continue;
        }
        candidates.push(Candidate { index, key: key_value, name: name.to_string(), kind, ring });
    }
    Ok((campus, candidates, skipped))
}

/// Area of a polygon (shoelace), in the polygon's units squared.
fn polygon_area(points: &[(f64, f64)]) -> f64 {
    let n = points.len();
    let mut twice = 0.0;
    for i in 0..n {
        let (x1, y1) = points[i];
        let (x2, y2) = points[(i + 1) % n];
        twice += x1 * y2 - x2 * y1;
    }
    (twice / 2.0).abs()
}

/// Even-odd ray casting. Handles any simple or concave polygon.
fn contains(points: &[(f64, f64)], x: f64, y: f64) -> bool {
    let mut inside = false;
    let mut j = points.len() - 1;
    for i in 0..points.len() {
        let (xi, yi) = points[i];
        let (xj, yj) = points[j];
        if (yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi {
            inside = !inside;
        }
        j = i;
    }
    inside
}

/// Shortest distance from a point to a polygon's edges.
fn edge_distance(points: &[(f64, f64)], x: f64, y: f64) -> f64 {
    let mut best = f64::MAX;
    let mut j = points.len() - 1;
    for i in 0..points.len() {
        let ((ax, ay), (bx, by)) = (points[j], points[i]);
        let (dx, dy) = (bx - ax, by - ay);
        let length2 = dx * dx + dy * dy;
        let t = if length2 > 0.0 { (((x - ax) * dx + (y - ay) * dy) / length2).clamp(0.0, 1.0) } else { 0.0 };
        best = best.min((x - ax - t * dx).hypot(y - ay - t * dy));
        j = i;
    }
    best
}

/// Builds the grid and its metadata from the bytes of buildings.json.
pub fn build(source: &[u8], config: &BuildingsConfig) -> Result<(GridMeta, Vec<u16>), String> {
    if !(config.resolution_m > 0.0) || !(config.margin_m >= 0.0) || !(config.buffer_m >= 0.0) {
        return Err("grid resolution must be positive, margin and buffer non-negative".into());
    }
    let (campus, candidates, mut skipped) = parse_buildings(source)?;

    // Extent of every polygon, padded by the buffer and the margin.
    let (mut min_lat, mut max_lat, mut min_lng, mut max_lng) = (f64::MAX, f64::MIN, f64::MAX, f64::MIN);
    for c in &candidates {
        for &(lat, lng) in &c.ring {
            min_lat = min_lat.min(lat);
            max_lat = max_lat.max(lat);
            min_lng = min_lng.min(lng);
            max_lng = max_lng.max(lng);
        }
    }
    if candidates.is_empty() {
        return Err("buildings.json has no valid buildings".into());
    }
    let (m_lat, m_lng) = meters_per_degree((min_lat + max_lat) / 2.0);
    let pad = config.margin_m + config.buffer_m;
    min_lat -= pad / m_lat;
    max_lat += pad / m_lat;
    min_lng -= pad / m_lng;
    max_lng += pad / m_lng;
    let res = config.resolution_m;
    let cols = (((max_lng - min_lng) * m_lng) / res).ceil() as usize;
    let rows = (((max_lat - min_lat) * m_lat) / res).ceil() as usize;
    // A square N × N grid with the buildings centered in it.
    let n = cols.max(rows);
    min_lng -= ((n - cols) / 2) as f64 * res / m_lng;
    max_lat += ((n - rows) / 2) as f64 * res / m_lat;
    let (rows, cols) = (n, n);
    // Snap the far edges to whole cells, anchored at the north-west corner.
    max_lng = min_lng + cols as f64 * res / m_lng;
    min_lat = max_lat - rows as f64 * res / m_lat;

    // Polygons in grid meters: x east from the west edge, y south from the north edge.
    struct Shape {
        id: u16,
        points: Vec<(f64, f64)>,
        area: f64,
    }
    let mut entries = Vec::new();
    let mut shapes = Vec::new();
    for c in candidates {
        let points: Vec<(f64, f64)> = c.ring.iter().map(|&(lat, lng)| ((lng - min_lng) * m_lng, (max_lat - lat) * m_lat)).collect();
        let area = polygon_area(&points);
        if area < 1.0 {
            skipped.push(Skipped { index: c.index, key: Some(c.key.clone()), reason: format!("polygon has no area ({area:.2} m²)") });
            continue;
        }
        if entries.len() >= u16::MAX as usize {
            return Err("more buildings than fit in a 16-bit id".into());
        }
        let id = entries.len() as u16 + 1;
        entries.push(BuildingEntry { id, key: c.key, name: c.name, kind: c.kind, area_m2: (area * 10.0).round() / 10.0 });
        shapes.push(Shape { id, points, area });
    }

    // Larger outlines first, so smaller (more specific) ones are drawn over them; equal areas
    // draw the higher id first so the lower id ends up on top. Order never depends on hashing.
    shapes.sort_by(|a, b| b.area.total_cmp(&a.area).then(b.id.cmp(&a.id)));

    let mut cells = vec![0u16; rows * cols];
    let mut overlaps: BTreeMap<(u16, u16), (usize, u16)> = BTreeMap::new();
    for shape in &shapes {
        let (mut x0, mut y0, mut x1, mut y1) = (f64::MAX, f64::MAX, f64::MIN, f64::MIN);
        for &(x, y) in &shape.points {
            x0 = x0.min(x);
            y0 = y0.min(y);
            x1 = x1.max(x);
            y1 = y1.max(y);
        }
        // Only the cells whose centers could be inside.
        let c0 = ((x0 / res - 0.5).floor().max(0.0)) as usize;
        let c1 = ((x1 / res - 0.5).ceil().max(0.0) as usize).min(cols - 1);
        let r0 = ((y0 / res - 0.5).floor().max(0.0)) as usize;
        let r1 = ((y1 / res - 0.5).ceil().max(0.0) as usize).min(rows - 1);
        for row in r0..=r1 {
            let cy = (row as f64 + 0.5) * res;
            for col in c0..=c1 {
                let cx = (col as f64 + 0.5) * res;
                if !contains(&shape.points, cx, cy) {
                    continue;
                }
                let cell = &mut cells[row * cols + col];
                if *cell != 0 {
                    let pair = ((*cell).min(shape.id), (*cell).max(shape.id));
                    let entry = overlaps.entry(pair).or_insert((0, shape.id));
                    entry.0 += 1;
                    entry.1 = shape.id;
                }
                *cell = shape.id;
            }
        }
    }

    // Buffers: cells outside every outline but within `buffer_m` of one go to the nearest
    // building (ties to the lower id: ids are visited in order and only a strictly closer
    // building replaces one already chosen).
    if config.buffer_m > 0.0 {
        let buffer = config.buffer_m;
        let mut claimed: BTreeMap<usize, (f64, u16)> = BTreeMap::new();
        let mut by_id: Vec<&Shape> = shapes.iter().collect();
        by_id.sort_by_key(|s| s.id);
        for shape in by_id {
            let (mut x0, mut y0, mut x1, mut y1) = (f64::MAX, f64::MAX, f64::MIN, f64::MIN);
            for &(x, y) in &shape.points {
                x0 = x0.min(x - buffer);
                y0 = y0.min(y - buffer);
                x1 = x1.max(x + buffer);
                y1 = y1.max(y + buffer);
            }
            let c0 = ((x0 / res - 0.5).floor().max(0.0)) as usize;
            let c1 = ((x1 / res - 0.5).ceil().max(0.0) as usize).min(cols - 1);
            let r0 = ((y0 / res - 0.5).floor().max(0.0)) as usize;
            let r1 = ((y1 / res - 0.5).ceil().max(0.0) as usize).min(rows - 1);
            for row in r0..=r1 {
                let cy = (row as f64 + 0.5) * res;
                for col in c0..=c1 {
                    let index = row * cols + col;
                    if cells[index] != 0 {
                        continue;
                    }
                    let cx = (col as f64 + 0.5) * res;
                    let distance = edge_distance(&shape.points, cx, cy);
                    if distance > buffer {
                        continue;
                    }
                    match claimed.get(&index) {
                        Some(&(best, _)) if best <= distance => {}
                        _ => {
                            claimed.insert(index, (distance, shape.id));
                        }
                    }
                }
            }
        }
        for (index, (_, id)) in claimed {
            cells[index] = id;
        }
    }

    let key_of = |id: u16| entries[id as usize - 1].key.clone();
    let overlaps = overlaps
        .into_iter()
        .map(|((a, b), (cells, winner))| Overlap { a: key_of(a), b: key_of(b), cells, winner: key_of(winner) })
        .collect();

    let meta = GridMeta {
        format_version: FORMAT_VERSION,
        source_checksum: checksum(source),
        campus,
        resolution_m: config.resolution_m,
        margin_m: config.margin_m,
        buffer_m: config.buffer_m,
        min_lat,
        max_lat,
        min_lng,
        max_lng,
        meters_per_deg_lat: m_lat,
        meters_per_deg_lng: m_lng,
        rows,
        cols,
        buildings: entries,
        overlap_policy: "inside overlapping outlines the smaller polygon area wins (equal areas: lower id); \
                         a real outline always beats another building's buffer; in buffers only, the nearest outline wins (ties: lower id)"
            .into(),
        overlaps,
        skipped,
    };
    Ok((meta, cells))
}

// MARK: Saving

/// Writes the metadata (readable JSON) and the cells (run-length encoded: little-endian
/// `u16 id, u32 count` pairs, row by row from the north-west corner). Campus is mostly
/// empty space, so this is a few tens of KB instead of megabytes.
pub fn save(config: &BuildingsConfig, meta: &GridMeta, cells: &[u16]) -> Result<(), String> {
    fs::create_dir_all(&config.grid_dir).map_err(|e| e.to_string())?;
    let json = serde_json::to_vec_pretty(meta).map_err(|e| e.to_string())?;
    write_atomic(&config.cells_path(), &encode_cells(cells))?;
    write_atomic(&config.meta_path(), &json)
}

fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let temp = path.with_extension("tmp");
    fs::write(&temp, bytes).map_err(|e| format!("{}: {e}", temp.display()))?;
    fs::rename(&temp, path).map_err(|e| format!("{}: {e}", path.display()))
}

pub fn encode_cells(cells: &[u16]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < cells.len() {
        let value = cells[i];
        let mut run = 1usize;
        while i + run < cells.len() && cells[i + run] == value && run < u32::MAX as usize {
            run += 1;
        }
        out.extend_from_slice(&value.to_le_bytes());
        out.extend_from_slice(&(run as u32).to_le_bytes());
        i += run;
    }
    out
}

pub fn decode_cells(bytes: &[u8], expected: usize) -> Result<Vec<u16>, String> {
    if bytes.len() % 6 != 0 {
        return Err("grid cells file is truncated".into());
    }
    let mut cells = Vec::with_capacity(expected);
    for chunk in bytes.chunks_exact(6) {
        let value = u16::from_le_bytes([chunk[0], chunk[1]]);
        let run = u32::from_le_bytes([chunk[2], chunk[3], chunk[4], chunk[5]]) as usize;
        if cells.len() + run > expected {
            return Err("grid cells file has more cells than rows × cols".into());
        }
        cells.resize(cells.len() + run, value);
    }
    if cells.len() != expected {
        return Err(format!("grid cells file has {} cells, expected {expected}", cells.len()));
    }
    Ok(cells)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn config(dir: &Path) -> BuildingsConfig {
        BuildingsConfig {
            source: dir.join("buildings.json"),
            grid_dir: dir.to_path_buf(),
            resolution_m: 2.0,
            margin_m: 10.0,
            buffer_m: 0.0,
            max_accuracy_m: Some(30.0),
            rebuild_if_stale: true,
        }
    }

    /// A rectangle `w` × `h` meters with its south-west corner `east`/`north` meters from a base point.
    fn rect(east: f64, north: f64, w: f64, h: f64) -> Vec<[f64; 2]> {
        let (m_lat, m_lng) = meters_per_degree(43.07);
        let lat = |n: f64| 43.07 + n / m_lat;
        let lng = |e: f64| -89.40 + e / m_lng;
        vec![
            [lat(north), lng(east)],
            [lat(north), lng(east + w)],
            [lat(north + h), lng(east + w)],
            [lat(north + h), lng(east)],
        ]
    }

    fn at(east: f64, north: f64) -> (f64, f64) {
        let (m_lat, m_lng) = meters_per_degree(43.07);
        (43.07 + north / m_lat, -89.40 + east / m_lng)
    }

    fn building(id: &str, name: &str, polygon: Vec<[f64; 2]>) -> Value {
        json!({ "id": id, "name": name, "type": "class", "center": polygon[0], "perimeter_polygon": polygon })
    }

    fn index_from(buildings: Vec<Value>) -> BuildingIndex {
        let source = serde_json::to_vec(&json!({ "campus": "Test", "buildings": buildings })).unwrap();
        let config = config(Path::new("/nonexistent"));
        let (meta, cells) = build(&source, &config).unwrap();
        BuildingIndex::from_parts(meta, cells, config.max_accuracy_m)
    }

    #[test]
    fn finds_rectangle_and_nothing_outside() {
        let index = index_from(vec![building("hall", "Hall", rect(0.0, 0.0, 40.0, 20.0))]);
        let (lat, lng) = at(20.0, 10.0);
        assert_eq!(index.building_name(lat, lng).map(|n| n.as_ref()), Some("Hall"));
        let (lat, lng) = at(50.0, 10.0); // 10 m east of the wall, still inside the grid margin
        assert_eq!(index.building_name(lat, lng), None);
        // Far away and invalid input
        assert_eq!(index.building_name(44.0, -89.40), None);
        assert_eq!(index.building_name(f64::NAN, -89.40), None);
        assert_eq!(index.building_name(43.07, f64::INFINITY), None);
        assert_eq!(index.building_name(91.0, 200.0), None);
    }

    fn index_with_buffer(buildings: Vec<Value>, buffer_m: f64) -> BuildingIndex {
        let source = serde_json::to_vec(&json!({ "campus": "Test", "buildings": buildings })).unwrap();
        let config = BuildingsConfig { buffer_m, ..config(Path::new("/nonexistent")) };
        let (meta, cells) = build(&source, &config).unwrap();
        BuildingIndex::from_parts(meta, cells, config.max_accuracy_m)
    }

    #[test]
    fn grid_is_square() {
        let index = index_with_buffer(vec![building("long", "Long", rect(0.0, 0.0, 400.0, 20.0))], 15.0);
        assert_eq!(index.meta().rows, index.meta().cols);
        // The building stays in the middle: found inside, not outside.
        let (lat, lng) = at(200.0, 10.0);
        assert_eq!(index.building_name(lat, lng).map(|n| n.as_ref()), Some("Long"));
        let (lat, lng) = at(200.0, 150.0);
        assert_eq!(index.building_name(lat, lng), None);
    }

    #[test]
    fn buffer_extends_a_building_a_little() {
        let index = index_with_buffer(vec![building("hall", "Hall", rect(0.0, 0.0, 40.0, 20.0))], 15.0);
        for (east, north) in [(50.0, 10.0), (20.0, 32.0), (-12.0, -8.0)] {
            let (lat, lng) = at(east, north);
            assert_eq!(index.building_name(lat, lng).map(|n| n.as_ref()), Some("Hall"), "{east},{north}");
        }
        for (east, north) in [(60.0, 10.0), (20.0, 40.0), (-20.0, -20.0)] {
            let (lat, lng) = at(east, north);
            assert_eq!(index.building_name(lat, lng), None, "{east},{north}");
        }
    }

    #[test]
    fn real_outline_beats_a_neighbors_buffer_and_buffers_split_by_distance() {
        // Two halls 10 m apart: the gap goes half to each; neither eats into the other.
        let index = index_with_buffer(vec![
            building("west", "West", rect(0.0, 0.0, 40.0, 20.0)),
            building("east", "East", rect(50.0, 0.0, 40.0, 20.0)),
        ], 15.0);
        let name = |east: f64| { let (lat, lng) = at(east, 10.0); index.building_name(lat, lng).map(|n| n.to_string()) };
        assert_eq!(name(41.0).as_deref(), Some("West"));
        assert_eq!(name(43.0).as_deref(), Some("West"));
        assert_eq!(name(47.0).as_deref(), Some("East"));
        assert_eq!(name(51.0).as_deref(), Some("East")); // inside East, 11 m from West
        assert_eq!(name(39.0).as_deref(), Some("West"));
    }

    #[test]
    fn concave_polygon_leaves_its_notch_empty() {
        // An L: 40 × 40 square missing its north-east 20 × 20 quarter.
        let (m_lat, m_lng) = meters_per_degree(43.07);
        let p = |e: f64, n: f64| [43.07 + n / m_lat, -89.40 + e / m_lng];
        let l_shape = vec![p(0.0, 0.0), p(40.0, 0.0), p(40.0, 20.0), p(20.0, 20.0), p(20.0, 40.0), p(0.0, 40.0)];
        let index = index_from(vec![building("ell", "Ell", l_shape)]);
        let name = |e: f64, n: f64| {
            let (lat, lng) = at(e, n);
            index.building_name(lat, lng).map(|s| s.to_string())
        };
        assert_eq!(name(10.0, 10.0).as_deref(), Some("Ell"));
        assert_eq!(name(30.0, 10.0).as_deref(), Some("Ell"));
        assert_eq!(name(10.0, 30.0).as_deref(), Some("Ell"));
        assert_eq!(name(30.0, 30.0), None, "the missing quarter must stay empty");
        // Rasterized area is close to the real 1200 m² (300 cells of 4 m²).
        let filled = index.cells().iter().filter(|&&c| c == 1).count();
        assert!((280..=320).contains(&filled), "{filled} cells");
    }

    #[test]
    fn smaller_overlapping_building_wins_and_is_reported() {
        let index = index_from(vec![
            building("complex", "Complex", rect(0.0, 0.0, 60.0, 60.0)),
            building("annex", "Annex", rect(20.0, 20.0, 10.0, 10.0)),
        ]);
        let (lat, lng) = at(25.0, 25.0);
        assert_eq!(index.building_name(lat, lng).map(|n| n.as_ref()), Some("Annex"));
        let (lat, lng) = at(5.0, 5.0);
        assert_eq!(index.building_name(lat, lng).map(|n| n.as_ref()), Some("Complex"));
        let overlap = &index.meta().overlaps[0];
        assert_eq!((overlap.a.as_str(), overlap.b.as_str(), overlap.winner.as_str()), ("complex", "annex", "annex"));
        assert_eq!(overlap.cells, 25);
    }

    #[test]
    fn equal_overlap_goes_to_the_lower_id() {
        let index = index_from(vec![
            building("first", "First", rect(0.0, 0.0, 20.0, 20.0)),
            building("second", "Second", rect(0.0, 0.0, 20.0, 20.0)),
        ]);
        let (lat, lng) = at(10.0, 10.0);
        assert_eq!(index.building_name(lat, lng).map(|n| n.as_ref()), Some("First"));
        assert_eq!(index.meta().overlaps[0].winner, "first");
    }

    #[test]
    fn malformed_buildings_are_skipped_and_reported() {
        let index = index_from(vec![
            building("good", "Good", rect(0.0, 0.0, 20.0, 20.0)),
            json!({ "id": "two_points", "name": "Two", "perimeter_polygon": [[43.07, -89.40], [43.071, -89.40]] }),
            json!({ "id": "nan", "name": "Bad", "perimeter_polygon": [[43.07, -89.40], ["x", -89.40], [43.071, -89.401]] }),
            json!({ "id": "flat", "name": "Flat", "perimeter_polygon": [[43.07, -89.40], [43.07, -89.401], [43.07, -89.402]] }),
            json!({ "id": "no_name", "perimeter_polygon": rect(30.0, 0.0, 5.0, 5.0) }),
            json!({ "id": "good", "name": "Duplicate", "perimeter_polygon": rect(40.0, 0.0, 5.0, 5.0) }),
            json!({ "name": "No id", "perimeter_polygon": rect(50.0, 0.0, 5.0, 5.0) }),
        ]);
        assert_eq!(index.meta().buildings.len(), 1);
        let reasons: Vec<&str> = index.meta().skipped.iter().map(|s| s.reason.as_str()).collect();
        assert_eq!(index.meta().skipped.len(), 6, "{reasons:?}");
    }

    #[test]
    fn closing_vertex_is_ignored() {
        let mut polygon = rect(0.0, 0.0, 20.0, 20.0);
        polygon.push(polygon[0]);
        let index = index_from(vec![building("hall", "Hall", polygon)]);
        assert_eq!(index.meta().buildings.len(), 1);
    }

    #[test]
    fn indices_are_consistent_and_never_out_of_bounds() {
        let index = index_from(vec![building("hall", "Hall", rect(0.0, 0.0, 40.0, 20.0))]);
        let meta = index.meta().clone();
        // Every cell's own center maps back to that cell.
        for row in (0..meta.rows).step_by(3) {
            for col in (0..meta.cols).step_by(3) {
                let lat = meta.max_lat - (row as f64 + 0.5) * meta.resolution_m / meta.meters_per_deg_lat;
                let lng = meta.min_lng + (col as f64 + 0.5) * meta.resolution_m / meta.meters_per_deg_lng;
                assert_eq!(index.cell_index(lat, lng), Some((row, col)));
            }
        }
        // Exact edges: the north-west corner is in, the far edges are out.
        assert_eq!(index.cell_index(meta.max_lat, meta.min_lng), Some((0, 0)));
        // The far edges are outside, give or take floating-point rounding onto the last cell.
        let last = (meta.rows - 1, meta.cols - 1);
        assert!([None, Some((last.0, 0))].contains(&index.cell_index(meta.min_lat, meta.min_lng)));
        assert!([None, Some((0, last.1))].contains(&index.cell_index(meta.max_lat, meta.max_lng)));
        assert_eq!(index.cell_index(meta.min_lat - 1e-6, meta.min_lng), None);
        assert_eq!(index.cell_index(meta.max_lat, meta.max_lng + 1e-6), None);
        // A sweep well past the grid on every side never panics.
        let mut seed = 7u64;
        for _ in 0..200_000 {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            let lat = 43.0 + ((seed >> 11) as f64 / (1u64 << 53) as f64) * 0.14;
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            let lng = -89.47 + ((seed >> 11) as f64 / (1u64 << 53) as f64) * 0.14;
            let _ = index.building_id(lat, lng);
        }
    }

    #[test]
    fn poor_accuracy_gets_no_building() {
        let index = index_from(vec![building("hall", "Hall", rect(0.0, 0.0, 40.0, 20.0))]);
        let (lat, lng) = at(20.0, 10.0);
        assert_eq!(index.lookup(lat, lng, None).as_deref(), Some("Hall"));
        assert_eq!(index.lookup(lat, lng, Some(8.0)).as_deref(), Some("Hall"));
        assert_eq!(index.lookup(lat, lng, Some(65.0)), None);
        assert_eq!(index.lookup(lat, lng, Some(-1.0)), None, "iOS reports -1 for an invalid fix");
    }

    #[test]
    fn saves_loads_and_rejects_a_stale_grid() {
        let dir = std::env::temp_dir().join(format!("grid-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let config = config(&dir);
        let source = serde_json::to_vec(&json!({ "campus": "T", "buildings": [building("hall", "Hall", rect(0.0, 0.0, 40.0, 20.0))] })).unwrap();
        fs::write(&config.source, &source).unwrap();

        let (meta, cells) = build(&source, &config).unwrap();
        save(&config, &meta, &cells).unwrap();
        let loaded = BuildingIndex::load(&config, &source).unwrap();
        assert_eq!(loaded.meta(), &meta);
        assert_eq!(loaded.cells(), &cells[..]);

        // Any change to the JSON makes the saved grid unusable.
        let mut changed = source.clone();
        changed.push(b' ');
        assert!(BuildingIndex::load(&config, &changed).is_err());
        // load_or_build rebuilds it instead.
        fs::write(&config.source, &changed).unwrap();
        let rebuilt = BuildingIndex::load_or_build(&config).unwrap();
        assert_eq!(rebuilt.meta().source_checksum, checksum(&changed));
        // ...or fails clearly when rebuilding isn't allowed.
        fs::write(&config.source, &source).unwrap();
        let strict = BuildingsConfig { rebuild_if_stale: false, ..config.clone() };
        assert!(BuildingIndex::load_or_build(&strict).err().unwrap().contains("out of date"));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn run_length_encoding_round_trips() {
        let cells = vec![0, 0, 0, 5, 5, 5, 0, 8, 8, 0];
        assert_eq!(decode_cells(&encode_cells(&cells), cells.len()).unwrap(), cells);
        assert!(decode_cells(&encode_cells(&cells), cells.len() + 1).is_err());
        assert!(decode_cells(&[1, 2, 3], 1).is_err());
    }
}
