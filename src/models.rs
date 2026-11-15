use chrono::{DateTime, FixedOffset, Utc};
use serde::{Deserialize, Serialize};

/// Deserializing into `DateTime<FixedOffset>` rejects timestamps without a timezone.
#[derive(Deserialize)]
pub struct LocationIn {
    pub lat: f64,
    pub lng: f64,
    pub timestamp: DateTime<FixedOffset>,
    pub device_id: Option<String>,
}

#[derive(Deserialize)]
pub struct BatchIn {
    pub points: Vec<LocationIn>,
}

#[derive(Serialize)]
pub struct Accepted {
    pub accepted: usize,
}

#[derive(Serialize, Clone, Copy)]
pub struct LatLng {
    pub lat: f64,
    pub lng: f64,
}

#[derive(Serialize)]
pub struct HeatmapOut {
    pub start: String,
    pub end: String,
    pub count: usize,
    pub data: std::collections::BTreeMap<String, Vec<LatLng>>,
}

/// A validated point, normalised to UTC.
#[derive(Clone, Debug)]
pub struct Point {
    pub lat: f64,
    pub lng: f64,
    pub time: DateTime<Utc>,
    pub device_id: String,
}

/// (time, lat, lng)
pub type Row = (DateTime<Utc>, f64, f64);

/// minLng, minLat, maxLng, maxLat
pub type BBox = (f64, f64, f64, f64);

impl LocationIn {
    pub fn validate(self) -> Result<Point, String> {
        if !(-90.0..=90.0).contains(&self.lat) {
            return Err("lat must be between -90 and 90".into());
        }
        if !(-180.0..=180.0).contains(&self.lng) {
            return Err("lng must be between -180 and 180".into());
        }
        let device_id = self
            .device_id
            .map(|d| d.trim().to_string())
            .filter(|d| !d.is_empty())
            .unwrap_or_else(|| "unknown".to_string());
        if device_id.len() > 128 {
            return Err("device_id must be at most 128 characters".into());
        }
        Ok(Point { lat: self.lat, lng: self.lng, time: self.timestamp.with_timezone(&Utc), device_id })
    }
}
