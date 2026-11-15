use chrono::{DateTime, FixedOffset, Utc};
use serde::{Deserialize, Serialize};

/// Timestamps must include an explicit timezone offset.
#[derive(Deserialize)]
pub struct LocationIn {
    pub lat: f64,
    pub lng: f64,
    pub timestamp: DateTime<FixedOffset>,
    pub device_id: Option<String>,
    /// Optional to preserve compatibility with clients that do not send a building yet.
    pub building: Option<String>,
}

#[derive(Deserialize)]
pub struct BatchIn {
    pub points: Vec<LocationIn>,
}

#[derive(Serialize)]
pub struct Accepted {
    pub accepted: usize,
}

/// The building appears last in each returned heatmap point.
#[derive(Serialize, Clone)]
pub struct LatLng {
    pub lat: f64,
    pub lng: f64,
    pub building: Option<String>,
}

#[derive(Serialize)]
pub struct HeatmapOut {
    pub start: String,
    pub end: String,
    pub count: usize,
    pub data: std::collections::BTreeMap<String, Vec<LatLng>>,
}

/// A validated point normalized to UTC.
#[derive(Clone, Debug)]
pub struct Point {
    pub lat: f64,
    pub lng: f64,
    pub time: DateTime<Utc>,
    pub device_id: String,
    pub building: Option<String>,
}

/// (time, lat, lng, building)
pub type Row = (DateTime<Utc>, f64, f64, Option<String>);

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
        let building = self
            .building
            .map(|name| name.trim().to_string())
            .filter(|name| !name.is_empty());
        if building.as_ref().is_some_and(|name| name.chars().count() > 256) {
            return Err("building must be at most 256 characters".into());
        }
        Ok(Point {
            lat: self.lat,
            lng: self.lng,
            time: self.timestamp.with_timezone(&Utc),
            device_id,
            building,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn building_is_trimmed_and_optional() {
        let time = FixedOffset::east_opt(0)
            .unwrap()
            .with_ymd_and_hms(2026, 11, 14, 7, 0, 0)
            .unwrap();
        let point = LocationIn {
            lat: 43.07,
            lng: -89.40,
            timestamp: time,
            device_id: None,
            building: Some("  Memorial Union  ".to_string()),
        }
        .validate()
        .unwrap();
        assert_eq!(point.building.as_deref(), Some("Memorial Union"));
        assert_eq!(point.device_id, "unknown");
        let missing: LocationIn = serde_json::from_str(
            r#"{"lat":43.07,"lng":-89.40,"timestamp":"2026-11-14T07:00:00Z"}"#,
        )
        .unwrap();
        assert_eq!(missing.validate().unwrap().building, None);
    }
}
